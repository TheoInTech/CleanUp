#if DEBUG
import AppKit
import CleanUpCore

/// Debug builds only. Launched with `-debugSnapshotDir <dir>`, the app renders its own windows to PNGs
/// (no Screen Recording permission needed) while walking through the main window, an opened
/// category, a "?" sheet, Keep, and Settings → Always kept (then removes the kept entry again).
/// Never presses Clean up or Stop. `-debugSnapshotQuit YES` quits when done.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ model: AppModel) {
        guard let path = UserDefaults.standard.string(forKey: "debugSnapshotDir") else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        Task { await run(model, dir: dir) }
    }

    private static func run(_ model: AppModel, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        while !model.hasScanned { await pause(0.5) }
        // The first scan has no CPU deltas yet; wait for the next one.
        await pause(7)
        capture("main-window", into: dir)

        let categories = model.snapshot.categories
        guard let category = categories.first(where: { $0.items.contains { $0.judgement.verdict == .idle } })
            ?? categories.first(where: { $0.id != .apps }) ?? categories.first,
            let item = category.items.first(where: { $0.judgement.verdict == .idle }) ?? category.items.first
        else { return finish() }

        // `-debugExpand apps,restart` opens those categories instead of the first idle one.
        let requested = (UserDefaults.standard.string(forKey: "debugExpand") ?? "")
            .split(separator: ",").compactMap { CategoryID(rawValue: String($0)) }
        if requested.isEmpty { model.toggleExpanded(category.id) } else { requested.forEach(model.toggleExpanded) }
        await pause(1.5)
        capture("main-expanded", into: dir)

        model.explaining = item
        await pause(10)   // the explainer gives up on the model after 8 s
        capture("explain-sheet", into: dir)

        model.keep(item)
        model.explaining = nil
        await pause(1)
        capture("kept-toast", into: dir)

        openSettings()
        await pause(2)
        capture("settings-kept", into: dir)

        model.unkeep(item.id)
        await pause(1)
        capture("settings-removed", into: dir)
        finish()
    }

    private static func finish() {
        if UserDefaults.standard.bool(forKey: "debugSnapshotQuit") { NSApp.terminate(nil) }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// The app menu's "Settings…" item (⌘,).
    private static func openSettings() {
        guard let menu = NSApp.mainMenu?.items.first?.submenu,
              let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { return }
        menu.performActionForItem(at: index)
    }

    /// One PNG per visible window, e.g. `main-window-CleanUp.png`.
    private static func capture(_ name: String, into dir: URL) {
        for window in NSApp.windows where window.isVisible && window.frame.width > 120 {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            let label = window.title.isEmpty ? "\(window.windowNumber)" : window.title.replacingOccurrences(of: " ", with: "-")
            let url = dir.appendingPathComponent("\(name)-\(label).png")
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }
}
#endif
