import Darwin
import Foundation
import os

/// Installs/uninstalls the `dev.irae.hidpify` LaunchAgent that keeps `hidpify daemon` resident.
public enum LaunchAgentInstaller {
    public static let label = "dev.irae.hidpify"

    private static let logger = Logger(subsystem: "dev.irae.hidpify", category: "launchagent")

    private static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    private static var logFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/hidpify.log")
    }

    private static var uid: uid_t { getuid() }
    private static var domainTarget: String { "gui/\(uid)" }
    private static var serviceTarget: String { "gui/\(uid)/\(label)" }

    /// Writes the LaunchAgent plist and (re)loads it via `launchctl bootstrap`.
    /// - Parameter binaryPath: Absolute path to the `hidpify` binary to run as `daemon`.
    ///   Resolution priority (see `resolvedBinaryPath`):
    ///   ① this explicit argument, when non-nil ② `Hidpify.app`'s bundled `hidpify`
    ///   binary (`/Applications/Hidpify.app/Contents/MacOS/hidpify` or the `~/Applications`
    ///   equivalent), if present — preferred so the daemon runs from inside the app bundle,
    ///   which gives TCC (Screen Recording, System Settings) a chance to attribute the grant
    ///   to the Hidpify app's icon/name instead of a bare unbundled binary (best-effort under
    ///   ad-hoc signing — not guaranteed on every macOS version) ③ the currently running
    ///   executable's path (`CommandLine.arguments.first`), which is only meaningful when
    ///   called from the `hidpify` CLI itself — callers outside that process (e.g. the menu
    ///   bar app) should pass an explicit path if they want to bypass ②.
    public static func install(binaryPath: String? = nil) throws {
        let binaryPath = try resolvedBinaryPath(binaryPath)
        let plistDict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binaryPath, "daemon"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardOutPath": logFileURL.path,
            "StandardErrorPath": logFileURL.path,
        ]

        let data: Data
        do {
            data = try PropertyListSerialization.data(
                fromPropertyList: plistDict,
                format: .xml,
                options: 0
            )
        } catch {
            throw HiDPIError.launchAgentError("plist 직렬화 실패: \(error.localizedDescription)")
        }

        do {
            try FileManager.default.createDirectory(
                at: plistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: plistURL, options: .atomic)
        } catch {
            throw HiDPIError.launchAgentError("plist 파일 작성 실패: \(error.localizedDescription)")
        }

        // Tear down any existing registration first; failure here just means it wasn't loaded.
        _ = runLaunchctl(["bootout", serviceTarget])

        // Booting out a *running* daemon returns immediately, but the daemon's
        // SIGTERM teardown (which detaches virtual displays → a display
        // reconfiguration burst) can still be in flight; bootstrapping into that
        // churn fails and leaves NO daemon running. Wait until the old service is
        // actually gone, then retry the bootstrap a few times, clearing any
        // partial state between attempts.
        for _ in 0..<10 {
            if runLaunchctl(["print", serviceTarget]) != 0 { break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        var bootstrapStatus: Int32 = -1
        for attempt in 0..<5 {
            bootstrapStatus = runLaunchctl(["bootstrap", domainTarget, plistURL.path])
            if bootstrapStatus == 0 { break }
            if attempt < 4 {
                Thread.sleep(forTimeInterval: 0.5)
                _ = runLaunchctl(["bootout", serviceTarget])
            }
        }
        guard bootstrapStatus == 0 else {
            throw HiDPIError.launchAgentError("launchctl bootstrap 실패 (exit code \(bootstrapStatus))")
        }
    }

    /// Unloads the LaunchAgent via `launchctl bootout` and removes its plist.
    public static func uninstall() throws {
        let bootoutStatus = runLaunchctl(["bootout", serviceTarget])
        if bootoutStatus != 0 {
            logger.info("launchctl bootout exit code \(bootoutStatus, privacy: .public) (에이전트가 이미 언로드 상태일 수 있음)")
        }

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: plistURL.path) else { return }
        do {
            try fileManager.removeItem(at: plistURL)
        } catch {
            throw HiDPIError.launchAgentError("plist 파일 삭제 실패: \(error.localizedDescription)")
        }
    }

    /// True when `launchctl print` succeeds for our service target.
    public static func isLoaded() -> Bool {
        runLaunchctl(["print", serviceTarget]) == 0
    }

    /// True when the LaunchAgent plist exists on disk, regardless of whether it's
    /// currently bootstrapped/running. Distinguishes "installed for Start at Login"
    /// from "running right now" (`isLoaded()`).
    public static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The absolute binary path the installed LaunchAgent runs as `daemon`
    /// (`ProgramArguments[0]`), or `nil` if not installed / unreadable. Lets a
    /// caller detect when the daemon is pointed at a different binary than it
    /// wants (e.g. migrating an old install onto a stable-cdhash binary).
    public static func installedBinaryPath() -> String? {
        guard let data = try? Data(contentsOf: plistURL),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
            let dict = plist as? [String: Any],
            let args = dict["ProgramArguments"] as? [String]
        else { return nil }
        return args.first
    }

    /// (Re)bootstraps the existing plist via `launchctl bootstrap`, without writing
    /// a new plist. Returns `false` if no plist is installed yet — use `install()`
    /// for that case.
    @discardableResult
    public static func load() -> Bool {
        guard isInstalled() else { return false }
        return runLaunchctl(["bootstrap", domainTarget, plistURL.path]) == 0
    }

    /// Unloads the running daemon via `launchctl bootout` but leaves the plist in
    /// place, so it comes back on the next login via `RunAtLoad`. Use `uninstall()`
    /// to remove the plist entirely.
    @discardableResult
    public static func stop() -> Bool {
        runLaunchctl(["bootout", serviceTarget]) == 0
    }

    /// Restarts the running daemon in place via `launchctl kickstart -k`.
    @discardableResult
    public static func kickstart() -> Bool {
        runLaunchctl(["kickstart", "-k", serviceTarget]) == 0
    }

    // MARK: - Helpers

    /// Resolves the `hidpify` binary the LaunchAgent should run as `daemon`:
    /// ① an explicit path if given, else ② the currently running executable.
    ///
    /// NOTE: we deliberately do NOT point the daemon at a copy nested inside
    /// `Hidpify.app/Contents/MacOS/`. That was tried (to get a nicer TCC
    /// Screen-Recording icon/name) but the ad-hoc code signature of a
    /// launchd-run helper inside an ad-hoc-signed bundle gets rejected by
    /// taskgated ("Invalid Signature"), so the daemon is SIGKILLed on launch
    /// and `KeepAlive` restarts it in a tight crash loop — visible as the
    /// mirror/stream flapping on and off. Running from a standalone,
    /// independently-signed binary (e.g. `~/.local/bin/hidpify`) is stable.
    /// The generic TCC icon is the accepted trade-off until a real Developer
    /// ID signing identity is available.
    private static func resolvedBinaryPath(_ explicitPath: String? = nil) throws -> String {
        let rawPath: String
        if let explicitPath, !explicitPath.isEmpty {
            rawPath = explicitPath
        } else if let currentExecutable = CommandLine.arguments.first, !currentExecutable.isEmpty {
            rawPath = currentExecutable
        } else {
            throw HiDPIError.launchAgentError("실행 바이너리 경로를 확인할 수 없습니다")
        }
        let absolutePath: String
        if rawPath.hasPrefix("/") {
            absolutePath = rawPath
        } else {
            let cwd = FileManager.default.currentDirectoryPath
            absolutePath = (cwd as NSString).appendingPathComponent(rawPath)
        }
        // Deliberately do NOT resolve symlinks. When installed via Homebrew the
        // invoked path is the stable symlink `<prefix>/bin/hidpify`; resolving it
        // would bake in the version-specific Cellar path
        // (`.../Cellar/hidpify/X.Y.Z/bin/hidpify`), which `brew cleanup` deletes
        // on the next upgrade, breaking the daemon. Keeping the symlink path
        // makes the LaunchAgent survive upgrades.
        return absolutePath
    }

    private static func runLaunchctl(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        // launchctl print/bootout chatter must not leak into the CLI/app output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            logger.error("launchctl 실행 실패: \(error.localizedDescription, privacy: .public)")
            return -1
        }
    }
}
