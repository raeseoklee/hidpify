import AppKit
import CoreGraphics
import Dispatch
import Darwin
import Foundation
import os

/// Event-driven resident daemon (no polling, per DESIGN.md §4.6).
/// Re-applies persisted targets on display reconfiguration, sleep/wake, and SIGHUP;
/// tears down virtual displays and exits on SIGTERM/SIGINT.
///
/// Runs a full `NSApplication` (not just `RunLoop.main`), since streaming-mode
/// sessions need one, and driving it also keeps this process's AppKit event
/// queue serviced (see the comment above `NSApplication.shared.run()` in
/// `run()`). It registers as `.prohibited` — no Dock icon, no Cmd-Tab entry —
/// so this is invisible to the user regardless.
public final class DaemonRunner {
    fileprivate let logger = Logger(subsystem: "dev.irae.hidpify", category: "daemon")
    fileprivate var debounceWorkItem: DispatchWorkItem?
    fileprivate var retryWorkItem: DispatchWorkItem?
    fileprivate var healthCheckTimer: DispatchSourceTimer?
    /// When this daemon process started — used to ignore a `screensDidWake` that
    /// arrives right after launch, so the wake-triggered self-restart can't loop.
    fileprivate let startedAt = Date()

    public init() {}

    /// Runs one reapply and, if `SessionController` reports a target still
    /// backing off (e.g. a virtual display that won't come online while
    /// WindowServer settles after wake), schedules the next retry at the
    /// requested time. This keeps a failed target getting retried with backoff
    /// even when no further display reconfiguration fires. Main-queue only.
    fileprivate func performReapply() {
        let nextRetry = SessionController.shared.reapply(configs: ConfigStore.load().targets)
        retryWorkItem?.cancel()
        guard let nextRetry else { return }
        let delay = max(0.5, nextRetry.timeIntervalSinceNow)
        let workItem = DispatchWorkItem { [weak self] in self?.performReapply() }
        retryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    public func run() {
        // Registers this process as a background GUI app (`.prohibited` — no
        // Dock icon, no Cmd-Tab entry) via the same one-shot initializer
        // streaming mode uses. Required so `NSApplication.shared.run()` below
        // has an application to drive, and so the daemon actually services its
        // AppKit event queue (avoids "Not Responding" in Activity Monitor —
        // see the comment on `NSApplication.shared.run()` at the bottom).
        StreamController.ensureAppKitInitialized()

        // Capture the arrangement baseline before the first reapply, but
        // only if the arrangement is actually clean (no virtual display
        // still online from a previous run) — otherwise keep whatever
        // baseline is already on disk (DESIGN.md §10.2).
        if ArrangementController.noVirtualDisplaysOnline() {
            let targets = Set(ConfigStore.load().targets.map { $0.matcher })
            if let baseline = ArrangementController.snapshotRealDisplays(preferAnchorNotIn: targets) {
                ArrangementStore.save(baseline)
            }
        }

        performReapply()

        CGDisplayRegisterReconfigurationCallback(
            daemonReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        let notificationCenter = NSWorkspace.shared.notificationCenter
        notificationCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [logger] _ in
            logger.info("screensDidSleep — disabling all sessions")
            SessionController.shared.disableAll()
        }
        notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [self] _ in
            // A CGVirtualDisplay created by THIS long-running process fails to
            // register in CGGetOnlineDisplayList after sleep/wake — the process's
            // WindowServer/CoreGraphics connection goes stale, so `enable` keeps
            // timing out in `waitUntilOnline` and HiDPI never comes back (observed
            // in the log: "created virtual display N" → "did not appear in
            // CGGetOnlineDisplayList within timeout"). A *freshly started* process
            // creates displays that online fine. So on wake we don't re-apply in
            // process — we exit and let launchd (KeepAlive) restart us with a fresh
            // connection, which reliably re-applies HiDPI. The startup guard stops
            // a wake notification arriving right after launch from looping restarts.
            guard Date().timeIntervalSince(startedAt) > 15 else {
                logger.info("screensDidWake ignored — daemon just started")
                return
            }
            logger.info("screensDidWake — restarting for a fresh graphics connection")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                exit(0)
            }
        }

        // Periodic stream health check (DESIGN.md §9.5). A stream can die
        // (ScreenCaptureKit error, a closed player window) with no display
        // reconfiguration to trigger a reapply, which would leave a frozen black
        // panel. While any session is streaming, re-run reapply every 5s so it
        // recreates an unhealthy stream (reapply is idempotent when healthy).
        // Only active while streaming — mirror-only setups never poll.
        let healthTimer = DispatchSource.makeTimerSource(queue: .main)
        healthTimer.schedule(deadline: .now() + 5.0, repeating: 5.0)
        healthTimer.setEventHandler { [weak self] in
            guard let self else { return }
            if SessionController.shared.hasStreamSessions() {
                self.performReapply()
            }
        }
        healthTimer.resume()
        healthCheckTimer = healthTimer

        // Ignore default disposition first so the dispatch sources can intercept.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)

        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource.setEventHandler { [logger] in
            logger.info("SIGTERM received — disabling all sessions and exiting")
            SessionController.shared.disableAll()
            exit(0)
        }
        sigtermSource.resume()

        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigintSource.setEventHandler { [logger] in
            logger.info("SIGINT received — disabling all sessions and exiting")
            SessionController.shared.disableAll()
            exit(0)
        }
        sigintSource.resume()

        let sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: .main)
        sighupSource.setEventHandler { [self] in
            logger.info("SIGHUP received — reapplying config")
            performReapply()
        }
        sighupSource.resume()

        // `NSApplication.run()` drives the same underlying CFRunLoop that a bare
        // `RunLoop.main.run()` wraps, so every registration above (DispatchSource
        // signal handlers, CGDisplayRegisterReconfigurationCallback, NSWorkspace
        // notifications) keeps working unchanged. Unlike the bare run loop, it
        // also services the AppKit event queue — a GUI-registered process
        // (`ensureAppKitInitialized()` above) that never does this is exactly
        // what macOS reports as "Not Responding" in Activity Monitor. Because
        // this process is `.prohibited`, it still shows no Dock icon and never
        // appears in Cmd-Tab; only its "Not Responding" status changes.
        NSApplication.shared.run()
    }

    /// Debounces reconfiguration bursts (1s) before re-applying, since our own
    /// mirroring/mode changes also trigger this callback (idempotent reapply blocks the loop).
    fileprivate func scheduleDebouncedReapply() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.debounceWorkItem?.cancel()
            let workItem = DispatchWorkItem {
                // Re-capture the baseline only when the arrangement is
                // provably clean: no active sessions *and* no virtual
                // display online. Capturing while a session is active would
                // bake its virtual-display-driven layout in as the
                // "baseline", corrupting future restores (DESIGN.md §10.2).
                if SessionController.shared.sessions.isEmpty,
                    ArrangementController.noVirtualDisplaysOnline()
                {
                    let targets = Set(ConfigStore.load().targets.map { $0.matcher })
                    if let baseline = ArrangementController.snapshotRealDisplays(preferAnchorNotIn: targets) {
                        ArrangementStore.save(baseline)
                    }
                }
                self.performReapply()
            }
            self.debounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
        }
    }
}

/// C function pointer target for `CGDisplayRegisterReconfigurationCallback`.
/// Must not capture context; the `DaemonRunner` instance is passed via `userInfo`.
private func daemonReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let runner = Unmanaged<DaemonRunner>.fromOpaque(userInfo).takeUnretainedValue()
    runner.scheduleDebouncedReapply()
}
