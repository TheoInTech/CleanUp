import Foundation

/// One linked worktree as `git worktree list --porcelain` reports it.
public struct GitWorktreeEntry: Sendable, Equatable {
    public var path: String
    public var head: String
    public var branch: String?
    public var locked: Bool
    public var prunable: Bool

    public init(path: String, head: String, branch: String?, locked: Bool, prunable: Bool) {
        self.path = path
        self.head = head
        self.branch = branch
        self.locked = locked
        self.prunable = prunable
    }
}

/// Reads worktree state from real git. Judging happens elsewhere.
public struct GitWorktrees: Sendable {
    public typealias Run = @Sendable (String, [String], Duration) async -> CommandResult
    private let run: Run
    private static let git = "/usr/bin/git"
    private static let timeout: Duration = .seconds(10)

    public init(run: Run? = nil) {
        self.run = run ?? { await CommandRunner.run($0, $1, timeout: $2) }
    }

    private func git(_ dir: String, _ args: [String], literal: Bool = false) async -> CommandResult {
        await run(Self.git, (literal ? ["--literal-pathspecs"] : []) + ["-C", dir] + args, Self.timeout)
    }

    /// Whether git can run at all (the Xcode command line tools are installed).
    public func available() async -> Bool {
        let tools = await run("/usr/bin/xcode-select", ["-p"], Self.timeout)
        guard tools.status == 0 else { return false }
        return await run(Self.git, ["--version"], Self.timeout).status == 0
    }

    /// Linked worktrees of `repo`, without the main checkout; nil when git failed.
    public func list(repo: String) async -> [GitWorktreeEntry]? {
        let r = await git(repo, ["worktree", "list", "--porcelain"])
        guard r.status == 0, !r.timedOut else { return nil }
        return Array(Self.parsePorcelain(r.stdout).dropFirst())
    }

    public static func parsePorcelain(_ out: String) -> [GitWorktreeEntry] {
        var entries: [GitWorktreeEntry] = []
        var current: GitWorktreeEntry?
        func flush() {
            if let c = current { entries.append(c) }
            current = nil
        }
        for line in out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty { flush(); continue }
            if line.hasPrefix("worktree ") {
                flush()
                current = GitWorktreeEntry(path: String(line.dropFirst(9)), head: "", branch: nil, locked: false, prunable: false)
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst(5))
            } else if line.hasPrefix("branch ") {
                let ref = String(line.dropFirst(7))
                current?.branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : ref
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.locked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.prunable = true
            }
        }
        flush()
        return entries
    }

    public func facts(
        _ e: GitWorktreeEntry, repo: String, processes: [Int32: ProcessInfoRecord], ownPID: Int32, lastChange: Date?
    ) async -> WorktreeFacts {
        // Process cwds are resolved real paths; git may report the worktree through a symlink.
        let roots = Set([e.path, realpath(e.path, nil).map { String(cString: $0) } ?? e.path])
        let inside = Array(Set(processes.values.compactMap { p -> String? in
            guard p.pid != ownPID, let cwd = p.cwd,
                  roots.contains(where: { cwd == $0 || cwd.hasPrefix($0 + "/") }) else { return nil }
            return p.name
        })).sorted()
        let agent = WorktreeAgent.label(path: e.path, branch: e.branch)

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo, isDirectory: &isDir), isDir.boolValue else {
            return WorktreeFacts(
                path: e.path, repo: repo, branch: e.branch, agent: agent, uncommitted: nil, merge: .unknown,
                locked: e.locked, processesInside: inside, lastChange: lastChange, lastCommit: nil, repoExists: false)
        }

        var uncommitted: Int?
        let status = await git(e.path, ["status", "--porcelain", "--untracked-files=normal"])
        if status.status == 0, !status.timedOut {
            uncommitted = status.stdout.split(separator: "\n").count
        }

        var lastCommit: Date?
        let log = await git(e.path, ["log", "-1", "--format=%ct"])
        if log.status == 0, let t = TimeInterval(log.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            lastCommit = Date(timeIntervalSince1970: t)
        }

        return WorktreeFacts(
            path: e.path, repo: repo, branch: e.branch, agent: agent, uncommitted: uncommitted,
            merge: await mergeState(at: e.path), locked: e.locked, processesInside: inside,
            lastChange: lastChange, lastCommit: lastCommit, repoExists: true)
    }

    private func mergeState(at dir: String) async -> MergeState {
        var refs: [String] = []
        for ref in ["main", "master", "origin/HEAD", "origin/main", "origin/master"] {
            let r = await git(dir, ["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])
            if r.status == 0 { refs.append(ref) }
        }
        guard let first = refs.first else { return .unknown }

        for ref in refs where await git(dir, ["merge-base", "--is-ancestor", "HEAD", ref]).status == 0 {
            return .ancestor
        }

        for ref in refs {
            let mb = await git(dir, ["merge-base", ref, "HEAD"])
            guard mb.status == 0 else { continue }
            let base = mb.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let diff = await git(dir, ["diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", base, "HEAD"], literal: true)
            guard diff.status == 0, !diff.timedOut else { continue }
            let files = diff.stdout.split(separator: "\0").map(String.init)
            if files.isEmpty { return .ancestor }
            if await git(dir, ["diff", "--quiet", "--no-ext-diff", ref, "HEAD", "--"] + files, literal: true).status == 0 { return .squash }
        }

        let count = await git(dir, ["rev-list", "--count", "\(first)..HEAD"])
        let ahead = Int(count.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let name = first.hasPrefix("origin/") ? String(first.dropFirst(7)) : first
        return .notMerged(commitsAhead: ahead, base: name)
    }
}
