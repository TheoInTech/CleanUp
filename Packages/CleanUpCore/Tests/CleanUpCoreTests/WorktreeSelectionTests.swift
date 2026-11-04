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
}
