import Foundation

/// A worktree CleanUp moved to the Trash, remembered so it can be put back.
public struct TrashedWorktree: Codable, Sendable, Equatable {
    public var id: UUID
    public var path: String
    public var repo: String?
    public var storedAdmin: String?
    public var trashURL: String
    public var bytes: Int64
    public var date: Date
    /// Inode and device of the item in the Trash right after it was trashed; nil in older records.
    /// Lets later steps tell that the name has since been reused by something else.
    public var fileID: UInt64?
    public var device: Int64?
    /// Where git's record lived before it was moved to the store (`<repo>/.git/worktrees/<name>`); nil in
    /// older records and for leftover folders.
    public var gitDir: String?

    public init(
        id: UUID, path: String, repo: String?, storedAdmin: String?, trashURL: String, bytes: Int64, date: Date,
        fileID: UInt64? = nil, device: Int64? = nil, gitDir: String? = nil
    ) {
        self.id = id
        self.path = path
        self.repo = repo
        self.storedAdmin = storedAdmin
        self.trashURL = trashURL
        self.bytes = bytes
        self.date = date
        self.fileID = fileID
        self.device = device
        self.gitDir = gitDir
    }
}

public struct WorktreeSnapshot: Sendable {
    public var date: Date
    public var items: [Item]
    public var trashed: [TrashedWorktree]

    public init(date: Date, items: [Item], trashed: [TrashedWorktree]) {
        self.date = date
        self.items = items
        self.trashed = trashed
    }

    private static func bytes(_ item: Item) -> Int64 { item.detail["bytes"].flatMap { Int64($0) } ?? 0 }

    /// Safe to remove: judged safe and not on the Keep list. Everything else is kept.
    public static func isSafe(_ item: Item, keep: KeepList) -> Bool {
        item.judgement.verdict == .idle && !keep.contains(item.id)
    }

    /// Bytes in worktrees that are safe to remove (including leftover folders), always-kept ones excluded.
    public func safeBytes(keep: KeepList) -> Int64 {
        items.filter { Self.isSafe($0, keep: keep) }.reduce(0) { $0 + Self.bytes($1) }
    }
    /// Bytes in worktrees that are kept, always-kept ones included.
    public func keptBytes(keep: KeepList) -> Int64 {
        items.filter { !Self.isSafe($0, keep: keep) }.reduce(0) { $0 + Self.bytes($1) }
    }
    public var safeBytes: Int64 { safeBytes(keep: .empty) }
    public var keptBytes: Int64 { keptBytes(keep: .empty) }
    public var trashedBytes: Int64 { trashed.reduce(0) { $0 + $1.bytes } }
}

/// Finds git worktrees left behind by AI agents and judges which are safe to remove.
public actor WorktreeScanner {
    private static let concurrency = 4

    private let git: GitWorktrees
    private let home: URL
    private let sizes: SizeCache

    public init(
        git: GitWorktrees = .init(), home: URL = FileManager.default.homeDirectoryForCurrentUser,
        sizes: SizeCache = .init()
    ) {
        self.git = git
        self.home = home
        self.sizes = sizes
    }

    /// nil when git is not available.
    public func scan(
        processes: [Int32: ProcessInfoRecord], ownPID: Int32, includeProtected: Bool,
        trashed: [TrashedWorktree], now: Date
    ) async -> WorktreeSnapshot? {
        guard await git.available() else { return nil }
        let home = self.home
        let repos = await Task.detached { WorktreeDiscovery.repositories(home: home, includeProtected: includeProtected) }.value
        let git = self.git
        let sizes = self.sizes

        // Every repository's list first, so a worktree that holds another one (from any repository) is known
        // before anything is judged, even when the folder walk can't see the inner one.
        let lists = await Self.limited(repos) { repo in (repo, await git.list(repo: repo)) }
        let listed = Set(lists.flatMap { $0.1 ?? [] }.map(\.path))
        var items = await Self.limited(lists.compactMap { r in r.1.map { (r.0, $0) } }) { repo, entries in
            await Self.items(
                repo: repo, entries: entries, listed: listed, git: git, sizes: sizes, processes: processes,
                ownPID: ownPID, now: now)
        }.flatMap { $0 }

        if let leftovers = await leftoverItem(now: now) { items.append(leftovers) }

        items.sort {
            let (a, b) = (Self.bytes($0), Self.bytes($1))
            return a != b ? a > b : $0.id.rawValue < $1.id.rawValue
        }
        return WorktreeSnapshot(date: now, items: items, trashed: trashed)
    }

    /// Looks at an item again just before it is removed: a fresh measure (never the cache), the current
    /// git state and process table. Anything that can't be checked again is kept.
    public func recheck(
        _ item: Item, processes: [Int32: ProcessInfoRecord], ownPID: Int32, now: Date
    ) async -> Judgement {
        func kept(_ fact: String) -> Judgement {
            Judgement(verdict: .inUse, fact: fact, signals: [Signal(kind: .inUse, text: fact)])
        }
        if item.id == .worktreeLeftovers {
            let home = self.home
            let current = Set(await Task.detached { WorktreeDiscovery.leftoverAgentFolders(home: home) }.value.map(\.path))
            let wanted = (item.detail["paths"] ?? "").split(separator: "\n").map(String.init)
            guard !wanted.isEmpty, wanted.allSatisfy(current.contains) else { return kept("no longer empty") }
            return Judgement(verdict: .idle, fact: item.judgement.fact, signals: item.judgement.signals)
        }
        guard let path = item.detail["path"], let repo = item.detail["repo"],
              let entries = await git.list(repo: repo), let entry = entries.first(where: { $0.path == path })
        else { return kept("can't check it again") }
        let m = await sizes.measure(URL(fileURLWithPath: path), now: now, fresh: true)
        let facts = await git.facts(
            entry, repo: repo, processes: processes, ownPID: ownPID, lastChange: m.complete ? m.newest : nil,
            holdsOtherCheckout: m.holdsOtherCheckout || Self.holdsListed(path, in: Set(entries.map(\.path))))
        return WorktreeJudge.judge(facts, now: now)
    }

    private static func bytes(_ item: Item) -> Int64 { item.detail["bytes"].flatMap { Int64($0) } ?? 0 }

    /// Whether another listed worktree lives inside `path`.
    private static func holdsListed(_ path: String, in listed: Set<String>) -> Bool {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        return listed.contains { $0 != path && $0.hasPrefix(prefix) }
    }

    /// Runs `work` on every input, a few at a time.
    private static func limited<T: Sendable, R: Sendable>(
        _ inputs: [T], _ work: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        var out: [R] = []
        await withTaskGroup(of: R.self) { group in
            var next = inputs.makeIterator()
            func addNext() {
                guard let input = next.next() else { return }
                group.addTask { await work(input) }
            }
            for _ in 0..<concurrency { addNext() }
            while let done = await group.next() {
                out.append(done)
                addNext()
            }
        }
        return out
    }

    private static func items(
        repo: String, entries: [GitWorktreeEntry], listed: Set<String>, git: GitWorktrees, sizes: SizeCache,
        processes: [Int32: ProcessInfoRecord], ownPID: Int32, now: Date
    ) async -> [Item] {
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        var out: [Item] = []
        for e in entries {
            let m = await sizes.measure(URL(fileURLWithPath: e.path), now: now)
            // An incomplete or empty measure says nothing about recent activity: judge it as kept.
            let lastChange = m.complete ? m.newest : nil
            let facts = await git.facts(
                e, repo: repo, processes: processes, ownPID: ownPID, lastChange: lastChange,
                holdsOtherCheckout: m.holdsOtherCheckout || holdsListed(e.path, in: listed))
            var detail = ["path": e.path, "repo": repo, "repoName": repoName, "bytes": String(m.bytes)]
            if let b = e.branch { detail["branch"] = b }
            if let a = facts.agent { detail["agent"] = a }
            out.append(Item(
                id: .worktree(path: e.path), category: .worktrees,
                name: URL(fileURLWithPath: e.path).lastPathComponent, symbol: "arrow.triangle.branch",
                judgement: WorktreeJudge.judge(facts, now: now), cores: 0, memoryBytes: 0, processes: [],
                detail: detail))
        }
        return out
    }

    private func leftoverItem(now: Date) async -> Item? {
        let home = self.home
        let folders = await Task.detached { WorktreeDiscovery.leftoverAgentFolders(home: home) }.value
        guard !folders.isEmpty else { return nil }
        var total: Int64 = 0
        for f in folders { total += await sizes.measure(f, now: now).bytes }
        let n = folders.count
        let judgement = Judgement(
            verdict: .idle, fact: n == 1 ? "1 empty folder" : "\(n) empty folders",
            signals: [Signal(kind: .idle, text: "Only the agent's own marker files are left")])
        return Item(
            id: .worktreeLeftovers, category: .worktrees, name: "Leftover agent folders",
            symbol: "arrow.triangle.branch", judgement: judgement, cores: 0, memoryBytes: 0, processes: [],
            detail: ["paths": folders.map(\.path).joined(separator: "\n"), "bytes": String(total)])
    }
}
