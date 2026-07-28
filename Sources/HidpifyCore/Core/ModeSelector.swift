import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "dev.irae.hidpify", category: "ModeSelector")

/// Enumerates a display's full mode list and switches it into the HiDPI
/// mode whose logical size matches `looksLikeWidth x looksLikeHeight`.
public enum ModeSelector {
    public static func setHiDPIMode(
        displayID: CGDirectDisplayID,
        looksLikeWidth: Int,
        looksLikeHeight: Int,
        refreshRate: Double?
    ) throws {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            throw HiDPIError.modeNotFound("\(looksLikeWidth)x\(looksLikeHeight) HiDPI (모드 목록을 가져올 수 없음)")
        }

        let candidates = modes.filter { mode in
            mode.width == looksLikeWidth
                && mode.height == looksLikeHeight
                && mode.pixelWidth == looksLikeWidth * 2
        }

        guard !candidates.isEmpty else {
            let summary = modes
                .map { "\($0.width)x\($0.height)(px \($0.pixelWidth)x\($0.pixelHeight))@\($0.refreshRate)" }
                .joined(separator: ", ")
            throw HiDPIError.modeNotFound("\(looksLikeWidth)x\(looksLikeHeight) HiDPI (사용 가능: \(summary))")
        }

        let selected: CGDisplayMode
        if let refreshRate {
            selected = candidates.min {
                abs($0.refreshRate - refreshRate) < abs($1.refreshRate - refreshRate)
            }!
        } else {
            selected = candidates[0]
        }

        var configRef: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&configRef)
        guard err == .success, let config = configRef else {
            throw HiDPIError.modeSetFailed(err)
        }

        err = CGConfigureDisplayWithDisplayMode(config, displayID, selected, nil)
        if err != .success {
            CGCancelDisplayConfiguration(config)
            throw HiDPIError.modeSetFailed(err)
        }

        err = CGCompleteDisplayConfiguration(config, .permanently)
        if err != .success {
            throw HiDPIError.modeSetFailed(err)
        }

        logger.info("HiDPI mode \(looksLikeWidth)x\(looksLikeHeight) applied to display \(displayID)")
    }

    /// The display's current mode, for capturing before a change so it can be
    /// restored later.
    static func currentMode(_ displayID: CGDirectDisplayID) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(displayID)
    }

    /// The mode with the most physical pixels (ties broken toward a 1× mode,
    /// where logical == pixel). Used to drive a streaming target's physical
    /// panel at its full native resolution so the player window can show the
    /// captured HiDPI content at full panel density (DESIGN.md §9.2 step 3).
    static func maxPixelMode(_ displayID: CGDirectDisplayID) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }
        return modes.max { a, b in
            let pa = a.pixelWidth * a.pixelHeight
            let pb = b.pixelWidth * b.pixelHeight
            if pa != pb { return pa < pb }
            // Same pixel count: prefer the 1× variant (logical == pixel) so the
            // player window isn't itself HiDPI-scaled on top of the stream.
            let a1x = a.width == a.pixelWidth ? 1 : 0
            let b1x = b.width == b.pixelWidth ? 1 : 0
            return a1x < b1x
        }
    }

    /// Applies an explicit `CGDisplayMode` (used to set a streaming target to
    /// its native resolution and to restore it afterward).
    static func setMode(_ displayID: CGDirectDisplayID, _ mode: CGDisplayMode) throws {
        var configRef: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&configRef)
        guard err == .success, let config = configRef else {
            throw HiDPIError.modeSetFailed(err)
        }
        err = CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil)
        if err != .success {
            CGCancelDisplayConfiguration(config)
            throw HiDPIError.modeSetFailed(err)
        }
        err = CGCompleteDisplayConfiguration(config, .permanently)
        if err != .success {
            throw HiDPIError.modeSetFailed(err)
        }
    }
}
