import Foundation

/// What the "Battery draining fast" notification says, built from a snapshot and the quick
/// selection. Pure, so the copy is tested without a notification center.
public struct DrainWarning: Equatable, Sendable {
    /// "4 idle simulators + 6 old containers": the two idle groups using the most cores.
    public let summary: String
    /// How many items the quick selection holds: the N in "Clean up N idle".
    public let idleCount: Int
    public let minutesLeft: Int?

    /// `Battery draining fast · 35 min left`, or without the minutes when the estimate is unknown.
    public var title: String {
        guard let minutesLeft else { return "Battery draining fast" }
        return "Battery draining fast · \(minutesLeft) min left"
    }

    public var actionTitle: String { "Clean up \(idleCount) idle" }

    public init(summary: String, idleCount: Int, minutesLeft: Int?) {
        self.summary = summary
        self.idleCount = idleCount
        self.minutesLeft = minutesLeft
    }

    /// Share of the busy cores that the quick selection would free (0 when nothing is busy).
    public static func idleShare(of selection: Selection, in snapshot: Snapshot) -> Double {
        selection.freedCores(in: snapshot) / max(snapshot.coresBusy, 0.1)
    }

    /// Nil when the selection is empty (nothing to offer). Engines add their cores to their category
    /// but are never counted as items: "6 old containers" means containers, not the engine.
    public static func make(snapshot: Snapshot, selection: Selection) -> DrainWarning? {
        guard selection.count > 0 else { return nil }
        var groups: [(category: CategoryID, cores: Double, count: Int)] = []
        for category in snapshot.categories {
            let ticked = category.items.filter { selection.ticked.contains($0.id) }
            guard !ticked.isEmpty else { continue }
            let count = ticked.filter { !isEngine($0) }.count
            guard count > 0, noun(for: category.id, count: count) != nil else { continue }
            groups.append((category.id, ticked.reduce(0) { $0 + $1.cores }, count))
        }
        let top = groups
            .sorted { ($0.cores, $1.category.rawValue) > ($1.cores, $0.category.rawValue) }
            .prefix(2)
        let parts = top.compactMap { noun(for: $0.category, count: $0.count) }
        let summary = parts.isEmpty ? "Idle background work" : parts.joined(separator: " + ")
        return DrainWarning(summary: summary, idleCount: selection.count, minutesLeft: snapshot.battery?.minutesLeft)
    }

    private static func isEngine(_ item: Item) -> Bool {
        item.id.rawValue.hasPrefix(Selection.enginePrefix)
    }

    /// "4 idle simulators", "1 old container", "2 old dev servers". Only the categories Quick select can tick.
    private static func noun(for category: CategoryID, count: Int) -> String? {
        let plural = count == 1 ? "" : "s"
        switch category {
        case .simulators: return "\(count) idle simulator\(plural)"
        case .containers: return "\(count) old container\(plural)"
        case .devServers: return "\(count) old dev server\(plural)"
        case .apps, .browserTabs, .restart, .worktrees: return nil
        }
    }
}
