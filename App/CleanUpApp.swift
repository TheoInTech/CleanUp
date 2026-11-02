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
        MenuBarExtra {
            MenuBarPopover()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

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

    /// Menu bar only. The debug snapshot renderer needs the window up front, so it asks for it.
    private static var launchBehavior: SceneLaunchBehavior {
        #if DEBUG
        UserDefaults.standard.string(forKey: "debugSnapshotDir") != nil ? .presented : .suppressed
        #else
        .suppressed
        #endif
    }
}
