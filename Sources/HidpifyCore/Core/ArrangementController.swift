import CoreGraphics
import os

/// A clean-state arrangement recorded as an **anchor + relative offsets**
/// (DESIGN.md §10.2). macOS renormalizes the whole coordinate space whenever
/// displays are added/removed/moved, so absolute origins don't survive; instead
/// we pin one stable `anchor` display and store every real display's origin as
/// an offset from the anchor. On restore we look up where the anchor sits *now*
/// and re-derive absolute targets, so the relative layout is preserved
/// regardless of how macOS shifted the coordinate space.
public struct ArrangementBaseline {
    /// The display all offsets are measured from. Chosen as a display hidpify
    /// never moves (a non-target real display), so it's a stable reference.
    public let anchor: DisplayMatcher
    /// Each real display's origin minus the anchor's origin (the anchor's own
    /// entry is (0,0)).
    public let relatives: [DisplayMatcher: CGPoint]

    public init(anchor: DisplayMatcher, relatives: [DisplayMatcher: CGPoint]) {
        self.anchor = anchor
        self.relatives = relatives
    }
}

/// Keeps unrelated monitors from drifting when hidpify's own display-config
/// changes (virtual create/remove, mirror, stream island move) make macOS
/// renormalize the arrangement (DESIGN.md §10).
public enum ArrangementController {
    private static let logger = Logger(subsystem: "dev.irae.hidpify", category: "ArrangementController")

    /// True when no virtual display created by this tool is currently online —
    /// i.e. the arrangement is only real displays and safe to capture.
    public static func noVirtualDisplaysOnline() -> Bool {
        !DisplayEnumerator.onlineDisplays().contains { $0.isOurVirtual }
    }

    /// Snapshots the current arrangement of online real displays as an
    /// anchor + relative offsets. Returns `nil` if there are no real displays.
    /// The anchor is preferably `CGMainDisplayID` (a display hidpify doesn't
    /// move); `preferAnchorNotIn` lets the caller steer the anchor away from
    /// displays it's about to move (e.g. configured stream/mirror targets).
    public static func snapshotRealDisplays(preferAnchorNotIn avoid: Set<DisplayMatcher> = []) -> ArrangementBaseline? {
        let reals = DisplayEnumerator.onlineDisplays().filter { !$0.isOurVirtual }
        guard !reals.isEmpty else { return nil }

        let mainID = CGMainDisplayID()
        // Prefer the main display, but never one the caller wants to keep off
        // the anchor; fall back to any display not in `avoid`; last resort, the
        // first real display (even if avoided — better an anchor than none).
        let anchorDisplay =
            reals.first { $0.id == mainID && !avoid.contains($0.matcher) }
            ?? reals.first { !avoid.contains($0.matcher) }
            ?? reals[0]

        let anchorOrigin = CGDisplayBounds(anchorDisplay.id).origin
        var relatives: [DisplayMatcher: CGPoint] = [:]
        for display in reals {
            let origin = CGDisplayBounds(display.id).origin
            relatives[display.matcher] = CGPoint(
                x: origin.x - anchorOrigin.x,
                y: origin.y - anchorOrigin.y
            )
        }
        return ArrangementBaseline(anchor: anchorDisplay.matcher, relatives: relatives)
    }

    /// The absolute origin `matcher`'s display should sit at, derived from the
    /// baseline and the anchor's *current* position. Returns `nil` if the
    /// anchor or the requested matcher isn't in the baseline / isn't online —
    /// used to place a mirror set's master (virtual) or a stream's virtual at
    /// the target physical display's slot.
    public static func absoluteTarget(
        for matcher: DisplayMatcher,
        baseline: ArrangementBaseline
    ) -> CGPoint? {
        guard let relative = baseline.relatives[matcher],
            let anchorDisplay = DisplayEnumerator.onlineDisplays()
                .first(where: { !$0.isOurVirtual && $0.matcher == baseline.anchor })
        else { return nil }
        let anchorOrigin = CGDisplayBounds(anchorDisplay.id).origin
        return CGPoint(x: anchorOrigin.x + relative.x, y: anchorOrigin.y + relative.y)
    }

    /// Repositions every online real display back to its baseline position,
    /// relative to wherever the anchor currently sits. Displays in `except` are
    /// left untouched (e.g. a stream session's physical, parked at its island).
    /// Displays already at their target are skipped (optimization + avoids
    /// provoking a needless reconfiguration callback — DESIGN.md §10.2 loop
    /// avoidance). Best-effort: failures are logged, never thrown.
    public static func restoreRealDisplaysToBaseline(
        _ baseline: ArrangementBaseline?,
        except: Set<CGDirectDisplayID>
    ) {
        guard let baseline else { return }
        let reals = DisplayEnumerator.onlineDisplays().filter { !$0.isOurVirtual }
        guard let anchorDisplay = reals.first(where: { $0.matcher == baseline.anchor }) else {
            logger.info("앵커 디스플레이가 온라인이 아니어서 배치 복원을 건너뜁니다")
            return
        }
        let anchorOrigin = CGDisplayBounds(anchorDisplay.id).origin

        let moves: [(display: CGDirectDisplayID, origin: CGPoint)] = reals
            .filter { !except.contains($0.id) }
            .compactMap { display in
                guard let relative = baseline.relatives[display.matcher] else { return nil }
                let target = CGPoint(x: anchorOrigin.x + relative.x, y: anchorOrigin.y + relative.y)
                let current = CGDisplayBounds(display.id).origin
                guard current != target else { return nil }
                return (display: display.id, origin: target)
            }

        guard !moves.isEmpty else { return }
        do {
            try MirrorController.setOrigins(moves)
            logger.info("배치 기준선으로 \(moves.count)개 디스플레이를 복원했습니다")
        } catch {
            logger.error("배치 기준선 복원 실패: \(String(describing: error), privacy: .public)")
        }
    }
}
