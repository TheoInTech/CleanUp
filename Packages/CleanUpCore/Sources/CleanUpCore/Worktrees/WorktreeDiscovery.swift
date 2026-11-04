import Foundation

/// Finds the git repositories on this Mac that own linked worktrees, by walking the home folder
/// for `.git` files (a linked worktree's `.git` is a file, a repository's is a folder).
public enum WorktreeDiscovery {
    /// Deepest level, counted from home (a direct child is level 1), at which a `.git` marker is looked for.
    static let maxDepth = 7
    /// Folder names never entered; names ending `.photoslibrary` are skipped too.
    static let skipped: Set<String> = ["node_modules", ".Trash", "DerivedData", ".build", "Pods", "Library"]
    /// Folders (relative to home) that trigger a permission prompt; entered only when asked.
    static let protected: [String] = ["Documents", "Desktop", "Downloads", "Library/Mobile Documents"]
    /// Where coding agents park worktrees (relative to home).
    static let agentRoots: [String] = [".codex/worktrees", ".cursor/worktrees", "conductor/workspaces"]

    private static let agentDepth = 4

    static func isSkipped(_ name: String) -> Bool {
        skipped.contains(name) || name.hasSuffix(".photoslibrary")
    }

    // MARK: Reading a worktree's .git file

    /// The absolute, resolved path in a `gitdir: <path>` file; nil when the file is not one.
    public static func gitDir(fromGitFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count < 4096,
              let text = String(data: data, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("gitdir:") else { return nil }
        let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw).standardized.path }
        return URL(fileURLWithPath: raw, relativeTo: url.deletingLastPathComponent()).standardized.path
    }

    /// The main repository a linked worktree's `.git` file points at; nil for submodules and anything else.
    public static func repo(fromGitFile url: URL) -> String? {
        guard let dir = gitDir(fromGitFile: url), let r = dir.range(of: "/.git/worktrees/") else { return nil }
        let repo = String(dir[..<r.lowerBound])
        return repo.isEmpty ? nil : repo
    }

    // MARK: Walks

    /// Main repositories (sorted, unique) that own at least one linked worktree.
    public static func repositories(home: URL, includeProtected: Bool) -> [String] {
        var found = Set<String>()
        let protectedSet = Set(protected)

        walk(root: home, maxLevel: maxDepth) { level, url, name in
            guard level <= 2, name != ".git" else { return !isSkipped(name) }
            if isSkipped(name) { return false }
            if !includeProtected {
                let rel = level == 1 ? name : url.deletingLastPathComponent().lastPathComponent + "/" + name
                if protectedSet.contains(rel) { return false }
            }
            return true
        } marker: { found.insert($0) }

        for root in agentRoots {
            let url = home.appendingPathComponent(root)
            walk(root: url, maxLevel: agentDepth) { _, _, name in !isSkipped(name) } marker: { found.insert($0) }
        }
        return found.sorted()
    }

    /// Enumerates below `root` without following links. `enter` decides whether a folder is descended into.
    /// `marker` receives the main repo of each linked-worktree `.git` file.
    private static func walk(
        root: URL, maxLevel: Int,
        enter: (_ level: Int, _ url: URL, _ name: String) -> Bool,
        marker: (String) -> Void
    ) {
        let fm = FileManager.default
        guard let e = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants], errorHandler: { _, _ in true }
        ) else { return }
        while let item = e.nextObject() as? URL {
            let name = item.lastPathComponent
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if name == ".git" {
                if values?.isRegularFile == true, let repo = repo(fromGitFile: item) { marker(repo) }
                if values?.isDirectory == true { e.skipDescendants() }
                continue
            }
            guard values?.isDirectory == true else { continue }
            let level = e.level
            if level >= maxLevel || !enter(level, item, name) { e.skipDescendants() }
        }
    }

    // MARK: Leftover agent folders

    /// Direct children of the Codex and Cursor worktree roots with no `.git` within 3 levels and under 1 MB.
    public static func leftoverAgentFolders(home: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in [".codex/worktrees", ".cursor/worktrees"] {
            let url = home.appendingPathComponent(root)
            guard let kids = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey], options: []
            ) else { continue }
            for kid in kids where (try? kid.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                if hasGit(kid, depth: 3) { continue }
                if allocatedBytes(kid, limit: 1_000_000) >= 1_000_000 { continue }
                out.append(kid)
            }
        }
        return out
    }

    private static func hasGit(_ folder: URL, depth: Int) -> Bool {
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [], errorHandler: { _, _ in true }
        ) else { return false }
        while let item = e.nextObject() as? URL {
            if item.lastPathComponent == ".git" { return true }
            if e.level >= depth { e.skipDescendants() }
        }
        return false
    }

    /// Allocated bytes under `folder`, stopping early once `limit` is reached.
    private static func allocatedBytes(_ folder: URL, limit: Int) -> Int {
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total = 0
        while let item = e.nextObject() as? URL {
            total += (try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0
            if total >= limit { break }
        }
        return total
    }
}
