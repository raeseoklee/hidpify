import ColorSync
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "dev.irae.hidpify", category: "ColorProfileController")

/// Enough information to undo `ColorProfileController.injectProfile` later:
/// which ColorSync device/profile slot was touched, and what (if anything)
/// occupied that slot before injection so `restore` can put it back exactly.
public struct ColorProfileRestore {
    fileprivate let deviceUUID: CFUUID
    fileprivate let profileID: CFString
    /// Custom profile URL that was already set on `profileID` before
    /// injection, or `nil` if the device had no custom override (i.e. was
    /// showing its factory/EDID profile) — `restore` then clears the
    /// override instead of pointing it at a URL, returning the display to
    /// its factory profile.
    fileprivate let previousCustomProfileURL: URL?
}

/// Injects a virtual display's ICC profile onto a physical display's
/// ColorSync device entry for the duration of a streaming session (DESIGN.md
/// §9). The physical panel's own EDID-derived profile tends to over-claim
/// gamut, which visibly washes out color relative to the sRGB-calibrated
/// virtual source (see `VirtualDisplayFactory`'s sRGB/Rec.709 primaries).
/// Mirroring doesn't need this: the physical display inherits the mirror
/// master's (virtual) profile automatically. Streaming instead feeds pixels
/// through a player window (DESIGN.md §9.2 step 5), so ColorSync still
/// applies the physical panel's own profile unless overridden here.
///
/// Uses the public ColorSync device API (`ColorSyncDevice.h`) — no private
/// API involved. All failures are logged and degrade to a `nil` return
/// rather than throwing, so a color-profile problem never blocks streaming
/// (DESIGN.md §4.8's "never leave a half-applied state" principle extended:
/// here the safe half-applied state is simply "no color override").
public enum ColorProfileController {
    private static let fallbackSRGBProfileURL = URL(
        fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc"
    )

    /// Copies `sourceDisplayID`'s (virtual) current ICC profile and sets it
    /// as `targetDisplayID`'s (physical) custom ColorSync profile. Returns
    /// `nil` on any failure — logged, never thrown — so the caller can
    /// proceed without color correction rather than fail the whole session.
    public static func injectProfile(
        from sourceDisplayID: CGDirectDisplayID,
        to targetDisplayID: CGDirectDisplayID
    ) -> ColorProfileRestore? {
        guard let targetUUID = CGDisplayCreateUUIDFromDisplayID(targetDisplayID)?.takeRetainedValue() else {
            logger.error(
                "target display \(targetDisplayID, privacy: .public)의 ColorSync UUID를 얻지 못했습니다 (CGDisplayCreateUUIDFromDisplayID)"
            )
            return nil
        }
        let deviceClass: CFString = kColorSyncDisplayDeviceClass.takeUnretainedValue()

        guard
            let deviceInfo = ColorSyncDeviceCopyDeviceInfo(deviceClass, targetUUID)?.takeRetainedValue()
                as? [String: Any]
        else {
            logger.error(
                "target display \(targetDisplayID, privacy: .public)의 ColorSync 디바이스 정보를 얻지 못했습니다 (ColorSyncDeviceCopyDeviceInfo)"
            )
            return nil
        }

        guard let profileID = resolveDefaultProfileID(deviceInfo: deviceInfo) else {
            logger.error(
                "target display \(targetDisplayID, privacy: .public)의 기본 factory profile ID를 확인하지 못했습니다"
            )
            return nil
        }

        let previousCustomURL = existingCustomProfileURL(deviceInfo: deviceInfo, profileID: profileID)

        let profileURL = writeSourceProfile(sourceDisplayID: sourceDisplayID, targetDisplayID: targetDisplayID)
            ?? fallbackSRGBProfileURL

        let setDict = [profileID as String: profileURL as CFURL] as CFDictionary
        guard ColorSyncDeviceSetCustomProfiles(deviceClass, targetUUID, setDict) else {
            logger.error(
                "target display \(targetDisplayID, privacy: .public)에 프로필 주입 실패 (ColorSyncDeviceSetCustomProfiles)"
            )
            return nil
        }

        logger.info(
            "target display \(targetDisplayID, privacy: .public)에 소스 \(sourceDisplayID, privacy: .public)의 색 프로필을 주입했습니다 (\(profileURL.path, privacy: .public))"
        )

        return ColorProfileRestore(
            deviceUUID: targetUUID,
            profileID: profileID,
            previousCustomProfileURL: previousCustomURL
        )
    }

    /// Undoes `injectProfile`: restores whatever custom-profile state
    /// (present or absent) the target device had before injection.
    /// Best-effort — logs on failure, never throws (mirrors `disable`'s
    /// `try?`-everywhere style in `SessionController`).
    public static func restore(_ token: ColorProfileRestore) {
        let deviceClass: CFString = kColorSyncDisplayDeviceClass.takeUnretainedValue()
        let value: CFTypeRef = token.previousCustomProfileURL.map { $0 as CFURL } ?? (kCFNull as CFTypeRef)
        let dict = [token.profileID as String: value] as CFDictionary

        if ColorSyncDeviceSetCustomProfiles(deviceClass, token.deviceUUID, dict) {
            logger.info("색 프로필을 원복했습니다 (profileID \(token.profileID as String, privacy: .public))")
        } else {
            logger.error(
                "색 프로필 원복 실패 (ColorSyncDeviceSetCustomProfiles, profileID \(token.profileID as String, privacy: .public))"
            )
        }
    }

    // MARK: - ColorSync device-info parsing

    /// `deviceInfo[kColorSyncFactoryProfiles]` is itself a dictionary keyed by
    /// ProfileID, with one extra sibling key (`kColorSyncDeviceDefaultProfileID`)
    /// whose value is the ProfileID of the default/current factory profile.
    /// That key may be absent when the device only has one factory profile
    /// (ColorSyncDevice.h doc comment on `ColorSyncRegisterDevice`), in which
    /// case the sole remaining key is used.
    private static func resolveDefaultProfileID(deviceInfo: [String: Any]) -> CFString? {
        let factoryKey = kColorSyncFactoryProfiles.takeUnretainedValue() as String
        guard let factoryProfiles = deviceInfo[factoryKey] as? [String: Any] else {
            return nil
        }

        let defaultKey = kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String
        if let defaultID = factoryProfiles[defaultKey] as? String {
            return defaultID as CFString
        }

        let remainingProfileKeys = factoryProfiles.keys.filter { $0 != defaultKey }
        if remainingProfileKeys.count == 1 {
            return remainingProfileKeys[0] as CFString
        }
        return nil
    }

    /// `deviceInfo[kColorSyncCustomProfiles]` is a flat dictionary keyed by
    /// the *resolved* ProfileID (unlike the Set call, which also accepts the
    /// `kColorSyncDeviceDefaultProfileID` placeholder as a key) — values are
    /// either a `CFURL` or `kCFNull` when no override is set for that slot.
    private static func existingCustomProfileURL(deviceInfo: [String: Any], profileID: CFString) -> URL? {
        let customKey = kColorSyncCustomProfiles.takeUnretainedValue() as String
        guard let customProfiles = deviceInfo[customKey] as? [String: Any] else {
            return nil
        }
        return customProfiles[profileID as String] as? URL
    }

    // MARK: - Source profile extraction

    /// Copies `sourceDisplayID`'s current ICC profile to a temp `.icc` file
    /// named after `targetDisplayID` (so concurrent sessions for different
    /// physical targets don't collide). Returns `nil` (never throws) on any
    /// failure — the caller falls back to the system sRGB profile.
    private static func writeSourceProfile(
        sourceDisplayID: CGDirectDisplayID,
        targetDisplayID: CGDirectDisplayID
    ) -> URL? {
        guard let profile = ColorSyncProfileCreateWithDisplayID(sourceDisplayID)?.takeRetainedValue() else {
            logger.error(
                "소스 디스플레이 \(sourceDisplayID, privacy: .public)의 ColorSync 프로필을 얻지 못했습니다 (ColorSyncProfileCreateWithDisplayID)"
            )
            return nil
        }
        guard let data = ColorSyncProfileCopyData(profile, nil)?.takeRetainedValue() as Data? else {
            logger.error(
                "소스 디스플레이 \(sourceDisplayID, privacy: .public)의 프로필 데이터 복사 실패 (ColorSyncProfileCopyData)"
            )
            return nil
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidpify-stream-color-\(targetDisplayID).icc")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            logger.error("임시 프로필 파일 쓰기 실패: \(String(describing: error), privacy: .public)")
            return nil
        }
        return url
    }
}
