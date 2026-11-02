import AppKit
import CleanUpCore
import Observation
import os
import SwiftUI
import WidgetKit

/// The app's single source of truth: the latest snapshot, what is ticked, and the refresh loop.
/// Views only present it; every decision about what is idle or stoppable comes from CleanUpCore.
@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    enum Mode: Hashable {
        /// Everything idle and not kept is ticked (never apps).
        case quick
        /// Nothing ticked until the user ticks it.
        case manual
    }

    static let useAIKey = "useAppleIntelligence"
    static let visibleInterval: TimeInterval = 5
    static let backgroundInterval: TimeInterval = 60
    static let externalInterval: TimeInterval = 30

    private(set) var snapshot: Snapshot = .empty
    /// False until the first scan lands.
    private(set) var hasScanned = false
    var selection = Selection()
    var mode: Mode = .quick {
        didSet { if mode != oldValue { applyMode() } }
    }
    var expanded: Set<CategoryID> = []
    var toast: ToastState?
    /// The item whose "?" sheet is open.
    var explaining: Item?
    /// The window or popover is on screen: refresh every 5 s instead of every 60 s.
    var isVisible = false
    private(set) var isCleaning = false
    private(set) var keepList = KeepList(defaults: .standard)
    var useAI: Bool {
        didSet {
            UserDefaults.standard.set(useAI, forKey: Self.useAIKey)
            explainer = Explainer(useAI: useAI)
        }
    }

    @ObservationIgnored private let modules: [any CategoryModule]
    @ObservationIgnored private let scanner: CleanUpCore.Scanner
    @ObservationIgnored private let cleaner: Cleaner
    @ObservationIgnored private var explainer: Explainer
    @ObservationIgnored private let groupID: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastExternal: Date?
    @ObservationIgnored private var lastUndo: [UndoToken] = []
    /// Ids Quick select proposed last refresh; only newly proposed ones are ticked on the next one,
    /// so an item the user unticked stays unticked.
    @ObservationIgnored private var lastQuickProposal: Set<ItemIdentity> = []
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.cleanup.CleanUp", category: "AppModel")

    private init() {
        let modules: [any CategoryModule] = [
            SimulatorsModule(), ContainersModule(), DevServersModule(),
            AppsModule(), BrowserTabsModule(), RestartModule(),
        ]
        self.modules = modules
        scanner = CleanUpCore.Scanner(modules: modules)
        cleaner = Cleaner(modules: modules)
        let useAI = UserDefaults.standard.object(forKey: Self.useAIKey) as? Bool ?? true
        self.useAI = useAI
        explainer = Explainer(useAI: useAI)
        groupID = Bundle.main.object(forInfoDictionaryKey: "CleanUpAppGroup") as? String
    }

    // MARK: Derived

    /// What Quick select would tick right now; the widget's and the notification's idle count.
    var quickSelection: Selection { Selection.quick(snapshot, keep: keepList) }

    var freedCores: Double { selection.freedCores(in: snapshot) }

    func isTicked(_ item: Item) -> Bool { selection.ticked.contains(item.id) }

    // MARK: Refresh loop

    /// Starts the single refresh loop (idempotent): every 5 s while visible, every 60 s otherwise.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Wake every second so opening the window shortens the wait right away.
                while !Task.isCancelled, !self.isDue { try? await Task.sleep(for: .seconds(1)) }
            }
        }
    }

    private var isDue: Bool {
        guard let lastRefresh else { return true }
        let interval = isVisible ? Self.visibleInterval : Self.backgroundInterval
        return Date().timeIntervalSince(lastRefresh) >= interval
    }

    func refresh() async {
        await refresh(forceExternal: false)
    }

    /// Scans off the main actor and applies the result. Never overlaps: a caller arriving during a
    /// scan waits for it, then runs its own. External commands run at most every 30 s unless forced
    /// (after a cleanup, to see what actually stopped).
    func refresh(forceExternal: Bool) async {
        while let running = scanTask { await running.value }
        let now = Date()
        let runExternal = forceExternal || lastExternal.map { now.timeIntervalSince($0) >= Self.externalInterval } ?? true
        if runExternal { lastExternal = now }
        let scanner = self.scanner
        // Runs on the main actor only to apply the result; the scan itself runs on the Scanner actor.
        // It clears `scanTask` itself, so waiters never see a finished scan as still running.
        let task = Task { [weak self] in
            let fresh = await scanner.scan(runExternal: runExternal)
            guard let self else { return }
            self.apply(fresh)
            self.lastRefresh = Date()
            self.scanTask = nil
        }
        scanTask = task
        await task.value
    }

    private func apply(_ fresh: Snapshot) {
        let oldMood = snapshot.mood
        let oldIdle = hasScanned ? quickSelection.count : -1
        withAnimation(.smooth(duration: 0.6)) { snapshot = fresh }
        if mode == .quick {
            let proposal = Selection.quick(fresh, keep: keepList).ticked
            selection.ticked.formUnion(proposal.subtracting(lastQuickProposal))
            lastQuickProposal = proposal
        }
        selection.reconcile(with: fresh)
        hasScanned = true

        writeSnapshot(fresh)
        if fresh.mood != oldMood || quickSelection.count != oldIdle {
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func writeSnapshot(_ s: Snapshot) {
        guard let groupID, !groupID.hasPrefix(".") else { return }
        let log = self.log
        Task.detached(priority: .utility) {
            do {
                try SnapshotStore.write(s, groupID: groupID)
            } catch {
                log.error("Snapshot not shared: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Ticks

    private func applyMode() {
        switch mode {
        case .quick:
            selection = quickSelection
            lastQuickProposal = selection.ticked
        case .manual:
            selection = Selection()
        }
    }

    func toggle(_ item: Item) {
        selection.toggle(item, in: snapshot)
    }

    /// Header tick: unticks the whole category if anything in it is ticked, otherwise ticks its idle
    /// items (never apps, which are only ever ticked one by one).
    func toggleCategory(_ id: CategoryID) {
        guard let category = snapshot.categories.first(where: { $0.id == id }) else { return }
        if selection.state(of: id, in: snapshot) != .none {
            for item in category.items where isTicked(item) { selection.toggle(item, in: snapshot) }
            return
        }
        // Two passes: containers first, so their engine can be ticked after them.
        for _ in 0..<2 {
            for item in category.items where canTickAll(item) && !isTicked(item) {
                selection.toggle(item, in: snapshot)
            }
        }
    }

    /// Whether the header tick can tick anything in this category.
    func hasIdle(_ id: CategoryID) -> Bool {
        snapshot.categories.first { $0.id == id }?.items.contains(where: canTickAll) ?? false
    }

    private func canTickAll(_ item: Item) -> Bool {
        item.category != .apps && item.judgement.verdict == .idle
    }

    func toggleExpanded(_ id: CategoryID) {
        withAnimation(.snappy(duration: 0.25)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Actions

    /// Stops every ticked item, reports it in a toast, then rescans.
    func cleanUp() async {
        let items = snapshot.allItems.filter(isTicked)
        await stop(items)
    }

    /// Stops one item from its "?" sheet. `force` is "Stop anyway" on an in-use item: the engine
    /// skips its idle checks for this one item but keeps every safety guard.
    func stop(_ item: Item, force: Bool = false) async {
        let current = snapshot.item(withID: item.id) ?? item
        await stop([current], forced: force ? [current.id] : [])
    }

    private func stop(_ items: [Item], forced: Set<ItemIdentity> = []) async {
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        defer { isCleaning = false }

        let report = await cleaner.clean(items, forced: forced)
        lastUndo = report.undo
        selection.ticked.subtract(report.stopped)

        var parts: [String] = []
        if !report.stopped.isEmpty { parts.append("Stopped \(report.stopped.count)") }
        let notStopped = report.failed.count + report.skipped.count
        if notStopped > 0 { parts.append("Couldn't stop \(notStopped)") }
        show(ToastState(parts: parts, canUndo: !report.undo.isEmpty), for: .seconds(8))
        for (id, reason) in report.failed { log.info("Couldn't stop \(id.rawValue, privacy: .public): \(reason, privacy: .public)") }
        for (id, reason) in report.skipped { log.info("Skipped \(id.rawValue, privacy: .public): \(reason, privacy: .public)") }

        await refresh(forceExternal: true)
    }

    func undoLast() async {
        let tokens = lastUndo
        guard !tokens.isEmpty else { return }
        lastUndo = []
        dismissToast()
        let failed = await cleaner.undo(tokens)
        if !failed.isEmpty { show(ToastState("Couldn't undo \(failed.count)"), for: .seconds(4)) }
        await refresh(forceExternal: true)
    }

    /// Adds the item to "Always kept" (Quick select never ticks it again) and unticks it.
    func keep(_ item: Item) {
        keepList.add(item.id, name: item.name)
        if isTicked(item) { selection.toggle(item, in: snapshot) }
        lastQuickProposal.remove(item.id)
        show(ToastState("Always kept"), for: .seconds(2))
    }

    func unkeep(_ id: ItemIdentity) {
        keepList.remove(id)
    }

    func explain(_ item: Item) async -> Explanation {
        await explainer.explain(item)
    }

    /// Shows the standard macOS Restart dialog; the user still decides.
    func showRestartDialog() async {
        if await RestartModule.showRestartDialog() != nil {
            show(ToastState("Couldn't show the restart dialog"), for: .seconds(3))
        }
    }

    // MARK: Toast

    private func show(_ toast: ToastState, for duration: Duration) {
        toastDismissal?.cancel()
        withAnimation(.snappy) { self.toast = toast }
        let id = toast.id
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.dismissToast()
        }
    }

    func dismissToast() {
        toastDismissal?.cancel()
        withAnimation(.snappy) { toast = nil }
    }
}
