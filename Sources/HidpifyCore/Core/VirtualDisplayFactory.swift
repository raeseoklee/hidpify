import CHiDPIPrivate
import CoreGraphics
import Foundation
import os

/// Owns a `CGVirtualDisplay` instance. The virtual display is detached from
/// the system as soon as this handle is deallocated.
public final class VirtualDisplayHandle {
    public let displayID: CGDirectDisplayID
    private let retained: AnyObject

    public init(displayID: CGDirectDisplayID, retained: AnyObject) {
        self.displayID = displayID
        self.retained = retained
    }
}

/// Creates `CGVirtualDisplay` instances via CoreGraphics private API
/// (see DESIGN.md §2.2.1 and Sources/CHiDPIPrivate for provenance).
public enum VirtualDisplayFactory {
    /// "HI" in ASCII — arbitrary vendor id marking virtual displays created by this tool.
    public static let vendorID: UInt32 = 0x4849

    private static let logger = Logger(subsystem: "dev.irae.hidpify", category: "VirtualDisplayFactory")

    /// True when all four private classes this tool depends on are present at runtime.
    public static func isAPIAvailable() -> Bool {
        let requiredClasses = [
            "CGVirtualDisplayDescriptor",
            "CGVirtualDisplay",
            "CGVirtualDisplayMode",
            "CGVirtualDisplaySettings",
        ]
        return requiredClasses.allSatisfy { NSClassFromString($0) != nil }
    }

    public static func create(
        name: String,
        looksLikeWidth: Int,
        looksLikeHeight: Int,
        refreshRates: [Double],
        serialNum: UInt32
    ) throws -> VirtualDisplayHandle {
        guard isAPIAvailable() else {
            throw HiDPIError.privateAPIUnavailable
        }

        guard let descriptor = CGVirtualDisplayDescriptor() else {
            throw HiDPIError.virtualDisplayCreationFailed("CGVirtualDisplayDescriptor() returned nil")
        }
        descriptor.queue = DispatchQueue.global(qos: .userInteractive)
        descriptor.name = name
        // sRGB/Rec.709 chromaticities with a D65 white point, so the profile
        // macOS synthesizes for the virtual display targets sRGB. Panels whose
        // EDID over-claims gamut (e.g. LG advertising red x=0.662 on an ~sRGB
        // panel) otherwise get visibly washed-out, compressed color.
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.3290)
        descriptor.redPrimary = CGPoint(x: 0.640, y: 0.330)
        descriptor.greenPrimary = CGPoint(x: 0.300, y: 0.600)
        descriptor.bluePrimary = CGPoint(x: 0.150, y: 0.060)
        descriptor.maxPixelsWide = UInt32(2 * looksLikeWidth)
        descriptor.maxPixelsHigh = UInt32(2 * looksLikeHeight)

        let diagonalRatio = 24.0 * 25.4
            / (Double(looksLikeWidth * looksLikeWidth + looksLikeHeight * looksLikeHeight)).squareRoot()
        descriptor.sizeInMillimeters = CGSize(
            width: Double(looksLikeWidth) * diagonalRatio,
            height: Double(looksLikeHeight) * diagonalRatio
        )

        descriptor.serialNum = serialNum
        let productWidthComponent: Int = min(looksLikeWidth - 1, 255) * 256
        let productHeightComponent: Int = min(looksLikeHeight - 1, 255)
        descriptor.productID = UInt32(productWidthComponent + productHeightComponent)
        descriptor.vendorID = vendorID

        // Objective-C import may surface this initializer as optional/IUO; guard defensively.
        guard let display = CGVirtualDisplay(descriptor: descriptor) else {
            throw HiDPIError.virtualDisplayCreationFailed("CGVirtualDisplay(descriptor:) returned nil")
        }

        var seenRates = Set<Double>()
        let uniqueRates = refreshRates.filter { seenRates.insert($0).inserted }
        // WindowServer가 "looks like W×H (백킹 2W×2H)" HiDPI 모드를 파생하려면
        // 1x 모드와 2x 모드가 모두 선언되어 있어야 한다 (2x 단독 선언 시 파생 안 됨).
        let modes: [CGVirtualDisplayMode] = uniqueRates.flatMap { rate in
            [
                CGVirtualDisplayMode(
                    width: UInt32(looksLikeWidth),
                    height: UInt32(looksLikeHeight),
                    refreshRate: rate
                ),
                CGVirtualDisplayMode(
                    width: UInt32(2 * looksLikeWidth),
                    height: UInt32(2 * looksLikeHeight),
                    refreshRate: rate
                ),
            ]
        }

        guard let settings = CGVirtualDisplaySettings() else {
            throw HiDPIError.virtualDisplayCreationFailed("CGVirtualDisplaySettings() returned nil")
        }
        settings.hiDPI = 1
        settings.modes = modes

        guard display.applySettings(settings) else {
            throw HiDPIError.virtualDisplayCreationFailed("applySettings(_:) returned false")
        }

        let displayID = CGDirectDisplayID(display.displayID)
        logger.info("created virtual display \(displayID, privacy: .public) (\(name, privacy: .public))")

        return VirtualDisplayHandle(displayID: displayID, retained: display)
    }
}
