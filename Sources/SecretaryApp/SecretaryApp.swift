import AppKit
import SecretaryCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let app = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only, no Dock icon (LSUIElement is also set in the bundle).
        NSApp.setActivationPolicy(.accessory)
        app.start()
    }
}

@main
struct SecretaryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(delegate.app)
        } label: {
            Image(systemName: delegate.app.assistant.isRecording ? "waveform.circle.fill" : "alarm")
        }
        .menuBarExtraStyle(.window)

        Window("AI Secretary", id: AssistantView.windowID) {
            AssistantView()
                .environment(delegate.app)
        }
        .defaultSize(width: 840, height: 660)
        .defaultPosition(.topTrailing)

        Settings {
            SettingsView()
                .environment(delegate.app)
        }
    }
}
