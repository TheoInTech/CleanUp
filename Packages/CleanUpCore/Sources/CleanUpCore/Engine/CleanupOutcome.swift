import Foundation

/// What a cleanup did, item by item, for the result card: each ticked item by name, stopped or
/// left running with the reason, stopped ones first.
public struct CleanupOutcome: Sendable, Equatable, Identifiable {
    public enum Result: Sendable, Equatable {
        case stopped
        case notStopped(String)
    }

    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: ItemIdentity
        public let name: String
        public let symbol: String
        public let category: CategoryID
        public let result: Result
    }

    public let id = UUID()
    public let entries: [Entry]
    public let freedCores: Double
    public let canUndo: Bool

    public init(items: [Item], report: CleanupReport) {
        let stopped = Set(report.stopped)
        var reasons: [ItemIdentity: String] = [:]
        for (id, reason) in report.failed + report.skipped { reasons[id] = reason }
        let all = items.map { item in
            Entry(
                id: item.id, name: item.name, symbol: item.symbol, category: item.category,
                result: stopped.contains(item.id) ? .stopped : .notStopped(reasons[item.id] ?? "Not stopped")
            )
        }
        entries = all.filter { $0.result == .stopped } + all.filter { $0.result != .stopped }
        freedCores = report.freedCores
        canUndo = !report.undo.isEmpty
    }

    public var stoppedCount: Int { entries.count { $0.result == .stopped } }
    public var allStopped: Bool { stoppedCount == entries.count }

    /// "Stopped 3" or "Nothing stopped".
    public var title: String { stoppedCount == 0 ? "Nothing stopped" : "Stopped \(stoppedCount)" }

    /// "1 left running · freed 1.2 cores"; nil when everything stopped and the savings are negligible.
    public var subtitle: String? {
        var parts: [String] = []
        let left = entries.count - stoppedCount
        if left > 0 { parts.append("\(left) left running") }
        if freedCores >= 0.05 { parts.append(String(format: "freed %.1f cores", freedCores)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    public static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}
