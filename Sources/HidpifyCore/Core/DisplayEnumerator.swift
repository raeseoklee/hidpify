import AppKit
import CoreGraphics
import os

private let logger = Logger(subsystem: "dev.irae.hidpify", category: "DisplayEnumerator")

/// Enumerates online displays via CoreGraphics and resolves human-readable
/// names through `NSScreen` (no private CoreDisplay lookups).
public enum DisplayEnumerator {
    private static let maxDisplays: UInt32 = 16

    public static func onlineDisplays() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var count: UInt32 = 0
        let err = CGGetOnlineDisplayList(maxDisplays, &ids, &count)
        guard err == .success else {
            logger.error("CGGetOnlineDisplayList failed: \(err.rawValue)")
            return []
        }

        let names = screenNamesByDisplayID()
        return ids.prefix(Int(count)).map { makeDisplayInfo(id: $0, names: names) }
    }

    /// Finds a physical display by matcher, excluding this tool's own virtual display.
    public static func find(matcher: DisplayMatcher) -> DisplayInfo? {
        onlineDisplays().first { !$0.isOurVirtual && $0.matcher == matcher }
    }

    /// Picks the default HiDPI target: the first non-builtin, non-virtual,
    /// non-HiDPI, non-mirroring display.
    public static func defaultTarget() -> DisplayInfo? {
        onlineDisplays().first {
            !$0.isBuiltin && !$0.isOurVirtual && !$0.isHiDPI && $0.mirrorsDisplayID == 0
        }
    }

    private static func screenNamesByDisplayID() -> [CGDirectDisplayID: String] {
        var map: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            map[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return map
    }

    private static func makeDisplayInfo(id: CGDirectDisplayID, names: [CGDirectDisplayID: String]) -> DisplayInfo {
        let vendorID = CGDisplayVendorNumber(id)
        var logicalWidth = 0
        var logicalHeight = 0
        var pixelWidth = 0
        var pixelHeight = 0
        var refreshRate = 0.0

        if let mode = CGDisplayCopyDisplayMode(id) {
            logicalWidth = mode.width
            logicalHeight = mode.height
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            refreshRate = mode.refreshRate
        }

        let physicalSize = CGDisplayScreenSize(id)

        return DisplayInfo(
            id: id,
            name: names[id] ?? "Display \(id)",
            vendorID: vendorID,
            modelID: CGDisplayModelNumber(id),
            serialNumber: CGDisplaySerialNumber(id),
            isBuiltin: CGDisplayIsBuiltin(id) != 0,
            isOurVirtual: vendorID == VirtualDisplayFactory.vendorID,
            rotation: CGDisplayRotation(id),
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            refreshRate: refreshRate,
            mirrorsDisplayID: CGDisplayMirrorsDisplay(id),
            physicalWidthMM: physicalSize.width,
            physicalHeightMM: physicalSize.height
        )
    }
}
