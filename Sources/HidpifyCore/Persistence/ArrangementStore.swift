import CoreGraphics
import Foundation
import os

/// Persists the "clean" baseline arrangement of real (non-virtual) displays —
/// captured while no session is active — so it survives daemon restarts
/// (DESIGN.md §10.2).
///
/// Stored as an **anchor + relative offsets**, not absolute origins: macOS
/// renormalizes the whole coordinate space whenever displays are added/moved,
/// so absolute origins captured earlier become meaningless. Instead we pin one
/// stable anchor display and record every other display's origin *relative to*
/// the anchor; on restore we re-anchor to wherever that display sits now. Keyed
/// by `DisplayMatcher` (stable across reconnects), not `CGDirectDisplayID`.
/// Sibling of `ConfigStore`, same `~/.config/hidpify` directory.
public enum ArrangementStore {
    private static let logger = Logger(subsystem: "dev.irae.hidpify", category: "ArrangementStore")

    public static var arrangementURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hidpify/arrangement.json")
    }

    private struct Offset: Codable {
        var x: CGFloat
        var y: CGFloat
    }

    private struct Persisted: Codable {
        var anchor: String
        var relatives: [String: Offset]
    }

    /// Loads the persisted baseline, or `nil` when the file is missing (normal
    /// before the first clean capture) or corrupt (logged).
    public static func load() -> ArrangementBaseline? {
        let url = arrangementURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let raw = try JSONDecoder().decode(Persisted.self, from: data)
            guard let anchor = matcher(fromKey: raw.anchor) else { return nil }
            var relatives: [DisplayMatcher: CGPoint] = [:]
            for (key, offset) in raw.relatives {
                guard let matcher = matcher(fromKey: key) else { continue }
                relatives[matcher] = CGPoint(x: offset.x, y: offset.y)
            }
            return ArrangementBaseline(anchor: anchor, relatives: relatives)
        } catch {
            logger.warning(
                "배치 기준선 파일이 손상되어 무시합니다: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Writes the baseline as pretty-printed JSON. Best-effort: failures are
    /// logged, never thrown — the next clean-state opportunity retries.
    public static func save(_ baseline: ArrangementBaseline) {
        let url = arrangementURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            var relatives: [String: Offset] = [:]
            for (matcher, point) in baseline.relatives {
                relatives[key(for: matcher)] = Offset(x: point.x, y: point.y)
            }
            let persisted = Persisted(anchor: key(for: baseline.anchor), relatives: relatives)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persisted)
            try data.write(to: url, options: .atomic)
        } catch {
            logger.warning("배치 기준선 저장 실패: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func key(for matcher: DisplayMatcher) -> String {
        "\(matcher.vendorID):\(matcher.modelID):\(matcher.serialNumber)"
    }

    private static func matcher(fromKey key: String) -> DisplayMatcher? {
        let parts = key.split(separator: ":")
        guard parts.count == 3,
            let vendorID = UInt32(parts[0]),
            let modelID = UInt32(parts[1]),
            let serialNumber = UInt32(parts[2])
        else {
            return nil
        }
        return DisplayMatcher(vendorID: vendorID, modelID: modelID, serialNumber: serialNumber)
    }
}
