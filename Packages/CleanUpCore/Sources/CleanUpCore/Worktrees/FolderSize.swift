import Foundation

/// How much disk a folder uses and when anything inside it last changed.
/// `complete` is false when some entry couldn't be read: treat the measure as unknown.
public struct FolderMeasure: Sendable, Equatable, Codable {
    public var bytes: Int64
    public var newest: Date?
    public var complete: Bool

    public init(bytes: Int64, newest: Date?, complete: Bool = true) {
        self.bytes = bytes
        self.newest = newest
        self.complete = complete
    }
}

public enum FolderSize {
    /// One enumerator pass with prefetched keys. Symlinks count as themselves and are never followed;
    /// file contents are never read.
    public static func measure(_ url: URL) -> FolderMeasure {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey]
        var bytes: Int64 = 0
        var newest: Date?
        var complete = true
        let handler: (URL, Error) -> Bool = { _, _ in complete = false; return true }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: handler) else {
            return FolderMeasure(bytes: 0, newest: nil, complete: false)
        }
        for case let item as URL in walker {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { complete = false; continue }
            if let d = v.contentModificationDate, newest == nil || d > newest! { newest = d }
            if v.isSymbolicLink == true {
                // Size of the link itself; the enumerator does not descend into symlinked directories.
                bytes += Int64(v.totalFileAllocatedSize ?? 0)
            } else if v.isRegularFile == true {
                // Hard links are counted once per link, so this is an estimate and may be above `du`.
                if let size = v.totalFileAllocatedSize { bytes += Int64(size) } else { complete = false }
            }
        }
        return FolderMeasure(bytes: bytes, newest: newest, complete: complete)
    }
}

public actor SizeCache {
    private struct Entry {
        var measure: FolderMeasure
        var folderMTime: Date?
        var gitMTime: Date?
        var at: Date
    }

    private let maxAge: TimeInterval
    private var entries: [String: Entry] = [:]

    public init(maxAge: TimeInterval = 6 * 3600) {
        self.maxAge = maxAge
    }

    /// The cache key (folder mtime and `.git` mtime) does not see changes deep inside the folder, so a cached
    /// `newest` can be up to `maxAge` stale: use it for display only. The safety re-check before removal
    /// must pass `fresh: true`, which skips the lookup, measures again and stores the result.
    public func measure(_ url: URL, now: Date, fresh: Bool = false) -> FolderMeasure {
        let key = url.path
        let folder = Self.mtime(url)
        let git = Self.mtime(url.appendingPathComponent(".git"))
        if !fresh, let folder, let e = entries[key], e.folderMTime == folder, e.gitMTime == git,
           now >= e.at, now.timeIntervalSince(e.at) < maxAge {
            return e.measure
        }
        let m = FolderSize.measure(url)
        if m.complete {
            entries[key] = Entry(measure: m, folderMTime: folder, gitMTime: git, at: now)
        } else {
            entries[key] = nil
        }
        return m
    }

    private static func mtime(_ url: URL) -> Date? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9)
    }
}
