import CoreGraphics
import Foundation
import HidpifyCore

/// Menu bar app state. Pure frontend per DESIGN.md §8.1: reads display state via
/// `DisplayEnumerator` (public, read-only), edits config via `ConfigStore`, and
/// controls the daemon via `LaunchAgentInstaller` — never creates virtual displays
/// or mirrors itself.
@MainActor
final class AppState: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var config: AppConfig = AppConfig()
    @Published var agentLoaded: Bool = false
    @Published var daemonInstalled: Bool = false

    private var debounceTask: Task<Void, Never>?

    init() {
        refresh()
        // Self-heal: if HiDPI is configured but the LaunchAgent has gone missing
        // (e.g. removed by an external `brew` operation), reinstall it so the
        // daemon comes back. Only acts when HiDPI targets exist and a standalone
        // `hidpify` binary is available to run.
        if !config.targets.isEmpty, !daemonInstalled, daemonBinaryPathForInstall() != nil {
            ensureDaemonRunning()
        }
        CGDisplayRegisterReconfigurationCallback(
            appStateReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Refreshes displays (physical only), config, daemon-loaded status, and
    /// Screen Recording permission status (for the streaming-mode warning).
    func refresh() {
        displays = DisplayEnumerator.onlineDisplays().filter { !$0.isOurVirtual }
        config = ConfigStore.load()
        agentLoaded = LaunchAgentInstaller.isLoaded()
        daemonInstalled = LaunchAgentInstaller.isInstalled()
    }

    /// Debounces reconfiguration bursts (1s) before refreshing, mirroring
    /// `DaemonRunner.scheduleDebouncedReapply` but implemented with structured
    /// concurrency for this MainActor-isolated class.
    func scheduleDebouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    func isManaged(_ display: DisplayInfo) -> Bool {
        config.targets.contains { $0.matcher == display.matcher }
    }

    /// Enables or disables HiDPI for `display`. Never touches virtual displays
    /// directly — only edits `ConfigStore` and, if the daemon is running,
    /// asks it to re-apply via `kickstart()`.
    func setHiDPI(_ display: DisplayInfo, enabled: Bool) {
        if enabled {
            let existing = config.targets.first { $0.matcher == display.matcher }
            let virtualSerialNum = existing?.virtualSerialNum ?? UInt32.random(in: 1...UInt32.max)

            let looksLike: (width: Int, height: Int)
            if let existing {
                looksLike = (existing.looksLikeWidth, existing.looksLikeHeight)
            } else if let firstCandidate = ResolutionAdvisor.candidates(
                for: display,
                others: displays.filter { $0.id != display.id }
            ).first {
                looksLike = (firstCandidate.width, firstCandidate.height)
            } else {
                looksLike = (display.logicalWidth, display.logicalHeight)
            }

            let refreshRate = display.refreshRate > 0 ? display.refreshRate : 60
            let target = TargetConfig(
                matcher: display.matcher,
                displayName: display.name,
                looksLikeWidth: looksLike.width,
                looksLikeHeight: looksLike.height,
                refreshRate: refreshRate,
                virtualSerialNum: virtualSerialNum
            )
            try? ConfigStore.addOrUpdate(target: target)
        } else {
            try? ConfigStore.remove(matcher: display.matcher)
        }

        if enabled {
            // The user just asked for HiDPI — make sure the daemon is up to apply
            // it, installing the LaunchAgent if it isn't there yet (self-heal).
            ensureDaemonRunning()
        } else {
            if agentLoaded {
                LaunchAgentInstaller.kickstart()
            }
            refresh()
        }
    }

    /// Updates the persisted looks-like resolution for an already-managed display
    /// and asks the daemon to re-apply it.
    func setLooksLike(_ display: DisplayInfo, width: Int, height: Int) {
        guard var target = config.targets.first(where: { $0.matcher == display.matcher }) else {
            return
        }
        target.looksLikeWidth = width
        target.looksLikeHeight = height
        try? ConfigStore.addOrUpdate(target: target)
        LaunchAgentInstaller.kickstart()
        refresh()
    }

    /// Returns the persisted scaling mode for `display`, or `.mirror` when the
    /// display isn't managed yet (mirroring is the default, DESIGN.md §9.1).
    func currentMode(_ display: DisplayInfo) -> ScalingMode {
        config.targets.first { $0.matcher == display.matcher }?.mode ?? .mirror
    }

    /// Switches an already-managed display between mirroring and streaming.
    /// Ignored if the display isn't managed yet. Never starts a stream itself
    /// (DESIGN.md §8.1) — it only edits `ConfigStore`, triggers the Screen
    /// Recording permission prompt up front for `.stream` (DESIGN.md §9.3), and
    /// asks the daemon to re-apply.
    func setMode(_ display: DisplayInfo, mode: ScalingMode) {
        guard var target = config.targets.first(where: { $0.matcher == display.matcher }) else {
            return
        }
        target.mode = mode
        try? ConfigStore.addOrUpdate(target: target)

        // Screen Recording is a per-binary TCC grant. The daemon (`hidpify`),
        // not this app, is what captures, so the app must NOT request the
        // permission for itself — that would grant it to the wrong binary. The
        // daemon requests it in its own context on the next kickstart below.
        if agentLoaded {
            LaunchAgentInstaller.kickstart()
        }
        refresh()
    }

    /// First existing path among the common install locations for the `hidpify` CLI.
    func cliBinaryPath() -> String? {
        let candidates = [
            "~/.local/bin/hidpify",
            "/opt/homebrew/bin/hidpify",
            "/usr/local/bin/hidpify",
        ]
        for path in candidates {
            let expanded = (path as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return expanded
            }
        }
        return nil
    }

    /// Installs/uninstalls the LaunchAgent. Installing requires a `hidpify` binary
    /// to be found by `daemonBinaryPathForInstall()`; if none is found, the
    /// request is silently ignored (the toggle is disabled in the UI for this case).
    func setStartAtLogin(_ on: Bool) {
        if on {
            if let binaryPath = daemonBinaryPathForInstall() {
                try? LaunchAgentInstaller.install(binaryPath: binaryPath)
            }
        } else {
            try? LaunchAgentInstaller.uninstall()
        }
        refresh()
    }

    /// Directly starts the daemon, independent of the "Start at Login" LaunchAgent
    /// installation. Three cases:
    /// 1. Not installed yet: installs (which bootstraps and thus runs it
    ///    immediately). Silently no-ops if no `hidpify` binary can be found.
    /// 2. Installed but not currently running: bootstraps the existing plist.
    /// 3. Already running: restarts it in place via `kickstart`.
    func startDaemon() {
        ensureDaemonRunning()
    }

    /// Ensures the daemon is installed and running: installs the LaunchAgent if
    /// missing (which also bootstraps it), loads it if installed-but-stopped, or
    /// kickstarts it to re-apply if already running. Silently no-ops when no
    /// standalone `hidpify` binary is available (the bundle copy can't run the
    /// daemon — see `daemonBinaryPathForInstall`). Shared by `startDaemon`, the
    /// self-heal on launch, and enabling HiDPI.
    func ensureDaemonRunning() {
        if !daemonInstalled {
            if let binaryPath = daemonBinaryPathForInstall() {
                try? LaunchAgentInstaller.install(binaryPath: binaryPath)
            }
        } else if !agentLoaded {
            LaunchAgentInstaller.load()
        } else {
            LaunchAgentInstaller.kickstart()
        }
        refresh()
    }

    /// Stops the running daemon without uninstalling it — the plist stays in
    /// place, so it returns on the next login via `RunAtLoad`.
    func stopDaemon() {
        LaunchAgentInstaller.stop()
        refresh()
    }

    /// Restarts the running daemon in place.
    func restartDaemon() {
        LaunchAgentInstaller.kickstart()
        refresh()
    }

    /// True if `startDaemon()` would be able to find a `hidpify` binary to run —
    /// either bundled inside this app or via `cliBinaryPath()`. Used by the UI to
    /// disable the "Start" control when neither is available.
    func canStartDaemon() -> Bool {
        daemonBinaryPathForInstall() != nil
    }

    /// Resolves which `hidpify` binary the LaunchAgent should run as `daemon`
    /// when this app installs/starts it.
    ///
    /// We deliberately use a STANDALONE binary (`cliBinaryPath()` — e.g.
    /// `~/.local/bin/hidpify`), never the copy nested inside this app bundle.
    /// Running the daemon from inside an ad-hoc-signed `.app` gets it SIGKILLed
    /// by taskgated ("Invalid Signature") in a crash-restart loop (see
    /// `LaunchAgentInstaller.resolvedBinaryPath`'s note). The trade-off is that
    /// the app requires the `hidpify` CLI to be installed on a standard path;
    /// the daemon controls are disabled (and Start at Login) when it isn't.
    private func daemonBinaryPathForInstall() -> String? {
        cliBinaryPath()
    }
}

/// C function pointer target for `CGDisplayRegisterReconfigurationCallback`.
/// Must not capture context; the `AppState` instance is passed via `userInfo`.
private func appStateReconfigurationCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let appState = Unmanaged<AppState>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor in
        appState.scheduleDebouncedRefresh()
    }
}
