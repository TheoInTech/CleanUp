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
            if crossesSymlink(home: home, relative: root) { continue }
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

    /// True when `relative` (below home) or any of its parent components is a symbolic link, or cannot be read.
    static func crossesSymlink(home: URL, relative: String) -> Bool {
        var url = home
        for part in relative.split(separator: "/") {
            url = url.appendingPathComponent(String(part))
            guard let v = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else { return true }
            if v.isSymbolicLink == true { return true }
        }
        return false
    }

    /// Files an agent leaves in an otherwise empty worktree folder.
    static let markerFiles: Set<String> = [".codex-worktree-name"]
    /// A folder with more entries than this is not a leftover.
    static let leftoverWalkCap = 200

    /// Direct children of the Codex and Cursor worktree roots that hold nothing but folders, `.DS_Store`
    /// and the agent's marker files. Fails safe: anything else (any other file, a symlink, a `.git`, an
    /// unreadable entry, or more than `leftoverWalkCap` entries) means the folder is not listed.
    public static func leftoverAgentFolders(home: URL) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for root in [".codex/worktrees", ".cursor/worktrees"] {
            if crossesSymlink(home: home, relative: root) { continue }
            let url = home.appendingPathComponent(root)
            guard let kids = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []
            ) else { continue }
            for kid in kids {
                guard let v = try? kid.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      v.isDirectory == true, v.isSymbolicLink != true else { continue }
                if holdsOnlyMarkers(kid) { out.append(kid) }
            }
        }
        return out
    }

    private static func holdsOnlyMarkers(_ folder: URL) -> Bool {
        var failed = false
        guard let e = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [],
            errorHandler: { _, _ in failed = true; return false }
        ) else { return false }
        var count = 0
        while let item = e.nextObject() as? URL {
            count += 1
            if count > leftoverWalkCap { return false }
            guard let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
            if v.isSymbolicLink != false { return false }
            let name = item.lastPathComponent
            if v.isDirectory == true {
                if name == ".git" { return false }
            } else if name != ".DS_Store" && !markerFiles.contains(name) {
                return false
            }
        }
        return !failed
    }
}
