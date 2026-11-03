import Foundation

/// The latest snapshot, shared with the widget as JSON in the App Group container.
public enum SnapshotStore {
    public static let fileName = "snapshot.json"

    public enum StoreError: Error {
        case noGroupContainer(String)
    }

    /// `<group container>/snapshot.json`, or nil when the App Group isn't available.
    public static func url(groupID: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?
            .appendingPathComponent(fileName)
    }

    public static func write(_ s: Snapshot, groupID: String) throws {
        guard let url = url(groupID: groupID) else { throw StoreError.noGroupContainer(groupID) }
        try write(s, to: url)
    }

    /// nil on any error (no container, no file, unreadable, undecodable).
    public static func read(groupID: String) -> Snapshot? {
        url(groupID: groupID).flatMap { read(from: $0) }
    }

    /// Atomic: a reader sees the old file or the new one, never half of one.
    public static func write(_ s: Snapshot, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
}

/// Writes snapshots one at a time, newest wins: a snapshot older than the last one written is
/// dropped, so a slow write can never put an old snapshot back over a newer one.
public actor SnapshotWriter {
    private let url: URL
    private var lastWritten: UInt64?

    public init(url: URL) {
        self.url = url
    }

    /// True when `s` was written; false when a newer (or the same) snapshot is already there.
    /// `sequence` counts up as the app makes snapshots; it orders them, not the wall clock, which
    /// can step back (a time sync) and would otherwise freeze the widget until it caught up.
    @discardableResult
    public func write(_ s: Snapshot, sequence: UInt64) throws -> Bool {
        if let lastWritten, sequence <= lastWritten { return false }
        try SnapshotStore.write(s, to: url)
        lastWritten = sequence
        return true
    }
}
