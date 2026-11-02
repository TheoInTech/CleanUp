/// How much of a category is ticked, for its header checkbox.
public enum TickState: Sendable, Equatable {
    case all, some, none
}

/// What the user has ticked for cleaning. Keeps one invariant for container engines: an engine is
/// ticked only while every running container of that engine is ticked too (stopping the engine
/// stops them all).
public struct Selection: Equatable, Sendable {
    public var ticked: Set<ItemIdentity>

    public init(ticked: Set<ItemIdentity> = []) {
        self.ticked = ticked
    }

    public var count: Int { ticked.count }

    /// Everything idle and not kept, never an app (apps are only ever ticked by hand).
    public static func quick(_ s: Snapshot, keep: KeepList) -> Selection {
        let ids = s.allItems
            .filter { $0.category != .apps && $0.judgement.verdict == .idle && !keep.contains($0.id) }
            .map(\.id)
        var selection = Selection(ticked: Set(ids))
        selection.untickBlockedEngines(in: s)
        return selection
    }

    /// Items a user can tick: idle work and apps (by hand). Never in-use items, advice, or busy
    /// tabs (CleanUp can't stop a tab; the browser's task manager can).
    public static func isTickable(_ item: Item) -> Bool {
        switch item.judgement.verdict {
        case .idle, .manual: true
        case .inUse, .advice, .check: false
        }
    }

    /// Unticking a container also unticks its engine. Ticking an engine is refused while one of its
    /// running containers is unticked; ticking an in-use item or advice is refused.
    public mutating func toggle(_ item: Item, in s: Snapshot) {
        if ticked.contains(item.id) {
            ticked.remove(item.id)
            if Self.isContainer(item) {
                for engine in s.allItems where Self.engineName(of: engine) != nil && Self.container(item, belongsTo: engine) {
                    ticked.remove(engine.id)
                }
            }
            return
        }
        guard Self.isTickable(item) else { return }
        if Self.engineName(of: item) != nil, !uncheckedContainers(of: item, in: s).isEmpty { return }
        ticked.insert(item.id)
    }

    /// Brings ticks carried over from an older snapshot in line with `s`: drops ticks for items that
    /// are gone or no longer tickable (e.g. now in use), then unticks any engine with a running
    /// container that isn't ticked (a container that started since). Call it on every refresh.
    public mutating func reconcile(with s: Snapshot) {
        let tickable = Set(s.allItems.filter(Self.isTickable).map(\.id))
        ticked.formIntersection(tickable)
        untickBlockedEngines(in: s)
    }

    /// Matches the "N of M ticked" count over every item: `.all` only when every item in the
    /// category is ticked, so a category with an in-use item never looks fully ticked.
    public func state(of category: CategoryID, in s: Snapshot) -> TickState {
        let items = s.categories.filter { $0.id == category }.flatMap(\.items)
        let on = items.filter { ticked.contains($0.id) }.count
        if on == 0 { return .none }
        return on == items.count ? .all : .some
    }

    /// Cores the ticked items in this snapshot are using.
    public func freedCores(in s: Snapshot) -> Double {
        s.allItems.filter { ticked.contains($0.id) }.reduce(0) { $0 + $1.cores }
    }

    // MARK: Engine rules (containers relationship only)

    private mutating func untickBlockedEngines(in s: Snapshot) {
        for engine in s.allItems where Self.engineName(of: engine) != nil && ticked.contains(engine.id) {
            if !uncheckedContainers(of: engine, in: s).isEmpty { ticked.remove(engine.id) }
        }
    }

    private func uncheckedContainers(of engine: Item, in s: Snapshot) -> [Item] {
        s.allItems.filter { Self.isContainer($0) && Self.container($0, belongsTo: engine) && !ticked.contains($0.id) }
    }

    static let containerPrefix = "container:"
    static let enginePrefix = "engine:"

    static func isContainer(_ item: Item) -> Bool {
        item.category == .containers && item.id.rawValue.hasPrefix(containerPrefix)
    }

    /// The engine name for a container-engine item; nil for anything else (including the simulator services engine).
    static func engineName(of item: Item) -> String? {
        guard item.category == .containers, item.id.rawValue.hasPrefix(enginePrefix) else { return nil }
        return String(item.id.rawValue.dropFirst(enginePrefix.count))
    }

    /// A container without a recorded engine is treated as belonging to every engine (the safe direction).
    static func container(_ container: Item, belongsTo engine: Item) -> Bool {
        guard let name = engineName(of: engine) else { return false }
        guard let containerEngine = container.detail["engine"] else { return true }
        return containerEngine == name
    }
}

extension Snapshot {
    /// Every item in every category, in display order.
    public var allItems: [Item] { categories.flatMap(\.items) }

    public func item(withID id: ItemIdentity) -> Item? {
        categories.lazy.flatMap(\.items).first { $0.id == id }
    }
}
