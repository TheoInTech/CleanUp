import Foundation

/// What a trash or permanent-removal run did: what moved, and what was kept (with why).
public struct WorktreeOutcome: Sendable, Equatable {
    public var moved: [Item]
    public var skipped: [(Item, String)]
    public var bytes: Int64
    public var permanent: Bool

    public init(moved: [Item], skipped: [(Item, String)], bytes: Int64, permanent: Bool) {
        self.moved = moved
        self.skipped = skipped
        self.bytes = bytes
        self.permanent = permanent
    }

    /// Skipped items compare by id and reason.
    public static func == (a: WorktreeOutcome, b: WorktreeOutcome) -> Bool {
        a.moved == b.moved && a.bytes == b.bytes && a.permanent == b.permanent
            && a.skipped.map(\.0.id) == b.skipped.map(\.0.id) && a.skipped.map(\.1) == b.skipped.map(\.1)
    }

    public var title: String {
        guard !moved.isEmpty else { return "Nothing moved" }
        let n = WorktreeCount.phrase(moved)
        return permanent ? "Removed \(n)" : "Moved \(n) to the Trash"
    }

    public var subtitle: String? {
        let kept = skipped.isEmpty ? nil : "\(skipped.count) kept"
        if moved.isEmpty { return kept }
        return Bytes.gb(bytes) + (kept.map { " · " + $0 } ?? "")
    }
}
