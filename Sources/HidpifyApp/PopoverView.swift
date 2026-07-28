import AppKit
import CoreGraphics
import HidpifyCore
import SwiftUI

/// The `MenuBarExtra` popover body. Pure frontend (DESIGN.md §8.1/§8.3): reads
/// `appState.displays`/`config`/`agentLoaded` and calls back into `AppState`
/// for every mutation — never touches `SessionController`/`VirtualDisplayFactory`.
struct PopoverView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 10) {
            header
            ForEach(appState.displays, id: \.id) { display in
                DisplayCard(display: display, appState: appState)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hidpify")
                .font(.system(size: 15, weight: .bold))
            HStack(spacing: 6) {
                Circle()
                    .fill(appState.agentLoaded ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(appState.agentLoaded ? "Daemon running" : "Daemon stopped")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                daemonControls
            }
        }
    }

    /// Direct daemon controls, distinct from the "Start at Login" toggle in the
    /// footer: these act on the daemon's current run state via `launchctl`
    /// (`AppState.startDaemon`/`stopDaemon`/`restartDaemon`) without touching
    /// whether the LaunchAgent plist is installed for future logins.
    @ViewBuilder
    private var daemonControls: some View {
        if appState.agentLoaded {
            HStack(spacing: 4) {
                Button("Restart") { appState.restartDaemon() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                Button("Stop") { appState.stopDaemon() }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        } else {
            let canStart = appState.canStartDaemon()
            Button("Start") { appState.startDaemon() }
                .controlSize(.small)
                .buttonStyle(.borderless)
                .disabled(!canStart)
                .help(
                    canStart
                        ? ""
                        : "hidpify 바이너리를 찾을 수 없습니다. 앱을 /Applications 또는 ~/Applications에 두거나 CLI를 설치하세요."
                )
        }
    }

    private var footer: some View {
        let cliPath = appState.cliBinaryPath()
        return HStack {
            Toggle(
                "Start at Login",
                isOn: Binding(
                    get: { appState.agentLoaded },
                    set: { appState.setStartAtLogin($0) }
                )
            )
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            .disabled(cliPath == nil)
            .help(cliPath == nil ? "Install the hidpify CLI first" : "")

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .controlSize(.small)
        }
    }
}

/// One physical display's card: current mode summary + HiDPI toggle, and
/// (when managed) the "looks like" resolution picker with a density-match hint.
private struct DisplayCard: View {
    let display: DisplayInfo
    @ObservedObject var appState: AppState

    private var isManaged: Bool { appState.isManaged(display) }

    private var currentTarget: TargetConfig? {
        appState.config.targets.first { $0.matcher == display.matcher }
    }

    /// Advisor candidates, plus the currently persisted looks-like size if the
    /// advisor didn't happen to include it (so the picker never shows a blank).
    private var candidates: [ResolutionCandidate] {
        let others = appState.displays.filter { $0.id != display.id }
        var result = ResolutionAdvisor.candidates(for: display, others: others)
        if let target = currentTarget,
            !result.contains(where: { $0.width == target.looksLikeWidth && $0.height == target.looksLikeHeight })
        {
            result.insert(
                ResolutionCandidate(
                    width: target.looksLikeWidth,
                    height: target.looksLikeHeight,
                    label: "\(target.looksLikeWidth) × \(target.looksLikeHeight)",
                    isDensityMatch: false
                ),
                at: 0
            )
        }
        return result
    }

    private var densityMatchCandidate: ResolutionCandidate? {
        candidates.first { $0.isDensityMatch }
    }

    private var subtitle: String {
        let hz = String(format: "%.0f", display.refreshRate)
        let status: String
        if isManaged {
            status = "HiDPI via hidpify ✓"
        } else if display.isHiDPI {
            status = "Native HiDPI ✓"
        } else {
            status = "Low resolution"
        }
        var text = "\(display.logicalWidth) × \(display.logicalHeight) @ \(hz) Hz · \(status)"
        if display.rotation != 0 {
            text += " · Portrait"
        }
        return text
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "display")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                Text(display.name)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { isManaged },
                        set: { appState.setHiDPI(display, enabled: $0) }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
            }

            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.leading, 23)

            if isManaged {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Looks like")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { tag(for: currentTarget) },
                                set: { newTag in
                                    if let candidate = candidates.first(where: { tag(for: $0) == newTag }) {
                                        appState.setLooksLike(display, width: candidate.width, height: candidate.height)
                                    }
                                }
                            )
                        ) {
                            ForEach(candidates, id: \.label) { candidate in
                                Text(candidate.label).tag(tag(for: candidate))
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                    }

                    if let densityMatchCandidate {
                        HStack(spacing: 5) {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(.blue)
                            Text(densityMatchCandidate.label)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 23)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Mode")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Picker(
                            "",
                            selection: Binding(
                                get: { appState.currentMode(display) },
                                set: { appState.setMode(display, mode: $0) }
                            )
                        ) {
                            Text("Mirror").tag(ScalingMode.mirror)
                            Text("Stream").tag(ScalingMode.stream)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .labelsHidden()
                        .fixedSize()
                    }

                    if appState.currentMode(display) == .stream {
                        HStack(alignment: .top, spacing: 5) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text("Stream is experimental. It enables Spaces swipe, but the physical display stays as a ‘phantom desktop’ (content can linger with full-screen apps). Needs Screen Recording granted to hidpify; falls back to mirroring until then. Mirror is recommended for everyday use.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
                .padding(.leading, 23)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private func tag(for candidate: ResolutionCandidate?) -> String {
        guard let candidate else { return "" }
        return "\(candidate.width)x\(candidate.height)"
    }

    private func tag(for target: TargetConfig?) -> String {
        guard let target else { return "" }
        return "\(target.looksLikeWidth)x\(target.looksLikeHeight)"
    }
}
