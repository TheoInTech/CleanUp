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

    public init(id: UUID, path: String, repo: String?, storedAdmin: String?, trashURL: String, bytes: Int64, date: Date) {
        self.id = id
        self.path = path
        self.repo = repo
        self.storedAdmin = storedAdmin
        self.trashURL = trashURL
        self.bytes = bytes
        self.date = date
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

    /// Bytes in worktrees that are safe to remove (including leftover folders).
    public var safeBytes: Int64 { items.filter { $0.judgement.verdict == .idle }.reduce(0) { $0 + Self.bytes($1) } }
    /// Bytes in worktrees that are kept.
    public var keptBytes: Int64 { items.filter { $0.judgement.verdict != .idle }.reduce(0) { $0 + Self.bytes($1) } }
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

        var items: [Item] = []
        await withTaskGroup(of: [Item].self) { group in
            var next = repos.makeIterator()
            func addNext() {
                guard let repo = next.next() else { return }
                group.addTask {
                    await Self.items(
                        repo: repo, git: git, sizes: sizes, processes: processes, ownPID: ownPID, now: now)
                }
            }
            for _ in 0..<Self.concurrency { addNext() }
            while let done = await group.next() {
                items += done
                addNext()
            }
        }

        if let leftovers = await leftoverItem(now: now) { items.append(leftovers) }

        items.sort {
            let (a, b) = (Self.bytes($0), Self.bytes($1))
            return a != b ? a > b : $0.id.rawValue < $1.id.rawValue
        }
        return WorktreeSnapshot(date: now, items: items, trashed: trashed)
    }

    private static func bytes(_ item: Item) -> Int64 { item.detail["bytes"].flatMap { Int64($0) } ?? 0 }

    private static func items(
        repo: String, git: GitWorktrees, sizes: SizeCache, processes: [Int32: ProcessInfoRecord],
        ownPID: Int32, now: Date
    ) async -> [Item] {
        guard let entries = await git.list(repo: repo) else { return [] }
        let repoName = URL(fileURLWithPath: repo).lastPathComponent
        var out: [Item] = []
        for e in entries {
            let m = await sizes.measure(URL(fileURLWithPath: e.path), now: now)
            // An incomplete or empty measure says nothing about recent activity: judge it as kept.
            let lastChange = m.complete ? m.newest : nil
            let facts = await git.facts(e, repo: repo, processes: processes, ownPID: ownPID, lastChange: lastChange)
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
