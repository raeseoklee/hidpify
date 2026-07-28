import AppKit
import SwiftUI

// Note: this file is intentionally not named `main.swift` — that filename
// disables top-level-code entry points, which conflicts with `@main`.
@main
struct HidpifyApp: App {
    @StateObject private var appState = AppState()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("hidpify", systemImage: "display") {
            PopoverView(appState: appState)
        }
        .menuBarExtraStyle(.window)
    }
}
