import AppKit
import CleanUpCore
import Darwin
import notify
import Observation
import os
import SwiftUI
import UserNotifications
import WidgetKit

/// The app's single source of truth: the latest snapshot, what is ticked, and the refresh loop.
/// Views only present it; every decision about what is idle or stoppable comes from CleanUpCore.
@Observable @MainActor
final class AppModel {
    static let shared = AppModel()

    /// Quick select | Choose myself.
    typealias Mode = TickController.Mode

    static let useAIKey = "useAppleIntelligence"
    static let lastWarningKey = "drainMonitor.lastWarning"
    static let visibleInterval: TimeInterval = 5
    static let backgroundInterval: TimeInterval = 60
    static let externalInterval: TimeInterval = 30

    private(set) var snapshot: Snapshot = .empty
    /// False until the first scan lands.
    private(set) var hasScanned = false
    /// What is ticked and how (Quick select | Choose myself); the rules live in CleanUpCore.
    private(set) var ticks = TickController()
    var selection: Selection { ticks.selection }
    var mode: Mode {
        get { ticks.mode }
        set { ticks.setMode(newValue, in: snapshot, keep: keepList) }
    }
    var expanded: Set<CategoryID> = []
    var toast: ToastState?
    /// The item whose "?" sheet is open.
    var explaining: Item?
    /// The main window is on screen.
    var windowVisible = false
    /// The menu bar popover is on screen.
    var popoverVisible = false
    /// Either surface is on screen: refresh every 5 s instead of every 60 s. Tracked per surface so
    /// closing one never slows the refresh while the other is still open.
    var isVisible: Bool { windowVisible || popoverVisible }
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
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.cleanup.CleanUp", category: "AppModel")
    @ObservationIgnored private var drainMonitor: DrainMonitor
    @ObservationIgnored private let notificationDelegate = NotificationDelegate()
    @ObservationIgnored private var signalToken: Int32 = NOTIFY_TOKEN_INVALID
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    /// Opens the main window; set by the menu bar label, the one view that always exists.
    @ObservationIgnored var openMainWindow: (() -> Void)?

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
        drainMonitor = DrainMonitor(
            lastWarning: (UserDefaults.standard.object(forKey: Self.lastWarningKey) as? Double).map(Date.init(timeIntervalSince1970:))
        )
    }

    // MARK: Derived

    /// What Quick select would tick right now; the widget's and the notification's idle count.
    var quickSelection: Selection { TickController.cleanIdleSelection(snapshot, keep: keepList) }

    var freedCores: Double { selection.freedCores(in: snapshot) }

    func isTicked(_ item: Item) -> Bool { selection.ticked.contains(item.id) }

    // MARK: Refresh loop

    /// Starts the single refresh loop (idempotent): every 5 s while visible, every 60 s otherwise.
    func start() {
        guard loop == nil else { return }
        startIntegrations()
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
        ticks.apply(fresh, keep: keepList)
        hasScanned = true

        let quick = quickSelection
        let widgetChanged = fresh.mood != oldMood || quick.count != oldIdle
        warnIfDrainingFast(fresh)
        // The widget can't read the Always-kept list, so it gets the idle count from here.
        writeSnapshot(
            fresh.withQuickSummary(idleCount: quick.count, freedCores: quick.freedCores(in: fresh)),
            reloadWidgets: widgetChanged
        )
    }

    /// Shares the snapshot with the widget; when `reloadWidgets`, asks WidgetKit to redraw only after
    /// the file is written, so the widget never reads the previous snapshot.
    private func writeSnapshot(_ s: Snapshot, reloadWidgets: Bool) {
        guard let groupID, !groupID.hasPrefix(".") else { return }
        let log = self.log
        Task.detached(priority: .utility) {
            do {
                try SnapshotStore.write(s, groupID: groupID)
                if reloadWidgets { WidgetCenter.shared.reloadAllTimelines() }
            } catch {
                log.error("Snapshot not shared: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Ticks

    func toggle(_ item: Item) {
        ticks.toggle(item, in: snapshot)
    }

    /// Header tick: unticks the whole category if anything in it is ticked, otherwise ticks its idle
    /// items that aren't Always kept (never apps, which are only ever ticked one by one).
    func toggleCategory(_ id: CategoryID) {
        ticks.toggleCategory(id, in: snapshot, keep: keepList)
    }

    /// Whether the header tick can tick anything in this category.
    func hasIdle(_ id: CategoryID) -> Bool {
        TickController.hasIdle(id, in: snapshot, keep: keepList)
    }

    func toggleExpanded(_ id: CategoryID) {
        withAnimation(.snappy(duration: 0.25)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    // MARK: Actions

    /// Stops every ticked item, reports it in a toast, then rescans. Pass a selection to clean exactly
    /// that instead of what is ticked (the notification and the widget never touch the user's ticks).
    @discardableResult
    func cleanUp(_ selection: Selection? = nil) async -> CleanupReport? {
        let chosen = selection ?? self.selection
        let items = snapshot.allItems.filter { chosen.ticked.contains($0.id) }
        return await stop(items)
    }

    /// Stops one item from its "?" sheet. `force` is "Stop anyway" on an in-use item: the engine
    /// skips its idle checks for this one item but keeps every safety guard.
    func stop(_ item: Item, force: Bool = false) async {
        let current = snapshot.item(withID: item.id) ?? item
        await stop([current], forced: force ? [current.id] : [])
    }

    @discardableResult
    private func stop(_ items: [Item], forced: Set<ItemIdentity> = []) async -> CleanupReport? {
        guard !items.isEmpty, !isCleaning else { return nil }
        isCleaning = true
        defer { isCleaning = false }

        let report = await clean(items, forced: forced)
        lastUndo = report.undo
        ticks.stopped(report.stopped)

        let parts = Self.summary(of: report)
        show(ToastState(parts: parts, canUndo: !report.undo.isEmpty), for: .seconds(8))
        for (id, reason) in report.failed { log.info("Couldn't stop \(id.rawValue, privacy: .public): \(reason, privacy: .public)") }
        for (id, reason) in report.skipped { log.info("Skipped \(id.rawValue, privacy: .public): \(reason, privacy: .public)") }

        await refresh(forceExternal: true)
        return report
    }

    /// The Cleaner, except in a debug build launched with `-dryRunCleanup`, which only logs what it
    /// would have stopped (so testing the notification and the widget never stops real work).
    private func clean(_ items: [Item], forced: Set<ItemIdentity>) async -> CleanupReport {
        #if DEBUG
        if Self.isDryRun {
            for item in items { log.notice("DRY RUN would stop \(item.id.rawValue, privacy: .public)") }
            return CleanupReport(
                stopped: items.map(\.id), failed: [], skipped: [], undo: [], freedCores: items.reduce(0) { $0 + $1.cores }
            )
        }
        #endif
        return await cleaner.clean(items, forced: forced)
    }

    /// "Stopped 3", "Couldn't stop 1": the toast's segments and the follow-up notification's text.
    private static func summary(of report: CleanupReport) -> [String] {
        var parts: [String] = []
        if !report.stopped.isEmpty { parts.append("Stopped \(report.stopped.count)") }
        #if DEBUG
        if isDryRun { parts.append("dry run") }
        #endif
        let notStopped = report.failed.count + report.skipped.count
        if notStopped > 0 { parts.append("Couldn't stop \(notStopped)") }
        return parts
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
        ticks.kept(item, in: snapshot)
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

    // MARK: Warning, widget trigger, activation

    #if DEBUG
    static var isDryRun: Bool { UserDefaults.standard.bool(forKey: "dryRunCleanup") }
    #endif

    /// Hooks the app to the outside world once: notification buttons, the widget's signal, the
    /// activation log, and the first-launch setup (notification permission, open at login).
    private func startIntegrations() {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { await Notifications.requestAuthorization() }
        LoginItem.setUpOnFirstLaunch()

        // The widget's "Clean up" button posts this; it does exactly what the notification button does.
        signalToken = CleanupSignal.observe {
            Task { @MainActor in await AppModel.shared.cleanIdle() }
        }
        if signalToken == NOTIFY_TOKEN_INVALID { log.error("Couldn't listen for the widget's clean signal") }

        // Apps are judged idle by when they were last in front, so stamp on both edges: activation
        // (now in front) and deactivation (just left the front).
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let bundleID = app?.bundleIdentifier else { return }
                let stamp = Date()
                Task { await ActivationLog.shared.record(bundleID: bundleID, at: stamp) }
            })
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            Task { await ActivationLog.shared.record(bundleID: front, at: Date()) }
        }
    }

    /// Asks the monitor after every scan; it decides on mood, idle share and the 30-minute quiet period.
    private func warnIfDrainingFast(_ fresh: Snapshot) {
        let selection = Selection.quick(fresh, keep: keepList)
        let share = DrainWarning.idleShare(of: selection, in: fresh)
        guard drainMonitor.shouldWarn(snapshot: fresh, idleShare: share, now: Date()) else { return }
        if let last = drainMonitor.lastWarning {
            UserDefaults.standard.set(last.timeIntervalSince1970, forKey: Self.lastWarningKey)
        }
        guard let warning = DrainWarning.make(snapshot: fresh, selection: selection) else { return }
        post(warning)
    }

    private func post(_ warning: DrainWarning) {
        Task {
            await Notifications.postDrainWarning(
                minutesLeft: warning.minutesLeft, idleSummary: warning.summary, idleCount: warning.idleCount
            )
        }
    }

    /// "Clean up N idle" from the notification or the widget. Looks again first and decides from the
    /// fresh scan, never from the numbers in the notification, which may be minutes old. Quick select
    /// only: never forced, never apps, and the user's own ticks stay as they were.
    func cleanIdle() async {
        guard !isCleaning else { return }
        await refresh(forceExternal: true)
        let quick = TickController.cleanIdleSelection(snapshot, keep: keepList)
        guard quick.count > 0 else {
            show(ToastState("Nothing idle"), for: .seconds(4))
            if !isVisible { await Notifications.postResult("Nothing idle to stop") }
            return
        }
        guard let report = await cleanUp(quick) else { return }
        // With no window or popover open the toast is invisible, so say it in a quiet notification.
        if !isVisible { await Notifications.postResult(Self.summary(of: report).joined(separator: " · ")) }
    }

    func showMainWindow() {
        NSApp.activate()
        openMainWindow?()
    }

    #if DEBUG
    /// "Simulate drain warning": runs the real warning path on a `.drainingFast` copy of the current
    /// snapshot (a demo set of idle items when nothing is idle right now), with a fresh monitor so the
    /// 30-minute quiet period and the stored time are left alone.
    func simulateDrainWarning() {
        var fake = Snapshot.demo(categories: snapshot.categories)
        let real = Selection.quick(fake, keep: keepList)
        if DrainWarning.idleShare(of: real, in: fake) < DrainMonitor.minimumIdleShare {
            fake = Snapshot.demo(categories: Self.demoCategories)
        }
        let selection = Selection.quick(fake, keep: keepList)
        var monitor = DrainMonitor()
        let share = DrainWarning.idleShare(of: selection, in: fake)
        guard monitor.shouldWarn(snapshot: fake, idleShare: share, now: Date()),
              let warning = DrainWarning.make(snapshot: fake, selection: selection) else {
            log.error("Simulated warning not shown (idle share \(share))")
            return
        }
        post(warning)
    }

    private static var demoCategories: [CategorySummary] {
        func item(_ id: ItemIdentity, _ category: CategoryID, _ name: String, cores: Double) -> Item {
            Item(id: id, category: category, name: name, symbol: "questionmark",
                 judgement: Judgement(verdict: .idle, fact: "idle", signals: []),
                 cores: cores, memoryBytes: 0, processes: [], detail: [:])
        }
        return [
            CategorySummary(id: .simulators, items: (1...4).map {
                item(.simulator(udid: "demo-\($0)"), .simulators, "Demo simulator \($0)", cores: 1)
            }),
            CategorySummary(id: .containers, items: (1...6).map {
                item(.container(name: "demo-\($0)"), .containers, "demo-\($0)", cores: 0.2)
            }),
        ]
    }

    /// Register, read back, unregister: proves the real login item code works without leaving the
    /// debug build in the user's login items. Launch with `-debugLoginItemCycle YES`.
    func debugLoginItemCycle() {
        func report(_ step: String) { log.notice("LOGIN ITEM \(step, privacy: .public): status \(String(describing: LoginItem.status), privacy: .public)") }
        report("before")
        do { try LoginItem.set(true) } catch { log.notice("LOGIN ITEM register threw: \(String(describing: error), privacy: .public)") }
        report("after register")
        do { try LoginItem.set(false) } catch { log.notice("LOGIN ITEM unregister threw: \(String(describing: error), privacy: .public)") }
        report("after unregister")
    }
    #endif

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

#if DEBUG
private extension Snapshot {
    /// A `.drainingFast` snapshot on battery with 35 minutes left, for the simulated warning.
    static func demo(categories: [CategorySummary]) -> Snapshot {
        Snapshot(
            date: Date(),
            battery: BatteryReading(onBattery: true, percent: 40, drainWatts: 95, minutesLeft: 35, healthPercent: 93, cycleCount: 200),
            coresBusy: max(categories.reduce(0) { $0 + $1.cores }, 1) * 1.5,
            swapUsedBytes: 0, swapTotalBytes: 0, uptime: 0, categories: categories, mood: .drainingFast
        )
    }
}
#endif
