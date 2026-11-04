import CleanUpCore
import Foundation
import Observation
import os

/// The Worktrees category: stale git worktrees left behind by AI agents. It has its own scan, selection and
/// actions and never joins the main Clean up, the widget or the drain warning. All work happens in the
/// scanner and trash actors; this class only awaits them.
@Observable @MainActor
final class WorktreesModel {
    static let includeProtectedKey = "worktreesIncludeProtected"
    static let removePermanentlyKey = "worktreesRemovePermanently"
    /// Looked at again when the window opens if the last scan is older than this.
    static let staleAfter: TimeInterval = 60 * 60
    static let timerInterval: Duration = .seconds(6 * 60 * 60)

    private(set) var snapshot: WorktreeSnapshot?
    var selection = WorktreeSelection()
    var outcome: WorktreeOutcome?
    private(set) var isScanning = false
    /// Quick select ticks what is safe; Choose myself ticks nothing.
    var quickSelect = true {
        didSet {
            guard quickSelect != oldValue, let snapshot else { return }
            selection.setMode(quick: quickSelect, in: snapshot, keep: currentKeep())
        }
    }
    /// Reads the app's live Keep list, so a Keep added after launch counts straight away.
    @ObservationIgnored private let keepList: @MainActor () -> KeepList

    /// The Keep list every check uses: the app's, or in debug renders the fixture's own (never saved).
    private func currentKeep() -> KeepList {
        #if DEBUG
        if Self.isFixtureMode {
            var keep = KeepList.empty
            for id in debugKept { keep.add(id, name: id.rawValue) }
            return keep
        }
        #endif
        return keepList()
    }
    /// An action (clean up, undo, put back, delete) is under way; nothing else may start or scan meanwhile.
    private(set) var isBusy = false
    /// What the last put back or delete couldn't do, as one line for the Trash row
    /// ("2 couldn't be put back · find them in the Trash"); nil when everything went.
    private(set) var failure: String?

    var includeProtected: Bool {
        didSet {
            guard includeProtected != oldValue else { return }
            UserDefaults.standard.set(includeProtected, forKey: Self.includeProtectedKey)
            Task { await refresh(force: true) }
        }
    }
    var removePermanently: Bool {
        didSet { UserDefaults.standard.set(removePermanently, forKey: Self.removePermanentlyKey) }
    }

    @ObservationIgnored private let scanner: WorktreeScanner
    @ObservationIgnored private let trash: WorktreeTrash
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var scanRequestedWhileScanning = false
    /// The Trash records the last move created, so Undo and the result card's Delete now act on exactly those.
    private(set) var lastMoved: [UUID] = []
    @ObservationIgnored private let log = Logger(subsystem: "io.cleanup.CleanUp", category: "WorktreesModel")

    init(keepList: @escaping @MainActor () -> KeepList) {
        self.keepList = keepList
        includeProtected = UserDefaults.standard.bool(forKey: Self.includeProtectedKey)
        removePermanently = UserDefaults.standard.bool(forKey: Self.removePermanentlyKey)
        // The trash creates the folder itself when it first saves, off the main thread.
        let store = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/io.cleanup.CleanUp/Worktrees", isDirectory: true)
        scanner = WorktreeScanner()
        trash = WorktreeTrash(store: store)
    }

    /// Launch: scan now, then every 6 hours.
    func start() {
        guard timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh(force: true)
                try? await Task.sleep(for: Self.timerInterval)
            }
        }
    }

    // MARK: Refresh

    /// Scans again. Without `force`, a scan newer than the stale limit is left alone.
    func refresh(force: Bool) async {
        #if DEBUG
        // Debug renders show fixtures only: never look at the owner's real worktrees.
        if Self.isFixtureMode { return }
        #endif
        if isScanning || isBusy {
            if force { scanRequestedWhileScanning = true }
            return
        }
        if !force, let snapshot, Date().timeIntervalSince(snapshot.date) < Self.staleAfter { return }
        isScanning = true
        defer { isScanning = false }
        repeat {
            scanRequestedWhileScanning = false
            await trash.reconcile()
            let table = await Task.detached(priority: .utility) { ProcessTable.snapshot() }.value
            let entries = await trash.entries
            // Utility priority (background QoS throttles disk I/O so hard the walk takes hours): a full walk is heavy and nobody is waiting for it. Folder measuring is
            // already serial (the SizeCache actor runs one measure at a time).
            let pid = ProcessInfo.processInfo.processIdentifier
            let protected = includeProtected
            let scanner = self.scanner
            let fresh = await Task.detached(priority: .utility) {
                await scanner.scan(processes: table, ownPID: pid, includeProtected: protected, trashed: entries, now: Date())
            }.value
            snapshot = fresh
            if let fresh { selection.apply(fresh, keep: currentKeep(), quick: quickSelect) } else { selection = WorktreeSelection() }
        } while scanRequestedWhileScanning
    }

    func windowOpened() async {
        await refresh(force: false)
    }

    // MARK: Actions

    /// Removes exactly `ids`, the worktrees ticked when the button was pressed, the way `permanent` said
    /// then (the permanent-mode dialog is the UI's, and confirmed this same set). A scan that lands
    /// meanwhile can only take items away: one that is gone, no longer safe or kept since is skipped,
    /// and each one left is looked at again first.
    func cleanUp(ids: Set<ItemIdentity>, permanent: Bool) async {
        guard !isBusy, !ids.isEmpty, snapshot != nil, !Self.actionsBlocked else { return }
        isBusy = true
        failure = nil
        await scanSettled()
        guard let snapshot, case let items = WorktreeSelection.items(withIDs: ids, in: snapshot, keep: currentKeep()),
              !items.isEmpty else {
            isBusy = false
            return
        }
        let table = await Task.detached(priority: .userInitiated) { ProcessTable.snapshot() }.value
        let pid = ProcessInfo.processInfo.processIdentifier
        let scanner = self.scanner
        let recheck: WorktreeTrash.Recheck = { await scanner.recheck($0, processes: table, ownPID: pid, now: Date()) }
        if permanent {
            outcome = await trash.removePermanently(items, recheck: recheck)
            lastMoved = []
        } else {
            let before = Set(await trash.entries.map(\.id))
            outcome = await trash.moveToTrash(items, recheck: recheck)
            lastMoved = await trash.entries.map(\.id).filter { !before.contains($0) }
        }
        await finishAction()
    }

    /// Puts back what the last move to the Trash created.
    func undoLast() async {
        let ids = lastMoved
        guard !isBusy, !ids.isEmpty, !Self.actionsBlocked else { return }
        isBusy = true
        await scanSettled()
        lastMoved = await trash.putBack(ids)
        failure = Self.failureLine(lastMoved.count, "put back")
        outcome = nil
        await finishAction()
    }

    func putBack(_ ids: [UUID]) async {
        guard !isBusy, !Self.actionsBlocked else { return }
        isBusy = true
        await scanSettled()
        let failed = await trash.putBack(ids)
        if !failed.isEmpty { log.notice("\(failed.count) worktrees could not be put back") }
        failure = Self.failureLine(failed.count, "put back")
        lastMoved.removeAll { ids.contains($0) && !failed.contains($0) }
        closeOutcomeIfSpent()
        await finishAction()
    }

    func deleteNow(_ ids: [UUID]) async {
        guard !isBusy, !Self.actionsBlocked else { return }
        isBusy = true
        await scanSettled()
        await trash.deleteNow(ids)
        // Whatever is still recorded couldn't be deleted (out of reach, or no longer the item we trashed).
        let remaining = Set(await trash.entries.map(\.id))
        let failed = ids.filter(remaining.contains)
        if !failed.isEmpty { log.notice("\(failed.count) worktrees could not be deleted") }
        failure = Self.failureLine(failed.count, "deleted")
        lastMoved.removeAll { ids.contains($0) }
        closeOutcomeIfSpent()
        await finishAction()
    }

    /// The result card's Undo and Delete now act on the last move; once none of it is left in the
    /// Trash the card has nothing to offer, so it closes.
    private func closeOutcomeIfSpent() {
        if let outcome, !outcome.permanent, lastMoved.isEmpty { self.outcome = nil }
    }

    private static func failureLine(_ count: Int, _ verb: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) couldn't be \(verb) · find \(count == 1 ? "it" : "them") in the Trash"
    }

    /// A scan already under way (which may be reconciling the Trash record) finishes before an action starts.
    private func scanSettled() async {
        while isScanning { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Every action ends with a forced scan, which also runs any scan that was asked for meanwhile.
    private func finishAction() async {
        isBusy = false
        await refresh(force: true)
    }

    /// Ticks stay as they are while an action runs.
    func toggle(_ item: Item) {
        guard !isBusy else { return }
        selection.toggle(item)
    }

    // MARK: For the views

    /// What the own button would remove: ticked, safe, and not on the Keep list.
    var tickedItems: [Item] {
        guard let snapshot else { return [] }
        return selection.items(in: snapshot, keep: currentKeep())
    }

    var tickedBytes: Int64 {
        guard let snapshot else { return 0 }
        return selection.bytes(in: snapshot, keep: currentKeep())
    }

    /// Items that may be ticked at all: safe to remove and not always kept.
    var tickableItems: [Item] {
        guard let snapshot else { return [] }
        let keep = currentKeep()
        return snapshot.items.filter { WorktreeSnapshot.isSafe($0, keep: keep) }
    }

    /// Safe to remove right now: judged safe and not always kept. Always-kept ones count as kept.
    func isSafe(_ item: Item) -> Bool { WorktreeSnapshot.isSafe(item, keep: currentKeep()) }

    /// Storage split with the live Keep list, for the storage bar and the popover line.
    var safeBytes: Int64 { snapshot?.safeBytes(keep: currentKeep()) ?? 0 }
    var keptBytes: Int64 { snapshot?.keptBytes(keep: currentKeep()) ?? 0 }

    func isTicked(_ item: Item) -> Bool { tickedItems.contains { $0.id == item.id } }

    /// The header's tick: all, some or none of the tickable items.
    var tickState: TickState {
        let ticked = tickedItems.count
        if ticked == 0 { return .none }
        return ticked == tickableItems.count ? .all : .some
    }

    /// Ticks every tickable item, or clears them all when they already are.
    func toggleAll() {
        guard !isBusy else { return }
        if tickState == .all { selection.ticked = [] } else { selection.ticked.formUnion(tickableItems.map(\.id)) }
    }

    /// After "Keep" in the "?" sheet: the item is never ticked again.
    func kept(_ item: Item) { selection.ticked.remove(item.id) }

    /// The entries the last move put in the Trash, still there.
    var lastMovedBytes: Int64 {
        let ids = Set(lastMoved)
        return (snapshot?.trashed ?? []).filter { ids.contains($0.id) }.reduce(0) { $0 + $1.bytes }
    }

    func dismissOutcome() { outcome = nil }

    /// The main window scrolls to the Worktrees row (from the storage bar, or the popover opening the window).
    private(set) var revealPending = false
    func reveal() { revealPending = true }
    func revealed() { revealPending = false }

    // MARK: Debug fixtures

    /// Debug renders (`-debugSnapshotDir`) never scan or act: they show what `debugShow` hands in.
    private static var actionsBlocked: Bool {
        #if DEBUG
        isFixtureMode
        #else
        false
        #endif
    }

    #if DEBUG
    /// The fixture's "always kept" worktrees, kept apart from the owner's real Keep list.
    private var debugKept: Set<ItemIdentity> = []

    static var isFixtureMode: Bool { UserDefaults.standard.string(forKey: "debugSnapshotDir") != nil }

    /// Shows a made-up snapshot, result and failure line. Only in fixture mode, so it can never mix
    /// with a real scan.
    func debugShow(
        _ fixture: WorktreeSnapshot, outcome: WorktreeOutcome? = nil, lastMoved: [UUID] = [], failure: String? = nil,
        alwaysKept: Set<ItemIdentity> = []
    ) {
        guard Self.isFixtureMode else { return }
        debugKept = alwaysKept
        snapshot = fixture
        selection = WorktreeSelection()
        selection.apply(fixture, keep: currentKeep(), quick: quickSelect)
        self.outcome = outcome
        self.lastMoved = lastMoved
        self.failure = failure
    }
    #endif
}
