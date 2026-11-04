import Foundation

/// Moves worktrees to the Trash (with git's record of them set aside so git forgets them), puts them back,
/// and removes them for good. Records what it trashed in `<store>/trashed-worktrees.json`.
public actor WorktreeTrash {
    public typealias Recheck = @Sendable (Item) async -> Judgement

    struct TrashError: LocalizedError {
        var errorDescription: String? { "The Trash didn't say where the folder went" }
    }

    public static let defaultTrashItem: @Sendable (URL) throws -> URL = { url in
        var out: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &out)
        guard let result = out else { throw TrashError() }
        return result as URL
    }

    private let store: URL
    private let git: GitWorktrees
    private let trashItem: @Sendable (URL) throws -> URL
    public private(set) var entries: [TrashedWorktree]

    private var recordURL: URL { store.appendingPathComponent("trashed-worktrees.json") }
    private var adminRoot: URL { store.appendingPathComponent("admin", isDirectory: true) }

    public init(
        store: URL, git: GitWorktrees = .init(),
        trashItem: @escaping @Sendable (URL) throws -> URL = WorktreeTrash.defaultTrashItem
    ) {
        self.store = store
        self.git = git
        self.trashItem = trashItem
        let data = try? Data(contentsOf: store.appendingPathComponent("trashed-worktrees.json"))
        self.entries = data.flatMap { try? JSONDecoder().decode([TrashedWorktree].self, from: $0) } ?? []
    }

    // MARK: Move to the Trash

    public func moveToTrash(_ items: [Item], recheck: Recheck) async -> WorktreeOutcome {
        var moved: [Item] = [], skipped: [(Item, String)] = [], bytes: Int64 = 0
        for item in items {
            let result = item.id == .worktreeLeftovers
                ? await trashLeftovers(item, recheck: recheck)
                : await trashWorktree(item, recheck: recheck)
            switch result {
            case .success: moved.append(item); bytes += Self.bytes(item)
            case .failure(let why): skipped.append((item, why.reason))
            }
        }
        return WorktreeOutcome(moved: moved, skipped: skipped, bytes: bytes, permanent: false)
    }

    private struct Skip: Error { var reason: String }

    private func trashWorktree(_ item: Item, recheck: Recheck) async -> Result<Void, Skip> {
        guard let path = item.detail["path"] else { return .failure(Skip(reason: "folder is missing")) }
        if let why = await folderProblem(path, item: item, recheck: recheck) { return .failure(Skip(reason: why)) }
        guard let repo = item.detail["repo"],
              let adminPath = Self.adminFolder(ofWorktree: path, repo: repo) else {
            return .failure(Skip(reason: "can't find git's record"))
        }

        let fm = FileManager.default
        let id = UUID()
        let stored = adminRoot.appendingPathComponent(id.uuidString)
        do {
            try fm.createDirectory(at: adminRoot, withIntermediateDirectories: true)
            try fm.moveItem(atPath: adminPath, toPath: stored.path)
        } catch {
            return .failure(Skip(reason: error.localizedDescription))
        }
        let trashURL: URL
        do {
            trashURL = try trashItem(URL(fileURLWithPath: path))
        } catch {
            do {
                try fm.moveItem(atPath: stored.path, toPath: adminPath)
            } catch {
                return .failure(Skip(reason: "couldn't restore git's record (it is in \(stored.path)): " + error.localizedDescription))
            }
            return .failure(Skip(reason: error.localizedDescription))
        }
        entries.append(TrashedWorktree(
            id: id, path: path, repo: repo, storedAdmin: stored.path, trashURL: trashURL.path,
            bytes: Self.bytes(item), date: Date()))
        save()
        return .success(())
    }

    private func trashLeftovers(_ item: Item, recheck: Recheck) async -> Result<Void, Skip> {
        let judgement = await recheck(item)
        guard judgement.verdict == .idle else { return .failure(Skip(reason: judgement.fact)) }
        let paths = (item.detail["paths"] ?? "").split(separator: "\n").map(String.init)
        guard !paths.isEmpty else { return .failure(Skip(reason: "folder is missing")) }
        var problems: [String] = []
        for path in paths {
            switch Self.kind(path) {
            case .missing: continue
            case .link: problems.append("folder is a link"); continue
            case .other: problems.append("folder is missing"); continue
            case .folder: break
            }
            do {
                let url = try trashItem(URL(fileURLWithPath: path))
                entries.append(TrashedWorktree(
                    id: UUID(), path: path, repo: nil, storedAdmin: nil, trashURL: url.path,
                    bytes: FolderSize.measure(url).bytes, date: Date()))
                save()
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if let first = problems.first { return .failure(Skip(reason: first)) }
        return .success(())
    }

    // MARK: Permanent removal

    public func removePermanently(_ items: [Item], recheck: Recheck) async -> WorktreeOutcome {
        var moved: [Item] = [], skipped: [(Item, String)] = [], bytes: Int64 = 0
        for item in items {
            let result = item.id == .worktreeLeftovers
                ? await removeLeftovers(item, recheck: recheck)
                : await removeWorktree(item, recheck: recheck)
            switch result {
            case .success: moved.append(item); bytes += Self.bytes(item)
            case .failure(let why): skipped.append((item, why.reason))
            }
        }
        return WorktreeOutcome(moved: moved, skipped: skipped, bytes: bytes, permanent: true)
    }

    private func removeWorktree(_ item: Item, recheck: Recheck) async -> Result<Void, Skip> {
        guard let path = item.detail["path"] else { return .failure(Skip(reason: "folder is missing")) }
        if let why = await folderProblem(path, item: item, recheck: recheck) { return .failure(Skip(reason: why)) }
        guard let repo = item.detail["repo"] else { return .failure(Skip(reason: "can't find git's record")) }
        // Never `--force`: git itself refuses a worktree with changes, and we report why.
        let r = await git.removeWorktree(repo: repo, path: path)
        if r.status == 0, !r.timedOut { return .success(()) }
        if r.timedOut { return .failure(Skip(reason: "git took too long")) }
        let line = r.stderr.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        return .failure(Skip(reason: line.flatMap { $0.isEmpty ? nil : $0 } ?? "git couldn't remove it"))
    }

    private func removeLeftovers(_ item: Item, recheck: Recheck) async -> Result<Void, Skip> {
        let judgement = await recheck(item)
        guard judgement.verdict == .idle else { return .failure(Skip(reason: judgement.fact)) }
        let paths = (item.detail["paths"] ?? "").split(separator: "\n").map(String.init)
        guard !paths.isEmpty else { return .failure(Skip(reason: "folder is missing")) }
        var problems: [String] = []
        for path in paths {
            switch Self.kind(path) {
            case .missing: continue
            case .link: problems.append("folder is a link"); continue
            case .other: problems.append("folder is missing"); continue
            case .folder: break
            }
            do { try FileManager.default.removeItem(atPath: path) } catch { problems.append(error.localizedDescription) }
        }
        if let first = problems.first { return .failure(Skip(reason: first)) }
        return .success(())
    }

    // MARK: Put back

    /// Returns the ids that could not be put back; their entries stay.
    public func putBack(_ ids: [UUID]) async -> [UUID] {
        var failed: [UUID] = []
        for id in ids {
            guard let entry = entries.first(where: { $0.id == id }), await restore(entry) else {
                failed.append(id)
                continue
            }
            entries.removeAll { $0.id == id }
            save()
        }
        return failed
    }

    private func restore(_ e: TrashedWorktree) async -> Bool {
        let fm = FileManager.default
        guard Self.kind(e.trashURL) != .missing, Self.kind(e.path) == .missing else { return false }
        let parent = URL(fileURLWithPath: e.path).deletingLastPathComponent()

        guard let repo = e.repo, let stored = e.storedAdmin else {
            // A leftover folder: no git record.
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
                try fm.moveItem(atPath: e.trashURL, toPath: e.path)
                return true
            } catch { return false }
        }
        guard Self.isDirectory(repo), Self.isDirectory(stored),
              let dest = Self.adminDestination(gitFile: e.trashURL + "/.git", repo: repo),
              Self.kind(dest) == .missing else { return false }
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.moveItem(atPath: e.trashURL, toPath: e.path)
        } catch { return false }
        do {
            try fm.moveItem(atPath: stored, toPath: dest)
        } catch {
            try? fm.moveItem(atPath: e.path, toPath: e.trashURL)
            return false
        }
        _ = await git.repairWorktree(repo: repo, path: e.path)
        return true
    }

    // MARK: Delete now

    public func deleteNow(_ ids: [UUID]) async {
        let fm = FileManager.default
        for id in ids {
            guard let e = entries.first(where: { $0.id == id }) else { continue }
            do {
                // Only the exact recorded Trash entry, and only if it is still there.
                if Self.kind(e.trashURL) != .missing { try fm.removeItem(atPath: e.trashURL) }
                if let admin = e.storedAdmin { try removeStoredAdmin(admin) }
            } catch {
                continue
            }
            entries.removeAll { $0.id == id }
            save()
        }
    }

    private func removeStoredAdmin(_ path: String) throws {
        guard path.hasPrefix(adminRoot.path + "/"), Self.kind(path) != .missing else { return }
        try FileManager.default.removeItem(atPath: path)
    }

    // MARK: Reconcile

    /// Catches up with what happened in Finder: items emptied from the Trash, or moved back by hand.
    public func reconcile() async {
        for e in entries {
            guard Self.kind(e.trashURL) == .missing else { continue }
            if let repo = e.repo, let stored = e.storedAdmin, Self.isDirectory(e.path), Self.isDirectory(repo),
               let dest = Self.adminDestination(gitFile: e.path + "/.git", repo: repo),
               Self.kind(dest) == .missing, Self.isDirectory(stored) {
                do { try FileManager.default.moveItem(atPath: stored, toPath: dest) } catch { continue }
                _ = await git.repairWorktree(repo: repo, path: e.path)
            } else if let stored = e.storedAdmin {
                do { try removeStoredAdmin(stored) } catch { continue }
            }
            entries.removeAll { $0.id == e.id }
            save()
        }
    }

    // MARK: Helpers

    private func folderProblem(_ path: String, item: Item, recheck: Recheck) async -> String? {
        switch Self.kind(path) {
        case .missing, .other: return "folder is missing"
        case .link: return "folder is a link"
        case .folder: break
        }
        let judgement = await recheck(item)
        return judgement.verdict == .idle ? nil : judgement.fact
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: recordURL, options: .atomic)
        } catch {}
    }

    private static func bytes(_ item: Item) -> Int64 { item.detail["bytes"].flatMap { Int64($0) } ?? 0 }

    private enum Kind { case missing, link, folder, other }

    private static func kind(_ path: String) -> Kind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .folder
        default: return .other
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func real(_ path: String) -> String? { realpath(path, nil).map { String(cString: $0) } }

    /// Git's record folder for the worktree at `path`, only if it really is a folder inside `<repo>/.git/worktrees/`.
    static func adminFolder(ofWorktree path: String, repo: String) -> String? {
        guard let dir = WorktreeDiscovery.gitDir(fromGitFile: URL(fileURLWithPath: path + "/.git")),
              let resolved = real(dir), isDirectory(resolved), let root = real(repo + "/.git/worktrees"),
              resolved.hasPrefix(root + "/"), resolved.count > root.count + 1 else { return nil }
        // The resolved folder, so a link inside `.git/worktrees` is never what gets moved.
        return resolved
    }

    /// Where the record folder named by `gitFile` belongs: directly inside `<repo>/.git/worktrees/`.
    static func adminDestination(gitFile: String, repo: String) -> String? {
        guard let dir = WorktreeDiscovery.gitDir(fromGitFile: URL(fileURLWithPath: gitFile)),
              let root = real(repo + "/.git/worktrees"),
              let parent = real(URL(fileURLWithPath: dir).deletingLastPathComponent().path), parent == root else { return nil }
        let name = URL(fileURLWithPath: dir).lastPathComponent
        return name.isEmpty || name == "." || name == ".." ? nil : root + "/" + name
    }
}
