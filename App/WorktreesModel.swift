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
            selection.setMode(quick: quickSelect, in: snapshot, keep: keepList())
        }
    }
    /// Reads the app's live Keep list, so a Keep added after launch counts straight away.
    @ObservationIgnored private let keepList: @MainActor () -> KeepList
    /// An action (clean up, undo, put back, delete) is under way; nothing else may start or scan meanwhile.
    private(set) var isBusy = false

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
    /// The Trash records the last move created, so Undo can put exactly those back.
    @ObservationIgnored private var lastMoved: [UUID] = []
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
            let fresh = await scanner.scan(
                processes: table, ownPID: ProcessInfo.processInfo.processIdentifier,
                includeProtected: includeProtected, trashed: entries, now: Date())
            snapshot = fresh
            if let fresh { selection.apply(fresh, keep: keepList(), quick: quickSelect) } else { selection = WorktreeSelection() }
        } while scanRequestedWhileScanning
    }

    func windowOpened() async {
        await refresh(force: false)
    }

    // MARK: Actions

    /// Removes the ticked worktrees, each looked at again first. Asks nothing: the permanent-mode dialog is the UI's.
    func cleanUp() async {
        guard !isBusy, snapshot != nil else { return }
        isBusy = true
        await scanSettled()
        // Read after any scan in flight lands, so the list is the current one, minus anything kept since.
        guard let snapshot, case let items = selection.items(in: snapshot, keep: keepList()), !items.isEmpty else {
            isBusy = false
            return
        }
        let table = await Task.detached(priority: .userInitiated) { ProcessTable.snapshot() }.value
        let pid = ProcessInfo.processInfo.processIdentifier
        let scanner = self.scanner
        let recheck: WorktreeTrash.Recheck = { await scanner.recheck($0, processes: table, ownPID: pid, now: Date()) }
        if removePermanently {
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
        guard !isBusy, !ids.isEmpty else { return }
        isBusy = true
        await scanSettled()
        lastMoved = await trash.putBack(ids)
        outcome = nil
        await finishAction()
    }

    func putBack(_ ids: [UUID]) async {
        guard !isBusy else { return }
        isBusy = true
        await scanSettled()
        let failed = await trash.putBack(ids)
        if !failed.isEmpty { log.notice("\(failed.count) worktrees could not be put back") }
        lastMoved.removeAll { ids.contains($0) && !failed.contains($0) }
        await finishAction()
    }

    func deleteNow(_ ids: [UUID]) async {
        guard !isBusy else { return }
        isBusy = true
        await scanSettled()
        await trash.deleteNow(ids)
        lastMoved.removeAll { ids.contains($0) }
        await finishAction()
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

    func toggle(_ item: Item) { selection.toggle(item) }
}
