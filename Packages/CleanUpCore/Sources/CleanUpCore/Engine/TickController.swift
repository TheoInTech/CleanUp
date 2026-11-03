import Foundation

/// Quick select | Choose myself, and what is ticked, refresh after refresh. The app keeps one and
/// only presents it; every rule about what may be ticked lives here (and in `Selection`).
public struct TickController: Sendable {
    public enum Mode: Hashable, Sendable {
        /// Everything idle and not kept is ticked (never apps).
        case quick
        /// Nothing ticked until the user ticks it.
        case manual
    }

    /// A snapshot older than this is looked at again before a Clean up press acts on it.
    public static let staleAfter: TimeInterval = 10

    public private(set) var mode: Mode
    public private(set) var selection = Selection()
    /// What Quick select proposed last time; only newly proposed items are ticked on the next
    /// snapshot, so an item the user unticked stays unticked.
    private var lastQuickProposal: Set<ItemIdentity> = []

    public init(mode: Mode = .quick) {
        self.mode = mode
    }

    /// A new snapshot: in Quick select, tick what has newly become idle; then drop ticks that are
    /// gone or no longer tickable, and untick engines with an unticked container.
    public mutating func apply(_ s: Snapshot, keep: KeepList) {
        if mode == .quick {
            let proposal = Selection.quick(s, keep: keep).ticked
            selection.ticked.formUnion(proposal.subtracting(lastQuickProposal))
            lastQuickProposal = proposal
        }
        selection.reconcile(with: s)
    }

    public mutating func setMode(_ mode: Mode, in s: Snapshot, keep: KeepList) {
        guard mode != self.mode else { return }
        self.mode = mode
        switch mode {
        case .quick:
            selection = Selection.quick(s, keep: keep)
            lastQuickProposal = selection.ticked
        case .manual:
            selection = Selection()
            lastQuickProposal = []
        }
    }

    public mutating func toggle(_ item: Item, in s: Snapshot) {
        selection.toggle(item, in: s)
    }

    /// Header tick: unticks the whole category if anything in it is ticked; otherwise ticks its idle
    /// items that aren't Always kept (never apps, which are only ever ticked one by one). Two passes:
    /// containers first, so their engine can be ticked after them.
    public mutating func toggleCategory(_ id: CategoryID, in s: Snapshot, keep: KeepList) {
        guard let category = s.categories.first(where: { $0.id == id }) else { return }
        if selection.state(of: id, in: s) != .none {
            for item in category.items where selection.ticked.contains(item.id) { selection.toggle(item, in: s) }
            return
        }
        for _ in 0..<2 {
            for item in category.items where Self.canTickAll(item, keep: keep) && !selection.ticked.contains(item.id) {
                selection.toggle(item, in: s)
            }
        }
    }

    /// Whether the header tick has anything to tick in this category.
    public static func hasIdle(_ id: CategoryID, in s: Snapshot, keep: KeepList) -> Bool {
        s.categories.first { $0.id == id }?.items.contains { canTickAll($0, keep: keep) } ?? false
    }

    /// The header tick may tick it: idle, not an app, not Always kept.
    public static func canTickAll(_ item: Item, keep: KeepList) -> Bool {
        item.category != .apps && item.judgement.verdict == .idle && !keep.contains(item.id)
    }

    /// "Keep" was tapped: untick it, and don't let Quick select tick it back.
    public mutating func kept(_ item: Item, in s: Snapshot) {
        if selection.ticked.contains(item.id) { selection.toggle(item, in: s) }
        lastQuickProposal.remove(item.id)
    }

    public mutating func stopped(_ ids: [ItemIdentity]) {
        selection.ticked.subtract(ids)
    }

    /// What the notification's and the widget's "Clean up" stop: Quick select on a fresh snapshot.
    /// Never apps, never Always kept, never the user's own ticks.
    public static func cleanIdleSelection(_ s: Snapshot, keep: KeepList) -> Selection {
        Selection.quick(s, keep: keep)
    }

    /// The items a Clean up press stops: chosen and still tickable in `s`, in display order.
    public static func itemsToClean(_ chosen: Selection, in s: Snapshot) -> [Item] {
        s.allItems.filter { chosen.ticked.contains($0.id) && Selection.isTickable($0) }
    }

    /// Same, limited to what was ticked when the button was pressed: a refresh in between (a stale
    /// snapshot) can tick newly idle items in Quick select that the user never saw ticked.
    public static func itemsToClean(_ chosen: Selection, in s: Snapshot, pressed: Set<ItemIdentity>) -> [Item] {
        itemsToClean(chosen, in: s).filter { pressed.contains($0.id) }
    }

    public static func isStale(_ s: Snapshot, now: Date) -> Bool {
        now.timeIntervalSince(s.date) > staleAfter
    }
}
