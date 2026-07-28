import CoreGraphics
import Foundation
import HidpifyCore

// MARK: - Display table rendering (shared by `list` and `status`)

private func rotationSuffix(_ info: DisplayInfo) -> String {
    info.rotation != 0 ? " rot=\(Int(info.rotation))°" : ""
}

private func virtualSuffix(_ info: DisplayInfo) -> String {
    info.isOurVirtual ? " [virtual]" : ""
}

private func mirrorSuffix(_ info: DisplayInfo) -> String {
    info.mirrorsDisplayID != 0 ? " → \(info.mirrorsDisplayID)" : ""
}

/// Parses a `--mode` CLI argument into a `ScalingMode`, case-insensitively.
private func parseScalingMode(_ text: String) throws -> ScalingMode {
    guard let mode = ScalingMode(rawValue: text.lowercased()) else {
        throw HiDPIError.configError("--mode 값이 올바르지 않습니다 (mirror 또는 stream): \(text)")
    }
    return mode
}

private func printDisplayTable(_ displays: [DisplayInfo]) {
    if displays.isEmpty {
        print("연결된 디스플레이가 없습니다.")
        return
    }
    for info in displays {
        let hidpiMark = info.isHiDPI ? "✓" : "✗"
        let hzText = info.refreshRate > 0 ? String(format: "%.0f", info.refreshRate) : "?"
        var line = "[\(info.id)] \(info.name) — \(info.logicalWidth)x\(info.logicalHeight)@\(hzText)Hz"
        line += " (픽셀 \(info.pixelWidth)x\(info.pixelHeight))"
        line += " HiDPI:\(hidpiMark)"
        line += rotationSuffix(info)
        line += virtualSuffix(info)
        line += mirrorSuffix(info)
        print(line)
    }
}

// MARK: - Target resolution shared by `enable`/`disable`

/// Resolves a `--display` argument (numeric id or case-insensitive name substring)
/// against the currently online, non-virtual displays.
private func resolveDisplay(_ token: String?) -> DisplayInfo? {
    let candidates = DisplayEnumerator.onlineDisplays().filter { !$0.isOurVirtual }
    guard let token else {
        return DisplayEnumerator.defaultTarget()
    }
    if let numericID = UInt32(token) {
        return candidates.first { $0.id == numericID }
    }
    let needle = token.lowercased()
    return candidates.first { $0.name.lowercased().contains(needle) }
}

/// Parses a "WxH" string (e.g. "900x1440") into (width, height).
private func parseLooksLike(_ text: String) throws -> (width: Int, height: Int) {
    let parts = text.lowercased().split(separator: "x")
    guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
        throw HiDPIError.configError("--looks-like 형식이 올바르지 않습니다 (예: 900x1440): \(text)")
    }
    return (width, height)
}

// MARK: - Minimal self-contained argument parser
//
// No external argument-parsing dependency. Supports `--key value` options and
// bare `--flag` boolean flags. The first CLI argument is always the subcommand.

/// Errors produced by the CLI-level argument parser itself (as opposed to
/// `HiDPIError`, which covers domain/runtime failures).
private enum CLIError: Error, CustomStringConvertible {
    case unknownSubcommand(String)
    case unknownOption(String)
    case missingValue(String)
    case invalidValue(option: String, value: String)

    var description: String {
        switch self {
        case .unknownSubcommand(let name):
            return "알 수 없는 명령어입니다: \(name)\n'hidpify --help'로 사용법을 확인하세요."
        case .unknownOption(let name):
            return "알 수 없는 옵션입니다: \(name)\n'hidpify <subcommand> --help'로 사용법을 확인하세요."
        case .missingValue(let name):
            return "옵션에 값이 필요합니다: \(name)"
        case .invalidValue(let option, let value):
            return "옵션 값이 올바르지 않습니다: \(option) \(value)"
        }
    }
}

/// Result of parsing a subcommand's `--key value` / `--flag` arguments.
private struct ParsedOptions {
    var values: [String: String] = [:]
    var flags: Set<String> = []
}

/// Parses `args` (already stripped of the subcommand token) against the given
/// sets of recognized option keys and flag keys. Every token must start with
/// `--`; unknown tokens, or options missing their value, throw `CLIError`.
private func parseOptions(_ args: [String], options: Set<String>, flags: Set<String>) throws -> ParsedOptions {
    var result = ParsedOptions()
    var index = 0
    while index < args.count {
        let token = args[index]
        guard token.hasPrefix("--") else {
            throw CLIError.unknownOption(token)
        }
        let key = String(token.dropFirst(2))
        if flags.contains(key) {
            result.flags.insert(key)
            index += 1
        } else if options.contains(key) {
            let valueIndex = index + 1
            guard valueIndex < args.count else {
                throw CLIError.missingValue(token)
            }
            result.values[key] = args[valueIndex]
            index += 2
        } else {
            throw CLIError.unknownOption(token)
        }
    }
    return result
}

private func hasHelpFlag(_ args: [String]) -> Bool {
    args.contains("--help") || args.contains("-h")
}

// MARK: - Usage / help text

private func printTopLevelUsage() {
    print(
        """
        사용법: hidpify <subcommand> [options]

        macOS 외장 모니터 HiDPI 강제 적용 도구

        명령어:
          list             연결된 디스플레이 목록을 표로 출력합니다.
          enable           지정한(또는 자동 선택된) 디스플레이에 HiDPI를 적용합니다.
          disable          적용된 HiDPI 설정을 해제합니다.
          status           설정 파일, LaunchAgent 상태, 디스플레이 목록을 출력합니다.
          daemon           상주 데몬으로 실행합니다 (보통 LaunchAgent가 실행).
          install-agent    LaunchAgent를 설치하여 로그인 시 데몬이 자동 실행되게 합니다.
          uninstall-agent  LaunchAgent를 제거합니다.

        각 명령어의 옵션은 'hidpify <subcommand> --help'로 확인하세요.
        """
    )
}

private func printListUsage() {
    print(
        """
        사용법: hidpify list

        연결된 디스플레이 목록을 표로 출력합니다.
        """
    )
}

private func printEnableUsage() {
    print(
        """
        사용법: hidpify enable [options]

        지정한(또는 자동 선택된) 디스플레이에 HiDPI를 적용합니다.

        옵션:
          --display <값>       대상 디스플레이 (이름 부분일치 또는 숫자 id). 미지정 시 자동 선택
          --looks-like <WxH>   논리 해상도 WxH (예: 900x1440). 미지정 시 현재 해상도 사용
          --hz <값>            주사율. 미지정 시 현재 주사율 사용 (0이면 60)
          --mode <값>          스케일링 모드: mirror(기본, 권장) 또는 stream(실험적 — Spaces 스와이프용)
          --foreground         데몬에 위임하지 않고 현재 프로세스를 포그라운드로 유지합니다
        """
    )
}

private func printDisableUsage() {
    print(
        """
        사용법: hidpify disable [options]

        적용된 HiDPI 설정을 해제합니다.

        옵션:
          --display <값>  대상 디스플레이 (이름 부분일치). 미지정 시 설정에 타겟이 1개면 그것을 사용
        """
    )
}

private func printStatusUsage() {
    print(
        """
        사용법: hidpify status

        설정 파일, LaunchAgent 상태, 디스플레이 목록을 출력합니다.
        """
    )
}

private func printDaemonUsage() {
    print(
        """
        사용법: hidpify daemon

        상주 데몬으로 실행합니다 (보통 LaunchAgent가 실행).
        """
    )
}

private func printInstallAgentUsage() {
    print(
        """
        사용법: hidpify install-agent

        LaunchAgent를 설치하여 로그인 시 데몬이 자동 실행되게 합니다.
        """
    )
}

private func printUninstallAgentUsage() {
    print(
        """
        사용법: hidpify uninstall-agent

        LaunchAgent를 제거합니다.
        """
    )
}

// MARK: - Subcommand implementations

private func runList(_ args: [String]) throws {
    if hasHelpFlag(args) {
        printListUsage()
        Foundation.exit(0)
    }
    _ = try parseOptions(args, options: [], flags: [])

    printDisplayTable(DisplayEnumerator.onlineDisplays())
}

private func runEnable(_ args: [String]) throws {
    if hasHelpFlag(args) {
        printEnableUsage()
        Foundation.exit(0)
    }
    let parsed = try parseOptions(
        args,
        options: ["display", "looks-like", "hz", "mode"],
        flags: ["foreground"]
    )

    let display = parsed.values["display"]
    let looksLike = parsed.values["looks-like"]

    let hz: Double?
    if let hzText = parsed.values["hz"] {
        guard let value = Double(hzText) else {
            throw CLIError.invalidValue(option: "--hz", value: hzText)
        }
        hz = value
    } else {
        hz = nil
    }

    let mode = parsed.values["mode"] ?? "mirror"
    let foreground = parsed.flags.contains("foreground")

    let scalingMode = try parseScalingMode(mode)

    guard let target = resolveDisplay(display) else {
        throw HiDPIError.displayNotFound(display ?? "(자동 선택 대상 없음 — 이미 모두 HiDPI일 수 있습니다)")
    }

    let looksLikeSize: (width: Int, height: Int)
    if let looksLike {
        looksLikeSize = try parseLooksLike(looksLike)
    } else {
        if target.isHiDPI {
            print("'\(target.name)'은 이미 HiDPI로 동작 중입니다. 추가 조치가 필요 없습니다.")
            return
        }
        looksLikeSize = (target.logicalWidth, target.logicalHeight)
    }

    let refreshRate = hz ?? (target.refreshRate > 0 ? target.refreshRate : 60)

    if scalingMode == .stream {
        print(
            "⚠️  스트리밍은 실험(experimental) 모드입니다. Spaces 스와이프가 되는 대신 물리 디스플레이가 "
                + "배치에 '유령 데스크탑'으로 남아, 전체화면 앱(예: 원격 데스크탑) 사용 시 내용이 남거나 "
                + "미션 컨트롤/스크린샷에 보일 수 있습니다. 안정적인 일상 사용은 기본값인 미러링(--mode mirror)을 권장합니다."
        )
        if !StreamController.hasScreenCapturePermission() {
            StreamController.requestScreenCapturePermission()
            print(
                "화면 기록 권한이 필요합니다. 시스템 설정 > 개인정보 보호 및 보안 > 화면 기록에서 hidpify를 허용한 뒤 다시 실행하세요. "
                    + "권한 없이 적용되면 데몬이 미러링으로 폴백합니다."
            )
        }
    }

    var config = ConfigStore.load()
    let virtualSerialNum =
        config.targets.first { $0.matcher == target.matcher }?.virtualSerialNum
        ?? UInt32.random(in: 1...UInt32.max)

    let newTarget = TargetConfig(
        matcher: target.matcher,
        displayName: target.name,
        looksLikeWidth: looksLikeSize.width,
        looksLikeHeight: looksLikeSize.height,
        refreshRate: refreshRate,
        virtualSerialNum: virtualSerialNum,
        mode: scalingMode
    )
    try ConfigStore.addOrUpdate(target: newTarget)
    config = ConfigStore.load()

    if LaunchAgentInstaller.isLoaded() && !foreground {
        if LaunchAgentInstaller.kickstart() {
            print("'\(target.name)': \(looksLikeSize.width)x\(looksLikeSize.height) HiDPI 설정을 저장하고 데몬 재시작으로 적용했습니다.")
        } else {
            print("데몬 재시작 요청을 보냈지만 실패했을 수 있습니다. `hidpify status`로 확인하세요.")
        }
        return
    }

    print("포그라운드 모드로 적용합니다. 영구 적용은 `hidpify install-agent`. Ctrl-C로 종료(원복됨).")
    DaemonRunner().run()
}

private func runDisable(_ args: [String]) throws {
    if hasHelpFlag(args) {
        printDisableUsage()
        Foundation.exit(0)
    }
    let parsed = try parseOptions(args, options: ["display"], flags: [])
    let display = parsed.values["display"]

    let config = ConfigStore.load()
    guard !config.targets.isEmpty else {
        print("저장된 HiDPI 타겟이 없습니다.")
        return
    }

    let matcher: DisplayMatcher
    if let display {
        let needle = display.lowercased()
        if let byName = config.targets.first(where: { $0.displayName.lowercased().contains(needle) }) {
            matcher = byName.matcher
        } else if let online = DisplayEnumerator.onlineDisplays().first(where: {
            !$0.isOurVirtual && $0.name.lowercased().contains(needle)
        }),
            let byOnline = config.targets.first(where: { $0.matcher == online.matcher })
        {
            matcher = byOnline.matcher
        } else {
            throw HiDPIError.displayNotFound(display)
        }
    } else {
        guard config.targets.count == 1 else {
            throw HiDPIError.configError("설정에 타겟이 여러 개입니다. --display로 지정하세요.")
        }
        matcher = config.targets[0].matcher
    }

    let name = config.targets.first { $0.matcher == matcher }?.displayName ?? "대상"
    try ConfigStore.remove(matcher: matcher)

    if LaunchAgentInstaller.isLoaded() {
        LaunchAgentInstaller.kickstart()
        print("'\(name)'의 HiDPI 설정을 제거하고 데몬 재시작으로 원복을 적용했습니다.")
    } else {
        print("'\(name)'의 HiDPI 설정을 제거했습니다. 데몬이 실행 중이지 않으면 `hidpify daemon`이나 재시작 시 원복됩니다.")
    }
}

private func runStatus(_ args: [String]) throws {
    if hasHelpFlag(args) {
        printStatusUsage()
        Foundation.exit(0)
    }
    _ = try parseOptions(args, options: [], flags: [])

    let config = ConfigStore.load()
    print("설정 파일: \(ConfigStore.configURL.path)")
    if config.targets.isEmpty {
        print("저장된 타겟 없음")
    } else {
        print("타겟 \(config.targets.count)개:")
        for target in config.targets {
            let hzText = String(format: "%.0f", target.refreshRate)
            print(
                "  - \(target.displayName): \(target.looksLikeWidth)x\(target.looksLikeHeight) @\(hzText)Hz [\(target.mode.rawValue)]"
            )
        }
    }
    print("LaunchAgent 로드됨: \(LaunchAgentInstaller.isLoaded() ? "예" : "아니오")")
    print("")
    print("현재 디스플레이:")
    printDisplayTable(DisplayEnumerator.onlineDisplays())
}

private func runDaemon(_ args: [String]) throws {
    if hasHelpFlag(args) {
        printDaemonUsage()
        Foundation.exit(0)
    }
    _ = try parseOptions(args, options: [], flags: [])

    DaemonRunner().run()
}

private func runInstallAgent(_ args: [String]) throws {
    if hasHelpFlag(args) {
        printInstallAgentUsage()
        Foundation.exit(0)
    }
    _ = try parseOptions(args, options: [], flags: [])

    try LaunchAgentInstaller.install()
    print("LaunchAgent를 설치했습니다 (\(LaunchAgentInstaller.label)).")

    let executablePath = CommandLine.arguments.first ?? ""
    if executablePath.contains("/.build/") {
        print("경고: 현재 실행 파일이 .build 아래에 있습니다. plist에는 이 절대경로가 그대로 기록되므로, ")
        print("     빌드 디렉터리를 정리하면 데몬이 깨집니다. 릴리스 바이너리를 /usr/local/bin 등 고정 경로에 ")
        print("     복사한 뒤 그 경로로 `hidpify install-agent`를 다시 실행하는 것을 권장합니다.")
    }
}

private func runUninstallAgent(_ args: [String]) throws {
    if hasHelpFlag(args) {
        printUninstallAgentUsage()
        Foundation.exit(0)
    }
    _ = try parseOptions(args, options: [], flags: [])

    try LaunchAgentInstaller.uninstall()
    print("LaunchAgent를 제거했습니다 (\(LaunchAgentInstaller.label)).")
}

// MARK: - Entry point
// This file is named `main.swift`, so top-level code runs directly (no @main).

let allArguments = Array(CommandLine.arguments.dropFirst())

guard let subcommand = allArguments.first else {
    printTopLevelUsage()
    Foundation.exit(0)
}

if subcommand == "--help" || subcommand == "-h" {
    printTopLevelUsage()
    Foundation.exit(0)
}

let subcommandArguments = Array(allArguments.dropFirst())

do {
    switch subcommand {
    case "list":
        try runList(subcommandArguments)
    case "enable":
        try runEnable(subcommandArguments)
    case "disable":
        try runDisable(subcommandArguments)
    case "status":
        try runStatus(subcommandArguments)
    case "daemon":
        try runDaemon(subcommandArguments)
    case "install-agent":
        try runInstallAgent(subcommandArguments)
    case "uninstall-agent":
        try runUninstallAgent(subcommandArguments)
    default:
        throw CLIError.unknownSubcommand(subcommand)
    }
} catch let error as HiDPIError {
    print(error.description)
    Foundation.exit(1)
} catch let error as CLIError {
    print(error.description)
    Foundation.exit(1)
} catch {
    print("오류: \(error)")
    Foundation.exit(1)
}
