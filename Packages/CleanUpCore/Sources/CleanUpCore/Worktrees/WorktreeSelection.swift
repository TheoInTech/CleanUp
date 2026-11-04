import Foundation

/// What is ticked in the worktrees list. Quick select ticks what is newly safe and not kept; an item the
/// user unticked stays unticked (like `TickController`). Only `.idle` items can ever be ticked.
public struct WorktreeSelection: Sendable, Equatable {
    public var ticked: Set<ItemIdentity>
    /// What Quick select proposed last time; only newly proposed items are ticked on the next snapshot.
    private var proposed: Set<ItemIdentity> = []

    public init(ticked: Set<ItemIdentity> = []) {
        self.ticked = ticked
    }

    public mutating func apply(_ s: WorktreeSnapshot, keep: KeepList, quick: Bool) {
        let idle = Set(s.items.filter { $0.judgement.verdict == .idle }.map(\.id))
        if quick {
            let proposal = Set(s.items.filter { $0.judgement.verdict == .idle && !keep.contains($0.id) }.map(\.id))
            ticked.formUnion(proposal.subtracting(proposed))
            proposed = proposal
        } else {
            proposed = []
        }
        ticked.formIntersection(idle)
    }

    /// Ticks or unticks an item; one that isn't safe to remove can't be ticked.
    public mutating func toggle(_ item: Item) {
        if ticked.contains(item.id) {
            ticked.remove(item.id)
        } else if item.judgement.verdict == .idle {
            ticked.insert(item.id)
        }
    }

    /// Switches like `TickController.setMode`: Quick select ticks everything safe and not kept at once;
    /// Choose myself clears every tick.
    public mutating func setMode(quick: Bool, in s: WorktreeSnapshot, keep: KeepList) {
        if quick {
            proposed = Set(s.items.filter { $0.judgement.verdict == .idle && !keep.contains($0.id) }.map(\.id))
            ticked = proposed
        } else {
            ticked = []
            proposed = []
        }
    }

    /// The ticked items that may still be removed: safe, and not on the Keep list.
    public func items(in s: WorktreeSnapshot, keep: KeepList = .empty) -> [Item] {
        s.items.filter { ticked.contains($0.id) && $0.judgement.verdict == .idle && !keep.contains($0.id) }
    }

    public func bytes(in s: WorktreeSnapshot, keep: KeepList = .empty) -> Int64 {
        items(in: s, keep: keep).reduce(0) { $0 + ($1.detail["bytes"].flatMap { Int64($0) } ?? 0) }
    }
}
