import Foundation

/// How many worktrees, said the way the button, the dialog, the result and the Trash row say it.
/// Leftover agent folders are not worktrees, so they are named on their own: "3 worktrees and leftover
/// folders", or just "leftover folders".
public enum WorktreeCount {
    public static func phrase(worktrees: Int, leftovers: Bool) -> String {
        let count = worktrees == 1 ? "1 worktree" : "\(worktrees) worktrees"
        guard leftovers else { return count }
        return worktrees == 0 ? "leftover folders" : "\(count) and leftover folders"
    }

    /// Items from a scan; the leftovers item is the folders.
    public static func phrase(_ items: [Item]) -> String {
        let leftovers = items.contains { $0.id == .worktreeLeftovers }
        return phrase(worktrees: items.count - (leftovers ? 1 : 0), leftovers: leftovers)
    }

    /// Trash records; one without a repository is a leftover folder.
    public static func phrase(_ trashed: [TrashedWorktree]) -> String {
        let leftovers = trashed.filter { $0.repo == nil }.count
        return phrase(worktrees: trashed.count - leftovers, leftovers: leftovers > 0)
    }
}

public enum WorktreeStorageCaption {
    /// "14.2 GB safe to remove · 8.2 GB kept · 3.1 GB in the Trash". A part that is zero is left out
    /// ("0 GB" for safe, which always shows), never "<0.1 GB".
    public static func text(safe: Int64, kept: Int64, trashed: Int64) -> String {
        var parts = ["\(safe > 0 ? Bytes.gb(safe) : "0 GB") safe to remove"]
        if kept > 0 { parts.append("\(Bytes.gb(kept)) kept") }
        if trashed > 0 { parts.append("\(Bytes.gb(trashed)) in the Trash") }
        return parts.joined(separator: " · ")
    }
}
