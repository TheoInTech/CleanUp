import AppKit
import SwiftUI

@main
struct CleanUpApp: App {
    @State private var model = AppModel.shared

    init() {
        #if DEBUG
        // Read-only worktree report: runs before the app model starts, then quits.
        if DebugWorktreeReport.requested { DebugWorktreeReport.run(); return }
        #endif
        AppModel.shared.start()
        #if DEBUG
        DebugSnapshot.runIfRequested(AppModel.shared)
        if UserDefaults.standard.bool(forKey: "debugLoginItemCycle") { AppModel.shared.debugLoginItemCycle() }
        if UserDefaults.standard.bool(forKey: "debugSimulateWarning") {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                AppModel.shared.simulateDrainWarning()
            }
        }
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
