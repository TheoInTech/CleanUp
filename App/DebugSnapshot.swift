#if DEBUG
import AppKit
import CleanUpCore
import SwiftUI

/// Debug builds only. Launched with `-debugSnapshotDir <dir>`, the app renders its own windows to PNGs
/// (no Screen Recording permission needed) while walking through the main window, an opened
/// category, a "?" sheet, Keep, and Settings → Always kept (then removes the kept entry again).
/// Never presses Clean up or Stop. `-debugSnapshotQuit YES` quits when done; `-debugAppearance dark`
/// renders in dark mode. Worktrees show made-up fixtures only: `WorktreesModel` neither scans nor
/// acts while `-debugSnapshotDir` is set, so the owner's real worktrees are never looked at or touched.
@MainActor
enum DebugSnapshot {
    static func runIfRequested(_ model: AppModel) {
        guard let path = UserDefaults.standard.string(forKey: "debugSnapshotDir") else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        Task { await run(model, dir: dir) }
    }

    private static func run(_ model: AppModel, dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if UserDefaults.standard.string(forKey: "debugAppearance") == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let fixture = WorktreeFixture()
        model.worktrees.debugShow(fixture.before)
        while !model.hasScanned { await pause(0.5) }
        // The first scan has no CPU deltas yet; wait for the next one.
        await pause(7)
        capture("main-window", into: dir)
        await capturePopover(model, into: dir)
        await walkWorktrees(model, fixture: fixture, into: dir)

        // Never touch an item the user already keeps (the walk removes its own Keep at the end).
        let kept = model.keepList
        let categories = model.snapshot.categories.map { c in
            CategorySummary(id: c.id, items: c.items.filter { !kept.contains($0.id) })
        }.filter { !$0.items.isEmpty }
        guard let category = categories.first(where: { $0.items.contains { $0.judgement.verdict == .idle } })
            ?? categories.first(where: { $0.id != .apps }) ?? categories.first,
            let item = category.items.first(where: { $0.judgement.verdict == .idle }) ?? category.items.first
        else {
            openSettings()
            await pause(2)
            capture("settings", into: dir)
            return finish()
        }

        // `-debugExpand apps,restart` opens those categories instead of the first idle one.
        let requested = (UserDefaults.standard.string(forKey: "debugExpand") ?? "")
            .split(separator: ",").compactMap { CategoryID(rawValue: String($0)) }
        if requested.isEmpty { model.toggleExpanded(category.id) } else { requested.forEach(model.toggleExpanded) }
        await pause(0.1)
        capture("main-expanding", into: dir)   // mid-animation: the items must stay inside their card
        await pause(1.4)
        capture("main-expanded", into: dir)

        // A made-up result (nothing is stopped) to show the outcome card in the window and the popover.
        let sample = Array(category.items.prefix(3))
        model.outcome = CleanupOutcome(items: sample, report: CleanupReport(
            stopped: sample.dropLast().map(\.id), failed: [],
            skipped: sample.count > 1 ? sample.suffix(1).map { ($0.id, "\($0.name) is in use now") } : [],
            undo: [], freedCores: 1.2
        ))
        await pause(1)
        capture("outcome-card", into: dir)
        await capturePopover(model, into: dir, name: "menubar-opened", opened: category.id)
        model.dismissOutcome()
        await pause(0.5)

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

    /// The Worktrees row opened, its result card, the "In the Trash" row with a failure line, and a kept
    /// worktree's "?" sheet, all from fixtures. Each state is captured in the window (scrolled to the
    /// row) and on its own (`worktrees-*.png`, the section alone at the window's width).
    private static func walkWorktrees(_ model: AppModel, fixture: WorktreeFixture, into dir: URL) async {
        let worktrees = model.worktrees
        model.expanded.insert(.worktrees)
        worktrees.reveal()
        await pause(1.5)
        capture("main-worktrees", into: dir)
        await captureSection(model, into: dir, name: "worktrees-open")

        worktrees.debugShow(fixture.after, outcome: fixture.outcome, lastMoved: fixture.moved)
        await pause(1)
        await captureSection(model, into: dir, name: "worktrees-outcome")

        model.expanded.remove(.worktrees)
        worktrees.debugShow(fixture.after, failure: "1 couldn't be put back · find it in the Trash")
        await pause(1)
        await captureSection(model, into: dir, name: "worktrees-trash")
        worktrees.reveal()
        await pause(1)
        capture("main-worktrees-trash", into: dir)

        model.explaining = fixture.keptItem
        await pause(10)   // the explainer gives up on the model after 8 s
        capture("worktrees-explain", into: dir)
        model.explaining = nil
        await pause(1)

        worktrees.debugShow(fixture.before)
    }

    /// The Worktrees section alone, on the window's background, at the window's content width.
    private static func captureSection(_ model: AppModel, into dir: URL, name: String) async {
        let content = WorktreesSection { _ in }
            .padding(16)
            .frame(width: 420)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(model)
        let host = NSHostingView(rootView: content)
        host.appearance = NSApp.effectiveAppearance
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: 120, y: 120))
        window.orderFront(nil)
        await pause(1.5)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
    }

    /// Hosts the popover and the menu bar label in throwaway windows (the real ones only exist while
    /// the status item is open) and writes `menubar-popover.png` and `menubar-label.png`.
    private static func capturePopover(_ model: AppModel, into dir: URL, name: String = "menubar-popover", opened: CategoryID? = nil) async {
        let host = NSHostingView(rootView: MenuBarPopover(opened: opened).environment(model))
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.backgroundColor = .clear
        window.isOpaque = false
        window.setFrameOrigin(NSPoint(x: 80, y: 80))
        window.orderFront(nil)
        await pause(2)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        window.orderOut(nil)
        guard opened == nil else { return }

        let strip = HStack(spacing: 28) {
            MenuBarLabelContent(mood: .allGood, minutes: "2h 5m")
            MenuBarLabelContent(mood: .busy, minutes: "58m")
            MenuBarLabelContent(mood: .drainingFast, minutes: "35m")
            MenuBarLabelContent(mood: .allGood, minutes: nil)
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: strip)
        renderer.scale = 4
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("menubar-label.png"))
        }
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

/// Made-up worktrees for the debug renders: safe and kept ones (uncommitted changes, in use, still
/// measuring), leftover agent folders, two in the Trash, and a cleanup that moved three and kept one.
/// The paths don't exist; nothing ever acts on them (`WorktreesModel` blocks actions while rendering).
@MainActor
private struct WorktreeFixture {
    let before: WorktreeSnapshot
    let after: WorktreeSnapshot
    let outcome: WorktreeOutcome
    /// The Trash records the fixture cleanup made.
    let moved: [UUID]
    let keptItem: Item

    init(now: Date = Date()) {
        let day: TimeInterval = 86_400
        let root = NSHomeDirectory() + "/Projects"
        func gb(_ value: Double) -> Int64 { Int64(value * 1_000_000_000) }
        func worktree(
            _ name: String, repo: String, gb bytes: Int64, agent: String?, uncommitted: Int = 0,
            merge: MergeState = .ancestor, processes: [String] = [], changed: TimeInterval? = 3 * 86_400,
            committed: TimeInterval = 6 * 86_400
        ) -> Item {
            let base = agent == "Codex" ? "\(root)/\(repo)/.codex/worktrees" : "\(root)/\(repo)-worktrees"
            let path = "\(base)/\(name)"
            let facts = WorktreeFacts(
                path: path, repo: "\(root)/\(repo)", branch: name, agent: agent, uncommitted: uncommitted,
                merge: merge, locked: false, processesInside: processes,
                lastChange: changed.map { now.addingTimeInterval(-$0) }, lastCommit: now.addingTimeInterval(-committed),
                repoExists: true)
            var detail = ["path": path, "repo": "\(root)/\(repo)", "repoName": repo, "bytes": String(bytes), "branch": name]
            if let agent { detail["agent"] = agent }
            return Item(
                id: .worktree(path: path), category: .worktrees, name: name, symbol: "arrow.triangle.branch",
                judgement: WorktreeJudge.judge(facts, now: now), cores: 0, memoryBytes: 0, processes: [],
                detail: detail)
        }

        let onboarding = worktree("feat-onboarding", repo: "atlas", gb: gb(8.4), agent: "Codex")
        let payments = worktree("payments-v2", repo: "atlas", gb: gb(6.0), agent: "Codex", uncommitted: 3)
        let login = worktree(
            "fix-login-crash", repo: "atlas", gb: gb(4.1), agent: "Claude Code", merge: .squash, committed: 2 * day)
        let dashboard = worktree("dashboard", repo: "studio", gb: gb(1.8), agent: nil, processes: ["node"])
        let refactor = worktree("refactor-api", repo: "studio", gb: gb(1.7), agent: nil, committed: 21 * day)
        let spike = worktree("spike-search", repo: "studio", gb: gb(0.4), agent: "Codex", changed: nil)
        let leftovers = Item(
            id: .worktreeLeftovers, category: .worktrees, name: "Leftover agent folders",
            symbol: "arrow.triangle.branch",
            judgement: Judgement(
                verdict: .idle, fact: "24 empty folders",
                signals: [Signal(kind: .idle, text: "Only the agent's own marker files are left")]),
            cores: 0, memoryBytes: 0, processes: [], detail: ["paths": "", "bytes": "98304"])

        func trashed(_ item: Item, daysAgo: Double) -> TrashedWorktree {
            TrashedWorktree(
                id: UUID(), path: item.detail["path"] ?? "", repo: item.detail["repo"], storedAdmin: nil,
                trashURL: NSHomeDirectory() + "/.Trash/" + item.name,
                bytes: item.detail["bytes"].flatMap { Int64($0) } ?? 0, date: now.addingTimeInterval(-daysAgo * day))
        }
        let older = [
            trashed(worktree("old-experiment", repo: "atlas", gb: gb(2.3), agent: "Codex"), daysAgo: 2),
            trashed(worktree("docs-refresh", repo: "studio", gb: gb(0.8), agent: nil), daysAgo: 1),
        ]
        let items = [onboarding, payments, login, dashboard, refactor, spike, leftovers]
        before = WorktreeSnapshot(date: now, items: items, trashed: older)

        let movedItems = [onboarding, login, leftovers]
        let fresh = movedItems.map { trashed($0, daysAgo: 0) }
        moved = fresh.map(\.id)
        let movedIDs = Set(movedItems.map(\.id))
        after = WorktreeSnapshot(date: now, items: items.filter { !movedIDs.contains($0.id) }, trashed: older + fresh)
        outcome = WorktreeOutcome(
            moved: movedItems, skipped: [(refactor, "changed 4 min ago")],
            bytes: fresh.reduce(0) { $0 + $1.bytes }, permanent: false)
        keptItem = payments
    }
}
#endif
