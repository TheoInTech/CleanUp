import Foundation

/// How much disk a folder uses and when anything inside it last changed.
/// `complete` is false when some entry couldn't be read: treat the measure as unknown.
/// `holdsOtherCheckout` is true when a `.git` file sits somewhere below the top level: another worktree
/// lives inside this folder, and removing the folder would take that one with it.
public struct FolderMeasure: Sendable, Equatable, Codable {
    public var bytes: Int64
    public var newest: Date?
    public var complete: Bool
    public var holdsOtherCheckout: Bool

    public init(bytes: Int64, newest: Date?, complete: Bool = true, holdsOtherCheckout: Bool = false) {
        self.bytes = bytes
        self.newest = newest
        self.complete = complete
        self.holdsOtherCheckout = holdsOtherCheckout
    }
}

public enum FolderSize {
    /// Entries handled per autorelease pool, so a walk of millions of files doesn't pile up objects.
    private static let poolBatch = 1000

    /// One enumerator pass with prefetched keys. Symlinks count as themselves and are never followed;
    /// file contents are never read.
    public static func measure(_ url: URL) -> FolderMeasure {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
            .linkCountKey, .fileResourceIdentifierKey]
        let keySet = Set(keys)
        var bytes: Int64 = 0
        var newest: Date?
        var complete = true
        var holdsOtherCheckout = false
        var seen = Set<NSObject>()   // files with several hard links, counted once like `du`
        let handler: (URL, Error) -> Bool = { _, _ in complete = false; return true }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: handler) else {
            return FolderMeasure(bytes: 0, newest: nil, complete: false)
        }

        func visit(_ item: URL) {
            guard let v = try? item.resourceValues(forKeys: keySet) else { complete = false; return }
            if let d = v.contentModificationDate, newest == nil || d > newest! { newest = d }
            if v.isSymbolicLink == true {
                // Size of the link itself; the enumerator does not descend into symlinked directories.
                bytes += Int64(v.totalFileAllocatedSize ?? 0)
            } else if v.isRegularFile == true {
                // A `.git` file is a worktree's marker. The top-level one is this folder's own; any deeper one
                // is another worktree. A `.git` folder (a full clone, like a SwiftPM checkout) is not.
                if walker.level > 1, item.lastPathComponent == ".git" { holdsOtherCheckout = true }
                if (v.linkCount ?? 1) > 1, let id = v.fileResourceIdentifier as? NSObject, !seen.insert(id).inserted {
                    return
                }
                if let size = v.totalFileAllocatedSize { bytes += Int64(size) } else { complete = false }
            }
        }

        var finished = false
        while !finished {
            autoreleasepool {
                for _ in 0..<poolBatch {
                    guard let next = walker.nextObject() else { finished = true; return }
                    if let item = next as? URL { visit(item) }
                }
            }
        }
        return FolderMeasure(bytes: bytes, newest: newest, complete: complete, holdsOtherCheckout: holdsOtherCheckout)
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

    public init(maxAge: TimeInterval = 24 * 3600) {
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
