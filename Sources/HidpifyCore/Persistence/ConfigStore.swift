import Foundation
import os

/// Reads/writes the persisted app configuration at `~/.config/hidpify/config.json`.
public enum ConfigStore {
    private static let logger = Logger(subsystem: "dev.irae.hidpify", category: "configstore")

    public static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/hidpify/config.json")
    }

    /// Loads the config. Returns an empty `AppConfig` when the file is missing or corrupt
    /// (corruption is logged as a warning; a missing file is normal on first run).
    public static func load() -> AppConfig {
        let url = configURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return AppConfig()
        }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AppConfig.self, from: data)
        } catch {
            logger.warning("설정 파일이 손상되어 빈 설정으로 대체합니다: \(error.localizedDescription, privacy: .public)")
            return AppConfig()
        }
    }

    /// Writes the config as pretty-printed JSON, creating the parent directory if needed.
    public static func save(_ config: AppConfig) throws {
        let url = configURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: url, options: .atomic)
        } catch {
            throw HiDPIError.configError("설정 파일 저장 실패: \(error.localizedDescription)")
        }
    }

    /// Replaces the target matching `target.matcher` if one exists, otherwise appends it.
    public static func addOrUpdate(target: TargetConfig) throws {
        var config = load()
        if let index = config.targets.firstIndex(where: { $0.matcher == target.matcher }) {
            config.targets[index] = target
        } else {
            config.targets.append(target)
        }
        try save(config)
    }

    /// Removes any target matching `matcher`, if present.
    public static func remove(matcher: DisplayMatcher) throws {
        var config = load()
        config.targets.removeAll { $0.matcher == matcher }
        try save(config)
    }
}
