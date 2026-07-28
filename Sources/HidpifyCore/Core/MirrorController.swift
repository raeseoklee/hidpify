import CoreGraphics
import os

private let logger = Logger(subsystem: "dev.irae.hidpify", category: "MirrorController")

/// Wraps the public display-mirroring configuration API: `physical` becomes
/// a mirror of `virtual` (the virtual display is the mirror set's master).
public enum MirrorController {
    public static func mirror(physical: CGDirectDisplayID, toVirtual virtualID: CGDirectDisplayID) throws {
        try configureMirror(physical: physical, master: virtualID)
        logger.info("Display \(physical) now mirrors \(virtualID)")
    }

    public static func stopMirroring(physical: CGDirectDisplayID) throws {
        try configureMirror(physical: physical, master: kCGNullDirectDisplay)
        logger.info("Display \(physical) mirroring stopped")
    }

    /// Batch-repositions displays in one atomic configuration transaction
    /// (DESIGN.md §9.2 step 2 — swapping the virtual/physical arrangement slots
    /// for streaming mode). Any single failure cancels the whole batch (§4.8).
    public static func setOrigins(_ moves: [(display: CGDirectDisplayID, origin: CGPoint)]) throws {
        var configRef: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&configRef)
        guard err == .success, let config = configRef else {
            throw HiDPIError.mirroringFailed(err)
        }

        for move in moves {
            err = CGConfigureDisplayOrigin(config, move.display, Int32(move.origin.x), Int32(move.origin.y))
            if err != .success {
                CGCancelDisplayConfiguration(config)
                throw HiDPIError.mirroringFailed(err)
            }
        }

        err = CGCompleteDisplayConfiguration(config, .permanently)
        if err != .success {
            throw HiDPIError.mirroringFailed(err)
        }

        logger.info("Repositioned \(moves.count) display(s)")
    }

    private static func configureMirror(physical: CGDirectDisplayID, master: CGDirectDisplayID) throws {
        var configRef: CGDisplayConfigRef?
        var err = CGBeginDisplayConfiguration(&configRef)
        guard err == .success, let config = configRef else {
            throw HiDPIError.mirroringFailed(err)
        }

        err = CGConfigureDisplayMirrorOfDisplay(config, physical, master)
        if err != .success {
            CGCancelDisplayConfiguration(config)
            throw HiDPIError.mirroringFailed(err)
        }

        err = CGCompleteDisplayConfiguration(config, .permanently)
        if err != .success {
            throw HiDPIError.mirroringFailed(err)
        }
    }
}
