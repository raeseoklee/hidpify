import CoreGraphics
import Foundation

/// Snapshot of one online display, as reported by CoreGraphics at enumeration time.
public struct DisplayInfo {
    public let id: CGDirectDisplayID
    public let name: String
    public let vendorID: UInt32
    public let modelID: UInt32
    public let serialNumber: UInt32
    public let isBuiltin: Bool
    /// True when this display is a virtual display created by this tool
    /// (identified by `VirtualDisplayFactory.vendorID`).
    public let isOurVirtual: Bool
    /// Rotation in degrees (0/90/180/270), from `CGDisplayRotation`.
    public let rotation: Double
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    /// Display this one mirrors (`CGDisplayMirrorsDisplay`); 0 when not mirroring.
    public let mirrorsDisplayID: CGDirectDisplayID
    /// Physical panel size in millimeters, from `CGDisplayScreenSize`. 0 when unknown
    /// (e.g. some virtual displays).
    public let physicalWidthMM: Double
    public let physicalHeightMM: Double

    public init(
        id: CGDirectDisplayID,
        name: String,
        vendorID: UInt32,
        modelID: UInt32,
        serialNumber: UInt32,
        isBuiltin: Bool,
        isOurVirtual: Bool,
        rotation: Double,
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        mirrorsDisplayID: CGDirectDisplayID,
        physicalWidthMM: Double = 0,
        physicalHeightMM: Double = 0
    ) {
        self.id = id
        self.name = name
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
        self.isBuiltin = isBuiltin
        self.isOurVirtual = isOurVirtual
        self.rotation = rotation
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.mirrorsDisplayID = mirrorsDisplayID
        self.physicalWidthMM = physicalWidthMM
        self.physicalHeightMM = physicalHeightMM
    }

    public var isHiDPI: Bool { pixelWidth > logicalWidth }
    public var matcher: DisplayMatcher {
        DisplayMatcher(vendorID: vendorID, modelID: modelID, serialNumber: serialNumber)
    }

    /// Logical diagonal pixels ÷ physical diagonal inches. 0 when the physical
    /// size is unknown (e.g. some virtual displays).
    public var logicalPPI: Double {
        let diagonalInches = (physicalWidthMM * physicalWidthMM + physicalHeightMM * physicalHeightMM)
            .squareRoot() / 25.4
        guard diagonalInches > 0 else { return 0 }
        let diagonalLogicalPixels = (Double(logicalWidth * logicalWidth + logicalHeight * logicalHeight))
            .squareRoot()
        return diagonalLogicalPixels / diagonalInches
    }
}

/// Stable identity of a physical display across reconnects/reboots.
/// `CGDirectDisplayID` is not stable, so it is never persisted.
/// `Hashable` so it can key arrangement-baseline dictionaries (DESIGN.md §10.2).
public struct DisplayMatcher: Codable, Hashable {
    public let vendorID: UInt32
    public let modelID: UInt32
    public let serialNumber: UInt32

    public init(vendorID: UInt32, modelID: UInt32, serialNumber: UInt32) {
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
    }
}

/// How a HiDPI target's virtual display reaches the physical panel (DESIGN.md §9.1).
public enum ScalingMode: String, Codable, Sendable {
    case mirror
    case stream
}

/// One persisted HiDPI target: "make this physical display look like W×H in HiDPI".
public struct TargetConfig: Codable {
    public var matcher: DisplayMatcher
    /// Display name at the time of configuration; informational only.
    public var displayName: String
    public var looksLikeWidth: Int
    public var looksLikeHeight: Int
    public var refreshRate: Double
    /// Fixed serial for the virtual display so macOS remembers arrangement (FR-6).
    public var virtualSerialNum: UInt32
    /// Mirroring (default) or streaming (DESIGN.md §9.4).
    public var mode: ScalingMode

    public init(
        matcher: DisplayMatcher,
        displayName: String,
        looksLikeWidth: Int,
        looksLikeHeight: Int,
        refreshRate: Double,
        virtualSerialNum: UInt32,
        mode: ScalingMode = .mirror
    ) {
        self.matcher = matcher
        self.displayName = displayName
        self.looksLikeWidth = looksLikeWidth
        self.looksLikeHeight = looksLikeHeight
        self.refreshRate = refreshRate
        self.virtualSerialNum = virtualSerialNum
        self.mode = mode
    }

    /// Custom decoding for backward compatibility: config.json files written before
    /// `mode` existed lack the key entirely, so it defaults to `.mirror` (DESIGN.md §9.4).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        matcher = try container.decode(DisplayMatcher.self, forKey: .matcher)
        displayName = try container.decode(String.self, forKey: .displayName)
        looksLikeWidth = try container.decode(Int.self, forKey: .looksLikeWidth)
        looksLikeHeight = try container.decode(Int.self, forKey: .looksLikeHeight)
        refreshRate = try container.decode(Double.self, forKey: .refreshRate)
        virtualSerialNum = try container.decode(UInt32.self, forKey: .virtualSerialNum)
        mode = try container.decodeIfPresent(ScalingMode.self, forKey: .mode) ?? .mirror
    }
}

public struct AppConfig: Codable {
    public var targets: [TargetConfig] = []

    public init(targets: [TargetConfig] = []) {
        self.targets = targets
    }
}

public enum HiDPIError: Error, CustomStringConvertible {
    case privateAPIUnavailable
    case displayNotFound(String)
    case virtualDisplayCreationFailed(String)
    case mirroringFailed(CGError)
    case modeNotFound(String)
    case modeSetFailed(CGError)
    case configError(String)
    case launchAgentError(String)
    case streamingFailed(String)

    public var description: String {
        switch self {
        case .privateAPIUnavailable:
            return "CGVirtualDisplay private API를 찾을 수 없습니다 (macOS 버전 비호환 가능)."
        case .displayNotFound(let detail):
            return "대상 디스플레이를 찾을 수 없습니다: \(detail)"
        case .virtualDisplayCreationFailed(let detail):
            return "가상 디스플레이 생성 실패: \(detail)"
        case .mirroringFailed(let err):
            return "미러링 구성 실패 (CGError \(err.rawValue))"
        case .modeNotFound(let detail):
            return "HiDPI 모드를 찾을 수 없습니다: \(detail)"
        case .modeSetFailed(let err):
            return "디스플레이 모드 설정 실패 (CGError \(err.rawValue))"
        case .configError(let detail):
            return "설정 파일 오류: \(detail)"
        case .launchAgentError(let detail):
            return "LaunchAgent 오류: \(detail)"
        case .streamingFailed(let detail):
            return "스트리밍 모드 오류: \(detail)"
        }
    }
}
