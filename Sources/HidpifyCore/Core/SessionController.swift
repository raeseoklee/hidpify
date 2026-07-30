import CoreGraphics
import Foundation
import os

/// Tracks active "physical display ↔ virtual display ↔ mirroring" sessions
/// for the current process. See DESIGN.md §4.4 (enable flow) and §4.8 (error handling).
public final class SessionController {
    public static let shared = SessionController()

    public struct ActiveSession {
        public let config: TargetConfig
        public let handle: VirtualDisplayHandle
        public let physicalID: CGDirectDisplayID
        /// Effective mode this session is actually running as — may differ from
        /// `config.mode` when `.stream` fell back to `.mirror` for missing
        /// screen-recording permission (DESIGN.md §9.3).
        public let mode: ScalingMode
        public let stream: StreamSession?
        /// Physical display's origin before it was moved aside for streaming
        /// (DESIGN.md §9.2 step 2), restored on `disable(matcher:)`. `nil` for
        /// mirror sessions, which never move anything.
        public let restoreOrigin: (id: CGDirectDisplayID, origin: CGPoint)?
        /// Token to undo the physical display's injected color profile
        /// (DESIGN.md §9, `ColorProfileController`), restored on
        /// `disable(matcher:)`. `nil` for mirror sessions — mirroring already
        /// makes the physical panel inherit the virtual display's profile, so
        /// no injection happens for them (see `enable(config:)`).
        public let colorRestore: ColorProfileRestore?
        /// Physical display's mode before streaming drove it to native
        /// resolution (DESIGN.md §9.2 step 3), restored on `disable(matcher:)`.
        /// `nil` for mirror sessions, which never change the physical mode.
        public let restorePhysicalMode: CGDisplayMode?
        /// When this session was established. `reapply` won't tear a session
        /// down and recreate it within `reapplyCooldown` of this, even if the
        /// mirror/stream state momentarily looks wrong — during wake from sleep
        /// the display reconfiguration events arrive in a burst before macOS has
        /// settled, and re-enabling on that stale state makes the screen flap.
        public let enabledAt: Date
    }

    /// Grace period after establishing a session during which `reapply` trusts
    /// it rather than tearing it down — long enough to cover a sleep/wake
    /// display-reconfiguration burst. A genuinely broken session self-heals on
    /// the first reapply after this window.
    private static let reapplyCooldown: TimeInterval = 8.0

    public private(set) var sessions: [ActiveSession] = []

    /// Per-target exponential-backoff state after a failed `enable` in
    /// `reapply` (see its doc comment). Cleared on success or when the target
    /// is removed from the config.
    private var enableBackoff: [DisplayMatcher: (attempts: Int, retryAt: Date)] = [:]

    private let logger = Logger(subsystem: "dev.irae.hidpify", category: "SessionController")

    private init() {}

    public func isActive(matcher: DisplayMatcher) -> Bool {
        sessions.contains { $0.config.matcher == matcher }
    }

    /// True while at least one active session is streaming — lets the daemon run
    /// its periodic stream health check only when it can matter (DESIGN.md §9.5).
    public func hasStreamSessions() -> Bool {
        sessions.contains { $0.mode == .stream }
    }

    /// Reposition/resize each active stream's player window onto its physical
    /// panel's current frame (island moves on renormalization; resolution/rotation
    /// changes). Best-effort, main-thread (DESIGN.md §9.5).
    public func refreshStreamWindows() {
        for session in sessions where session.mode == .stream {
            _ = session.stream?.refreshWindowFrame()
        }
    }

    /// §4.4 ①~⑤ / §9.2. Never leaves a half-applied state: any failure after the
    /// virtual display comes online unwinds everything it did (in reverse order)
    /// and rethrows (§4.8).
    public func enable(config: TargetConfig) throws {
        guard VirtualDisplayFactory.isAPIAvailable() else {
            throw HiDPIError.privateAPIUnavailable
        }

        guard let physical = DisplayEnumerator.find(matcher: config.matcher) else {
            throw HiDPIError.displayNotFound(config.displayName)
        }

        // Reconnection cycle: an existing session for this display is torn down
        // first so it can be recreated cleanly below.
        if isActive(matcher: config.matcher) {
            try disable(matcher: config.matcher)
        }

        let handle = try VirtualDisplayFactory.create(
            name: "HiDPI \(config.displayName)",
            looksLikeWidth: config.looksLikeWidth,
            looksLikeHeight: config.looksLikeHeight,
            refreshRates: [config.refreshRate],
            serialNum: config.virtualSerialNum
        )

        // Rollback actions accumulated as each step below succeeds; run in
        // reverse on any later failure so no half-applied state remains (§4.8).
        // `handle` itself needs no entry here: falling out of scope on throw
        // deinits it, which detaches the virtual display.
        var rollback: [() -> Void] = []

        do {
            try waitUntilOnline(handle.displayID)

            var effectiveMode = config.mode
            if config.mode == .stream, !StreamController.hasScreenCapturePermission() {
                // Ask from the daemon's own (hidpify) binary context. Screen
                // Recording is a per-binary TCC grant and the daemon is what
                // actually captures — requesting here both registers `hidpify`
                // in System Settings > Screen Recording (so the user has
                // something to toggle) and shows the prompt attributed to the
                // correct binary. It returns immediately without the grant, so
                // we still fall back to mirror for this cycle; the next reapply
                // (after the user grants + the daemon restarts) streams for real.
                StreamController.requestScreenCapturePermission()
                logger.warning(
                    "화면 기록 권한이 없어 '\(config.displayName, privacy: .public)'을 스트리밍 대신 미러링으로 폴백합니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 hidpify를 허용한 뒤 다시 적용하세요."
                )
                effectiveMode = .mirror
            }

            let session: ActiveSession
            switch effectiveMode {
            case .mirror:
                try MirrorController.mirror(physical: physical.id, toVirtual: handle.displayID)
                rollback.append { try? MirrorController.stopMirroring(physical: physical.id) }

                try setHiDPIModeWithRetry(handle: handle, config: config)

                // Mirroring added the virtual display and made macOS renormalize
                // the arrangement (DESIGN.md §10.2). A mirror set sits at its
                // *master's* origin (the virtual display), so moving the physical
                // slave can't place the set — put the master where the physical
                // belongs, then pull the other real displays back to baseline
                // (the physical is a slave, it moves with the set).
                let baseline = ArrangementStore.load()
                if let target = baseline.flatMap({
                    ArrangementController.absoluteTarget(for: config.matcher, baseline: $0)
                }) {
                    try? MirrorController.setOrigins([(display: handle.displayID, origin: target)])
                }
                ArrangementController.restoreRealDisplaysToBaseline(baseline, except: [physical.id])

                session = ActiveSession(
                    config: config,
                    handle: handle,
                    physicalID: physical.id,
                    mode: .mirror,
                    stream: nil,
                    restoreOrigin: nil,
                    colorRestore: nil,
                    restorePhysicalMode: nil,
                    enabledAt: Date()
                )

            case .stream:
                let physicalOrigin = CGDisplayBounds(physical.id).origin
                let baseline = ArrangementStore.load()
                // Place the (independent) virtual at the physical's baseline slot
                // so the interactive desktop stays where the monitor was; fall
                // back to the physical's current origin if no baseline yet.
                let virtualTarget = baseline.flatMap {
                    ArrangementController.absoluteTarget(for: config.matcher, baseline: $0)
                } ?? physicalOrigin
                let islandOrigin = Self.remoteIslandOrigin(excluding: physical.id)

                try MirrorController.setOrigins([
                    (display: handle.displayID, origin: virtualTarget),
                    (display: physical.id, origin: islandOrigin),
                ])
                rollback.append {
                    try? MirrorController.setOrigins([(display: physical.id, origin: physicalOrigin)])
                }

                try setHiDPIModeWithRetry(handle: handle, config: config)

                // Drive the physical panel at its full native resolution so the
                // player window shows the captured HiDPI content at maximum panel
                // density (DESIGN.md §9.2 step 3). Without this the panel can sit
                // at a lower scaled mode, making the stream look non-HiDPI even
                // though the virtual source is rendered HiDPI. Best-effort: if the
                // native mode can't be found/applied, streaming still proceeds.
                var restorePhysicalMode: CGDisplayMode?
                if let originalMode = ModeSelector.currentMode(physical.id),
                    let nativeMode = ModeSelector.maxPixelMode(physical.id),
                    nativeMode.pixelWidth * nativeMode.pixelHeight
                        > originalMode.pixelWidth * originalMode.pixelHeight
                {
                    do {
                        try ModeSelector.setMode(physical.id, nativeMode)
                        restorePhysicalMode = originalMode
                        rollback.append { try? ModeSelector.setMode(physical.id, originalMode) }
                    } catch {
                        logger.error(
                            "물리 디스플레이를 네이티브 해상도로 전환하지 못했습니다: \(String(describing: error), privacy: .public)"
                        )
                    }
                }

                StreamController.ensureAppKitInitialized()
                let stream = try StreamController.start(
                    virtualID: handle.displayID,
                    physicalID: physical.id,
                    refreshRate: config.refreshRate
                )
                rollback.append { stream.stop() }

                // Parking the physical display at its island origin (above)
                // and starting capture both trigger a display reconfiguration
                // that renormalizes everyone else's arrangement. Restore every
                // other real display to baseline, but leave the physical
                // display alone — it's deliberately parked at the island
                // (DESIGN.md §10.2, §9.2).
                ArrangementController.restoreRealDisplaysToBaseline(
                    baseline,
                    except: [physical.id]
                )

                // Streaming feeds pixels via a player window rather than a
                // hardware mirror, so the physical panel doesn't automatically
                // inherit the virtual (sRGB) display's profile the way a
                // mirror does — inject it explicitly (DESIGN.md §9, background
                // in ColorProfileController's doc comment). Best-effort: a
                // failed injection is logged and streaming continues without
                // color correction rather than failing the whole session.
                let colorRestore = ColorProfileController.injectProfile(
                    from: handle.displayID,
                    to: physical.id
                )
                if let colorRestore {
                    rollback.append { ColorProfileController.restore(colorRestore) }
                }

                session = ActiveSession(
                    config: config,
                    handle: handle,
                    physicalID: physical.id,
                    mode: .stream,
                    stream: stream,
                    restoreOrigin: (id: physical.id, origin: physicalOrigin),
                    colorRestore: colorRestore,
                    restorePhysicalMode: restorePhysicalMode,
                    enabledAt: Date()
                )
            }

            sessions.append(session)
            logger.info(
                "enabled HiDPI (\(effectiveMode.rawValue, privacy: .public)) session for \(config.displayName, privacy: .public)"
            )
        } catch {
            for action in rollback.reversed() { action() }
            throw error
        }
    }

    private func setHiDPIModeWithRetry(handle: VirtualDisplayHandle, config: TargetConfig) throws {
        do {
            try ModeSelector.setHiDPIMode(
                displayID: handle.displayID,
                looksLikeWidth: config.looksLikeWidth,
                looksLikeHeight: config.looksLikeHeight,
                refreshRate: config.refreshRate
            )
        } catch {
            Thread.sleep(forTimeInterval: 0.5)
            try ModeSelector.setHiDPIMode(
                displayID: handle.displayID,
                looksLikeWidth: config.looksLikeWidth,
                looksLikeHeight: config.looksLikeHeight,
                refreshRate: config.refreshRate
            )
        }
    }

    /// Parks the streaming source's *physical* display far below every other
    /// display, with a large gap so no edge touches anything (DESIGN.md §9.2
    /// step 2). Because macOS only lets the cursor cross between displays whose
    /// edges are adjacent, a fully detached "island" display is unreachable by
    /// the cursor — so its phantom desktop (the physical panel is showing the
    /// stream via the player window, not this desktop) stays out of the way and
    /// off the working monitors, instead of leaving a visible empty region next
    /// to them. `excluding` is the physical display being moved, so its own
    /// (pre-move) bounds don't inflate the offset.
    private static func remoteIslandOrigin(excluding physicalID: CGDirectDisplayID) -> CGPoint {
        let others = DisplayEnumerator.onlineDisplays()
            .filter { $0.id != physicalID }
            .map { CGDisplayBounds($0.id) }
        let minX = others.map { $0.origin.x }.min() ?? 0
        let maxY = others.map { $0.origin.y + $0.size.height }.max() ?? 0
        // Gap larger than any plausible display dimension guarantees the top
        // edge is nowhere near another display's bottom edge → true island.
        let islandGap: CGFloat = 8000
        return CGPoint(x: minX, y: maxY + islandGap)
    }

    /// Best-effort: stop streaming or unmirror (whichever this session used),
    /// restore the physical display's origin if it was moved, and drop the
    /// session — which detaches the virtual display via `VirtualDisplayHandle` deinit.
    public func disable(matcher: DisplayMatcher) throws {
        guard let index = sessions.firstIndex(where: { $0.config.matcher == matcher }) else {
            return
        }
        let session = sessions[index]

        session.stream?.stop()

        if session.mode == .mirror, let physical = DisplayEnumerator.find(matcher: matcher) {
            try? MirrorController.stopMirroring(physical: physical.id)
        }

        // Order relative to `stream.stop()` above doesn't matter: the physical
        // display itself is untouched by either, so it's still around to
        // restore color on regardless of sequence.
        if let colorRestore = session.colorRestore {
            ColorProfileController.restore(colorRestore)
        }

        if let restorePhysicalMode = session.restorePhysicalMode {
            try? ModeSelector.setMode(session.physicalID, restorePhysicalMode)
        }

        if let restoreOrigin = session.restoreOrigin {
            try? MirrorController.setOrigins([(display: restoreOrigin.id, origin: restoreOrigin.origin)])
        }

        sessions.remove(at: index)
        logger.info("disabled HiDPI session for matcher \(String(describing: matcher), privacy: .public)")

        // The virtual display detaches as `session.handle`'s deinit runs
        // (triggered once the last strong reference — held by `session`
        // above — drops), which macOS also renormalizes the arrangement
        // for. Give it a brief moment to land, then restore every real
        // display, including the one just disabled, to baseline
        // (DESIGN.md §10.2).
        Thread.sleep(forTimeInterval: 0.3)
        ArrangementController.restoreRealDisplaysToBaseline(ArrangementStore.load(), except: [])
    }

    public func disableAll() {
        for matcher in sessions.map({ $0.config.matcher }) {
            try? disable(matcher: matcher)
        }
    }

    /// Clears all session bookkeeping WITHOUT the mirror/mode/origin teardown that
    /// `disable` does. Used on wake: after sleep the virtual displays are already
    /// gone, and running `disable`'s CG calls (stopMirroring / setMode /
    /// setOrigins) against that stale post-wake display state can block — a hung
    /// `disable` inside `reapply` leaves the daemon alive but never re-applying
    /// HiDPI (the exact "didn't recover after wake" symptom). Dropping the
    /// sessions lets each `VirtualDisplayHandle` deinit (detaching any lingering
    /// virtual) and clears backoff, so the next `reapply` rebuilds from a clean
    /// slate — the same state a freshly started daemon is in, which is the path
    /// that reliably re-applies after wake.
    public func forceResetForWake() {
        sessions.removeAll()
        enableBackoff.removeAll()
    }

    /// Idempotent, never throws. Applies each target that isn't already up.
    ///
    /// On failure it does NOT immediately retry: right after wake, creating a
    /// `CGVirtualDisplay` succeeds as an object but the display never registers
    /// in `CGGetOnlineDisplayList` (WindowServer is still settling), so
    /// `waitUntilOnline` times out. Retrying at once just creates/destroys a new
    /// virtual every few seconds, and that churn keeps WindowServer from ever
    /// settling — the daemon "flaps" and HiDPI never comes up. Instead each
    /// failing target backs off exponentially (3→6→12→24→30s), giving
    /// WindowServer quiet time to settle so a later attempt succeeds. Returns the
    /// earliest time a backed-off target should be retried (`nil` if none), so
    /// the daemon can schedule that retry even without a new reconfiguration.
    @discardableResult
    public func reapply(configs: [TargetConfig]) -> Date? {
        let staleMatchers = sessions
            .map { $0.config.matcher }
            .filter { matcher in !configs.contains { $0.matcher == matcher } }

        for matcher in staleMatchers {
            try? disable(matcher: matcher)
            enableBackoff[matcher] = nil
        }
        // Drop backoff state for matchers no longer configured at all.
        enableBackoff = enableBackoff.filter { key, _ in configs.contains { $0.matcher == key } }

        // Keep each stream's player window aligned to its panel's current frame
        // before deciding health below (DESIGN.md §9.5).
        refreshStreamWindows()

        for config in configs {
            guard let physical = DisplayEnumerator.find(matcher: config.matcher) else {
                continue
            }

            if let session = sessions.first(where: { $0.config.matcher == config.matcher }) {
                // Don't thrash a session we just established (wake-from-sleep
                // reconfiguration burst): trust it for a grace period even if
                // the mirror/stream state momentarily reads wrong.
                let recentlyEnabled =
                    Date().timeIntervalSince(session.enabledAt) < Self.reapplyCooldown

                // Screen-recording permission became available since we fell back
                // to mirror (DESIGN.md §9.3): upgrade to the stream the config
                // actually asks for. If the upgrade fails, fall back to mirror so
                // the display is never left dead (DESIGN.md §4.8).
                if session.mode == .mirror, config.mode == .stream,
                    StreamController.hasScreenCapturePermission()
                {
                    do {
                        try enable(config: config)
                        enableBackoff[config.matcher] = nil
                    } catch {
                        logger.warning(
                            "스트리밍 승격 실패 — 미러링을 유지합니다: \(String(describing: error), privacy: .public)"
                        )
                        var mirrorConfig = config
                        mirrorConfig.mode = .mirror
                        try? enable(config: mirrorConfig)
                    }
                    continue
                }

                switch session.mode {
                case .mirror:
                    if recentlyEnabled || physical.mirrorsDisplayID == session.handle.displayID {
                        enableBackoff[config.matcher] = nil
                        continue
                    }
                case .stream:
                    // Trust only a *healthy* stream: virtual still online, the
                    // capture hasn't errored, and the player window is still up
                    // (DESIGN.md §9.5). A dead stream falls through to be recreated
                    // instead of leaving a frozen black panel.
                    let virtualOnline = DisplayEnumerator.onlineDisplays()
                        .contains { $0.id == session.handle.displayID }
                    let healthy = virtualOnline && session.stream?.isHealthy == true
                    if healthy || recentlyEnabled {
                        enableBackoff[config.matcher] = nil
                        continue
                    }
                }
            }

            // Still inside a backoff window from a previous failure — skip so we
            // don't churn WindowServer; the daemon retries at `retryAt`.
            if let state = enableBackoff[config.matcher], Date() < state.retryAt {
                continue
            }

            do {
                try enable(config: config)
                enableBackoff[config.matcher] = nil
            } catch {
                let attempts = (enableBackoff[config.matcher]?.attempts ?? 0) + 1
                let delay = min(30.0, 3.0 * pow(2.0, Double(attempts - 1)))
                enableBackoff[config.matcher] = (attempts, Date().addingTimeInterval(delay))
                logger.error(
                    "reapply failed for \(config.displayName, privacy: .public) — retrying in \(Int(delay), privacy: .public)s: \(String(describing: error), privacy: .public)"
                )
            }
        }

        return enableBackoff.values.map(\.retryAt).min()
    }

    /// Polls `DisplayEnumerator.onlineDisplays()` for the freshly created virtual
    /// display to appear (0.1s interval, 2s ceiling — §4.4 step ⑤).
    private func waitUntilOnline(_ virtualID: CGDirectDisplayID) throws {
        let deadline = Date().addingTimeInterval(3.0)
        repeat {
            if DisplayEnumerator.onlineDisplays().contains(where: { $0.id == virtualID }) {
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        throw HiDPIError.virtualDisplayCreationFailed(
            "virtual display did not appear in CGGetOnlineDisplayList within timeout"
        )
    }
}
