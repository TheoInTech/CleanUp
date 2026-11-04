import Foundation

/// Whether a worktree's branch has landed in the repository's base branch.
public enum MergeState: Sendable, Equatable {
    /// The branch tip is an ancestor of the base branch.
    case ancestor
    /// The branch's changes are on the base branch as a squash or rebase merge.
    case squash
    case notMerged(commitsAhead: Int, base: String)
    case unknown
}

/// Everything the judge needs to know about one git worktree.
public struct WorktreeFacts: Sendable, Equatable {
    public var path: String
    public var repo: String
    public var branch: String?
    public var agent: String?
    /// Modified or untracked files git sees; nil when git could not say.
    public var uncommitted: Int?
    public var merge: MergeState
    public var locked: Bool
    /// Names of processes whose working directory is inside the worktree.
    public var processesInside: [String]
    /// Most recent file modification inside the worktree; nil while not yet measured.
    public var lastChange: Date?
    public var lastCommit: Date?
    public var repoExists: Bool

    public init(
        path: String, repo: String, branch: String?, agent: String?, uncommitted: Int?, merge: MergeState,
        locked: Bool, processesInside: [String], lastChange: Date?, lastCommit: Date?, repoExists: Bool
    ) {
        self.path = path
        self.repo = repo
        self.branch = branch
        self.agent = agent
        self.uncommitted = uncommitted
        self.merge = merge
        self.locked = locked
        self.processesInside = processesInside
        self.lastChange = lastChange
        self.lastCommit = lastCommit
        self.repoExists = repoExists
    }
}

/// Decides whether a worktree is safe to remove. Pure: everything it needs is in the facts.
/// `.idle` means safe to remove, `.inUse` means kept.
public enum WorktreeJudge {
    /// A worktree touched more recently than this is treated as being worked in.
    public static let recentChange: TimeInterval = 3600

    public static func judge(_ f: WorktreeFacts, now: Date) -> Judgement {
        var signals: [Signal] = []
        var reasons: [String] = []

        func check(_ passes: Bool, pass: String, fail: String, reason: String) {
            signals.append(Signal(kind: passes ? .idle : .inUse, text: passes ? pass : fail))
            if !passes { reasons.append(reason) }
        }

        check(f.repoExists, pass: "The repository is there", fail: "The repository is missing, so nothing can be checked",
              reason: "can't check: repository missing")

        switch f.uncommitted {
        case 0?:
            signals.append(Signal(kind: .idle, text: "No uncommitted changes"))
        case let n?:
            let text = "\(n) uncommitted change\(n == 1 ? "" : "s")"
            signals.append(Signal(kind: .inUse, text: text))
            reasons.append(text)
        case nil:
            signals.append(Signal(kind: .inUse, text: "Git could not say whether there are uncommitted changes"))
            reasons.append("can't check for uncommitted changes")
        }

        var mergeUnknown = false
        switch f.merge {
        case .ancestor:
            signals.append(Signal(kind: .idle, text: "Its commits are on the base branch"))
        case .squash:
            signals.append(Signal(kind: .idle, text: "Its changes were squash-merged into the base branch"))
        case let .notMerged(ahead, base):
            let text = "\(ahead) commit\(ahead == 1 ? "" : "s") not on \(base)"
            signals.append(Signal(kind: .inUse, text: text))
            reasons.append(text)
        case .unknown:
            signals.append(Signal(kind: .inUse, text: "Can't tell if its commits are merged"))
            mergeUnknown = true
        }

        if !f.processesInside.isEmpty {
            let names = f.processesInside.joined(separator: ", ")
            signals.append(Signal(kind: .inUse, text: "A process is running inside it: \(names)"))
            reasons.append("in use by \(names)")
        } else {
            signals.append(Signal(kind: .idle, text: "Nothing is running inside it"))
        }

        check(!f.locked, pass: "Not locked", fail: "Locked with git worktree lock", reason: "locked")

        if let lastChange = f.lastChange {
            let age = now.timeIntervalSince(lastChange)
            if age < recentChange {
                let text = "changed \(RelativeAge.short(age)) ago"
                signals.append(Signal(kind: .inUse, text: "Files changed \(RelativeAge.short(age)) ago"))
                reasons.append(text)
            } else {
                signals.append(Signal(kind: .idle, text: "No file changes for \(RelativeAge.short(age))"))
            }
        } else {
            signals.append(Signal(kind: .inUse, text: "Still measuring when it last changed"))
            reasons.append("measuring…")
        }

        if mergeUnknown { reasons.append("can't tell if it's merged") }

        if let reason = reasons.first {
            return Judgement(verdict: .inUse, fact: reason, signals: signals)
        }
        var fact = "merged"
        if let lastCommit = f.lastCommit { fact += " \(RelativeAge.short(now.timeIntervalSince(lastCommit))) ago" }
        if let agent = f.agent { fact += " · \(agent)" }
        return Judgement(verdict: .idle, fact: fact, signals: signals)
    }
}

/// Which AI tool made a worktree, from where it lives or what its branch is called.
public enum WorktreeAgent {
    public static func label(path: String, branch: String?) -> String? {
        let lower = path.lowercased()
        if lower.contains("/.codex/") { return "Codex" }
        if lower.contains("/.cursor/") { return "Cursor" }
        if lower.contains("/.claude/worktrees/") || lower.contains("/.claude-worktrees/") { return "Claude Code" }
        if lower.contains("/conductor/") { return "Conductor" }
        if lower.contains("antigravity") { return "Antigravity" }
        if lower.contains("/.worktrees/") { return "VS Code" }
        let prefixes: [(String, String)] = [
            ("codex/", "Codex"), ("claude/", "Claude Code"), ("cursor/", "Cursor"), ("copilot/", "Copilot"),
        ]
        if let branch { return prefixes.first { branch.hasPrefix($0.0) }?.1 }
        return nil
    }
}

public enum Bytes {
    /// "208.3 GB", or "<0.1 GB" for anything under 0.1 GB.
    public static func gb(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_000_000_000
        if value < 0.1 { return "<0.1 GB" }
        return String(format: "%.1f GB", value)
    }
}
