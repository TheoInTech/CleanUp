import Foundation
import Testing
@testable import CleanUpCore

@Suite struct WorktreeSelectionTests {
    private func item(_ path: String, _ verdict: Verdict = .idle, bytes: Int64 = 100) -> Item {
        Item(
            id: .worktree(path: path), category: .worktrees, name: URL(fileURLWithPath: path).lastPathComponent,
            symbol: "arrow.triangle.branch",
            judgement: Judgement(verdict: verdict, fact: "f", signals: []), cores: 0, memoryBytes: 0, processes: [],
            detail: ["path": path, "bytes": String(bytes)])
    }

    private func snap(_ items: [Item]) -> WorktreeSnapshot { WorktreeSnapshot(date: Date(), items: items, trashed: []) }

    @Test func quickTicksSafeNotKept() {
        let a = item("/a"), b = item("/b"), c = item("/c", .inUse)
        var keep = KeepList.empty
        keep.add(b.id, name: "b")
        var sel = WorktreeSelection()
        sel.apply(snap([a, b, c]), keep: keep, quick: true)
        #expect(sel.ticked == [a.id])
    }

    @Test func untickedStaysUnticked() {
        let a = item("/a"), b = item("/b")
        let s = snap([a, b])
        var sel = WorktreeSelection()
        sel.apply(s, keep: .empty, quick: true)
        #expect(sel.ticked == [a.id, b.id])
        sel.toggle(a)
        sel.apply(s, keep: .empty, quick: true)
        #expect(sel.ticked == [b.id])
        // A newly safe item does get ticked.
        let c = item("/c")
        sel.apply(snap([a, b, c]), keep: .empty, quick: true)
        #expect(sel.ticked == [b.id, c.id])
    }

    @Test func goneOrKeptItemsDrop() {
        let a = item("/a"), b = item("/b")
        var sel = WorktreeSelection()
        sel.apply(snap([a, b]), keep: .empty, quick: true)
        sel.apply(snap([item("/a", .inUse)]), keep: .empty, quick: true)
        #expect(sel.ticked.isEmpty)
    }

    @Test func manualModeTicksNothing() {
        let a = item("/a")
        var sel = WorktreeSelection()
        sel.apply(snap([a]), keep: .empty, quick: false)
        #expect(sel.ticked.isEmpty)
        sel.toggle(a)
        #expect(sel.ticked == [a.id])
        sel.apply(snap([a]), keep: .empty, quick: false)
        #expect(sel.ticked == [a.id])
    }

    @Test func toggleRefusesKeptItems() {
        let k = item("/k", .inUse)
        var sel = WorktreeSelection()
        sel.toggle(k)
        #expect(sel.ticked.isEmpty)
    }

    @Test func bytesSumsTicked() {
        let a = item("/a", bytes: 100), b = item("/b", bytes: 250), c = item("/c", bytes: 7)
        let s = snap([a, b, c])
        var sel = WorktreeSelection()
        sel.apply(s, keep: .empty, quick: false)
        sel.toggle(a); sel.toggle(c)
        #expect(sel.bytes(in: s) == 107)
        #expect(Set(sel.items(in: s).map(\.id)) == [a.id, c.id])
    }

    @Test func keptAfterTickingIsExcluded() {
        let a = item("/a"), b = item("/b")
        let s = snap([a, b])
        var sel = WorktreeSelection()
        sel.apply(s, keep: .empty, quick: true)
        var keep = KeepList.empty
        keep.add(a.id, name: "a")
        #expect(sel.items(in: s, keep: keep).map(\.id) == [b.id])
        #expect(sel.bytes(in: s, keep: keep) == 100)
    }

    @Test func modeSwitchMirrorsTickController() {
        let a = item("/a"), b = item("/b")
        let s = snap([a, b])
        var sel = WorktreeSelection()
        sel.apply(s, keep: .empty, quick: true)
        sel.setMode(quick: false, in: s, keep: .empty)
        #expect(sel.ticked.isEmpty)
        sel.toggle(a)
        sel.setMode(quick: true, in: s, keep: .empty)
        #expect(sel.ticked == [a.id, b.id])
        sel.toggle(a)
        sel.apply(s, keep: .empty, quick: true)
        #expect(sel.ticked == [b.id])
    }

    @Test func confirmedIDsResolveToExactlyThoseStillSafe() {
        let a = item("/a"), b = item("/b"), c = item("/c"), d = item("/d", .inUse)
        var keep = KeepList.empty
        keep.add(b.id, name: "b")
        // Confirmed a, b, d and one that is gone; c is safe but was never confirmed.
        let ids: Set<ItemIdentity> = [a.id, b.id, d.id, .worktree(path: "/gone")]
        let items = WorktreeSelection.items(withIDs: ids, in: snap([a, b, c, d]), keep: keep)
        #expect(items.map(\.id) == [a.id])
    }

    @Test func alwaysKeptCountsAsKept() {
        let a = item("/a", bytes: 300), b = item("/b", bytes: 200), c = item("/c", .inUse, bytes: 50)
        var keep = KeepList.empty
        keep.add(b.id, name: "b")
        let s = snap([a, b, c])
        #expect(s.safeBytes(keep: keep) == 300)
        #expect(s.keptBytes(keep: keep) == 250)
        #expect(s.safeBytes == 500 && s.keptBytes == 50)
        #expect(!WorktreeSnapshot.isSafe(b, keep: keep) && WorktreeSnapshot.isSafe(a, keep: keep))
    }

    @Test func countPhrases() {
        #expect(WorktreeCount.phrase(worktrees: 1, leftovers: false) == "1 worktree")
        #expect(WorktreeCount.phrase(worktrees: 2, leftovers: false) == "2 worktrees")
        #expect(WorktreeCount.phrase(worktrees: 1, leftovers: true) == "1 worktree and leftover folders")
        #expect(WorktreeCount.phrase(worktrees: 3, leftovers: true) == "3 worktrees and leftover folders")
        #expect(WorktreeCount.phrase(worktrees: 0, leftovers: true) == "leftover folders")
        let left = Item.fixture(.worktreeLeftovers, category: .worktrees)
        #expect(WorktreeCount.phrase([item("/a"), item("/b"), left]) == "2 worktrees and leftover folders")
        #expect(WorktreeCount.phrase([left]) == "leftover folders")
        func entry(repo: String?) -> TrashedWorktree {
            TrashedWorktree(id: UUID(), path: "/p", repo: repo, storedAdmin: nil, trashURL: "/t", bytes: 1, date: Date())
        }
        #expect(WorktreeCount.phrase([entry(repo: "/r"), entry(repo: nil), entry(repo: nil)]) == "1 worktree and leftover folders")
        #expect(WorktreeCount.phrase([entry(repo: "/r"), entry(repo: "/r")]) == "2 worktrees")
    }

    @Test func storageCaptionLeavesOutZeroParts() {
        let gb: Int64 = 1_000_000_000
        #expect(WorktreeStorageCaption.text(safe: 14_200_000_000, kept: 8_200_000_000, trashed: 0)
            == "14.2 GB safe to remove · 8.2 GB kept")
        #expect(WorktreeStorageCaption.text(safe: 2 * gb, kept: 0, trashed: 3_100_000_000)
            == "2.0 GB safe to remove · 3.1 GB in the Trash")
        #expect(WorktreeStorageCaption.text(safe: 0, kept: 5 * gb, trashed: 0) == "0 GB safe to remove · 5.0 GB kept")
        #expect(WorktreeStorageCaption.text(safe: 50_000_000, kept: 0, trashed: 0) == "<0.1 GB safe to remove")
    }
}
