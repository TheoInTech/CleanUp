import AppKit
import SwiftUI

@main
struct CleanUpApp: App {
    @State private var model = AppModel.shared

    init() {
        AppModel.shared.start()
        #if DEBUG
        DebugSnapshot.runIfRequested(AppModel.shared)
        #endif
    }

    var body: some Scene {
        MenuBarExtra("CleanUp", systemImage: "sparkles") {
            // Placeholder until the menu bar popover lands.
            OpenMainWindowButton()
        }

        Window("CleanUp", id: "main") {
            MainView()
                .environment(model)
                .containerBackground(.thinMaterial, for: .window)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 760)
        .defaultLaunchBehavior(Self.launchBehavior)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    /// Debug builds open the window at launch so it can be checked without the menu bar.
    private static var launchBehavior: SceneLaunchBehavior {
        #if DEBUG
        .presented
        #else
        .suppressed
        #endif
    }
}

private struct OpenMainWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open CleanUp") {
            NSApp.activate()
            openWindow(id: "main")
        }
        Divider()
        Button("Quit CleanUp") { NSApp.terminate(nil) }
    }
}
