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
    /// WidgetKit may skip reloads; ask again at least this often so the widget never shows a false
    /// "Open CleanUp" (it calls a snapshot older than 15 minutes stale).
    static let widgetReloadInterval: TimeInterval = 10 * 60

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
    /// The last cleanup, item by item, shown as a card until dismissed (or for a minute).
    var outcome: CleanupOutcome?
    /// The item whose "?" sheet is open.
    var explaining: Item?
    /// The main window is on screen.
    var windowVisible = false {
        didSet {
            guard windowVisible != oldValue else { return }
            wakeRefreshLoop()
            if windowVisible { Task { await worktrees.windowOpened() } }
        }
    }
    /// The menu bar popover is on screen.
    var popoverVisible = false {
        didSet { if popoverVisible != oldValue { wakeRefreshLoop() } }
    }
    /// Either surface is on screen: refresh every 5 s instead of every 60 s. Tracked per surface so
    /// closing one never slows the refresh while the other is still open.
    var isVisible: Bool { windowVisible || popoverVisible }
    private(set) var isCleaning = false
    /// A notification or widget cleanup is under way (it looks again before stopping anything);
    /// nothing else may start one meanwhile, and no "Nothing idle" toast covers the real one.
    private(set) var cleanIdleInFlight = false
    private(set) var keepList = KeepList(defaults: .standard)
    /// Stale git worktrees: scanned and cleaned on their own, never part of the main Clean up.
    let worktrees = WorktreesModel()
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
    /// The refresh loop's wait until the next refresh is due; cancelled when visibility changes.
    @ObservationIgnored private var sleeper: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var lastRefresh: Date?
    @ObservationIgnored private var lastExternal: Date?
    @ObservationIgnored private var lastUndo: [UndoToken] = []
    @ObservationIgnored private var toastDismissal: Task<Void, Never>?
    @ObservationIgnored private var outcomeDismissal: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.cleanup.CleanUp", category: "AppModel")
    @ObservationIgnored private var drainMonitor: DrainMonitor
    @ObservationIgnored private let notificationDelegate = NotificationDelegate()
    @ObservationIgnored private var signalToken: Int32 = NOTIFY_TOKEN_INVALID
    @ObservationIgnored private var signalGate = CleanupSignalGate()
    @ObservationIgnored private var workspaceObservers: [any NSObjectProtocol] = []
    /// Snapshots for the widget, written in order by one consumer (newest wins).
    @ObservationIgnored private var snapshotOutbox: AsyncStream<(Snapshot, Bool, UInt64)>.Continuation?
    /// Counts snapshots as they are made, so the writer keeps their order whatever the clock does.
    @ObservationIgnored private var snapshotSequence: UInt64 = 0
    @ObservationIgnored private var lastWidgetReload: Date?
    /// Opens the main window; set by the menu bar label, the one view that always exists. "Show me"
    /// tapped before it is set (a cold launch from the notification) opens the window once it is.
    @ObservationIgnored var openMainWindow: (() -> Void)? {
        didSet {
            guard pendingMainWindow, let openMainWindow else { return }
            pendingMainWindow = false
            openMainWindow()
        }
    }
    @ObservationIgnored private var pendingMainWindow = false

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
        worktrees.start()
        startSnapshotSharing()
        startIntegrations()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Sleep until the next refresh is due. Opening or closing the window or popover cancels
                // the sleep, and the wait is worked out again for the new interval.
                while !Task.isCancelled, let wait = self.timeUntilDue, wait > 0 {
                    let sleeper = Task<Void, Never> { try? await Task.sleep(for: .seconds(wait)) }
                    self.sleeper = sleeper
                    await sleeper.value
                    self.sleeper = nil
                }
            }
        }
    }

    /// Seconds until the next refresh is due; nil before the first one.
    private var timeUntilDue: TimeInterval? {
        guard let lastRefresh else { return nil }
        let interval = isVisible ? Self.visibleInterval : Self.backgroundInterval
        return interval - Date().timeIntervalSince(lastRefresh)
    }

    private func wakeRefreshLoop() {
        sleeper?.cancel()
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
        let now = Date()
        let widgetChanged = fresh.mood != oldMood || quick.count != oldIdle
            || lastWidgetReload.map { now.timeIntervalSince($0) >= Self.widgetReloadInterval } ?? true
        if widgetChanged { lastWidgetReload = now }
        warnIfDrainingFast(fresh)
        // The widget can't read the Always-kept list, so it gets the idle count from here. It needs no
        // item details or signals (command lines, paths), so they stay in the app.
        writeSnapshot(
            fresh.withQuickSummary(idleCount: quick.count, freedCores: quick.freedCores(in: fresh)).forWidget(),
            reloadWidgets: widgetChanged
        )
    }

    /// One consumer writes the widget's snapshots in the order they were made (and never an older
    /// one over a newer one); when asked, it reloads the widget only after the file is written, so
    /// the widget never reads the previous snapshot.
    private func startSnapshotSharing() {
        guard let groupID, !groupID.hasPrefix("."), let url = SnapshotStore.url(groupID: groupID) else { return }
        let (stream, outbox) = AsyncStream.makeStream(of: (Snapshot, Bool, UInt64).self)
        snapshotOutbox = outbox
        let writer = SnapshotWriter(url: url)
        let log = self.log
        Task.detached(priority: .utility) {
            for await (snapshot, reload, sequence) in stream {
                do {
                    if try await writer.write(snapshot, sequence: sequence), reload { WidgetCenter.shared.reloadAllTimelines() }
                } catch {
                    log.error("Snapshot not shared: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    private func writeSnapshot(_ s: Snapshot, reloadWidgets: Bool) {
        snapshotSequence += 1
        snapshotOutbox?.yield((s, reloadWidgets, snapshotSequence))
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

    /// The Clean up button (window and popover): stops every ticked item, shows each one in the outcome card, then
    /// rescans. A snapshot more than 10 s old is looked at again first; only what is still ticked and
    /// tickable in the fresh one is stopped.
    @discardableResult
    func cleanUp() async -> CleanupReport? {
        guard !isCleaning, !cleanIdleInFlight else { return nil }
        isCleaning = true
        let pressed = ticks.selection.ticked   // what the button promised; a refresh may tick more
        if TickController.isStale(snapshot, now: Date()) {
            await refresh(forceExternal: true)   // applying it reconciles the ticks with what is there now
        }
        return await perform(TickController.itemsToClean(ticks.selection, in: snapshot, pressed: pressed))
    }

    /// Stops one item from its "?" sheet. `force` is "Stop anyway" on an in-use item: the engine
    /// skips its idle checks for this one item but keeps every safety guard. Engines are never forced.
    func stop(_ item: Item, force: Bool = false) async {
        guard !isCleaning, !cleanIdleInFlight else { return }
        isCleaning = true
        let current = snapshot.item(withID: item.id) ?? item
        await perform([current], forced: force && !current.isEngine ? [current.id] : [])
    }

    /// Runs with `isCleaning` already set, and clears it when done.
    @discardableResult
    private func perform(_ items: [Item], forced: Set<ItemIdentity> = []) async -> CleanupReport? {
        defer { isCleaning = false }
        guard !items.isEmpty else { return nil }

        let report = await clean(items, forced: forced)
        lastUndo = report.undo
        ticks.stopped(report.stopped)

        dismissToast()
        show(CleanupOutcome(items: items, report: report))
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
        dismissOutcome()
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

        Notifications.registerDrainCategory(idleCount: nil)

        // The widget's "Clean up" button posts this; it does exactly what the notification button does.
        signalToken = CleanupSignal.observe {
            Task { @MainActor in AppModel.shared.handleCleanupSignal() }
        }
        if signalToken == NOTIFY_TOKEN_INVALID { log.error("Couldn't listen for the widget's clean signal") }

        // Time asleep wasn't watched: no observation window may count it as quiet.
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await AppModel.shared.scanner.restartObservation() }
        })

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

    /// The Darwin signal is unauthenticated (anything can post it): act only on a fresh request the
    /// widget wrote into the App Group, newer than the last one handled, at most every 30 s.
    private func handleCleanupSignal() {
        let requestedAt = groupID
            .flatMap { $0.hasPrefix(".") ? nil : CleanupRequest.url(groupID: $0) }
            .flatMap(CleanupRequest.read(from:))
        guard signalGate.accept(requestedAt: requestedAt, now: Date()) else {
            log.notice("Ignored a clean signal without a fresh widget request")
            return
        }
        Task { await cleanIdle() }
    }

    /// "Clean up N idle" from the notification or the widget. Looks again first and decides from the
    /// fresh scan, never from the numbers in the notification, which may be minutes old. Quick select
    /// only: never forced, never apps, and the user's own ticks stay as they were.
    func cleanIdle() async {
        guard !isCleaning, !cleanIdleInFlight else { return await sayAlreadyCleaning() }
        cleanIdleInFlight = true
        defer { cleanIdleInFlight = false }
        await refresh(forceExternal: true)
        // A Clean up pressed in the window meanwhile is already stopping things: let it finish.
        guard !isCleaning else { return await sayAlreadyCleaning() }
        let quick = TickController.cleanIdleSelection(snapshot, keep: keepList)
        guard quick.count > 0 else {
            show(ToastState("Nothing idle"), for: .seconds(4))
            if !isVisible { await Notifications.postResult("Nothing idle to stop") }
            return
        }
        isCleaning = true
        guard let report = await perform(TickController.itemsToClean(quick, in: snapshot)) else { return }
        // With no window or popover open the toast is invisible, so say it in a quiet notification.
        if !isVisible { await Notifications.postResult(Self.summary(of: report).joined(separator: " · ")) }
    }

    /// A second Clean up (notification or widget) while one runs: say so instead of doing nothing.
    private func sayAlreadyCleaning() async {
        if isVisible { show(ToastState("Already cleaning up"), for: .seconds(4)) }
        else { await Notifications.postResult("Already cleaning up") }
    }

    func showMainWindow() {
        NSApp.activate()
        if let openMainWindow { openMainWindow() } else { pendingMainWindow = true }
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

    private func show(_ outcome: CleanupOutcome) {
        outcomeDismissal?.cancel()
        withAnimation(.snappy) { self.outcome = outcome }
        let id = outcome.id
        outcomeDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled, let self, self.outcome?.id == id else { return }
            withAnimation(.snappy) { self.outcome = nil }
        }
    }

    func dismissOutcome() {
        outcomeDismissal?.cancel()
        withAnimation(.snappy) { outcome = nil }
    }

    /// Whether anything on screen could be ticked right now (idle items, or apps by hand).
    var hasTickable: Bool {
        snapshot.categories.contains { $0.items.contains(where: Selection.isTickable) }
    }

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
