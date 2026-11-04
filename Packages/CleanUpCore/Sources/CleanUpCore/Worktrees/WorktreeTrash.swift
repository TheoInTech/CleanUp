import Foundation
import os

/// Moves worktrees to the Trash (with git's record of them set aside so git forgets them), puts them back,
/// and removes them for good. Records what it trashed in `<store>/trashed-worktrees.json`.
///
/// Create one `WorktreeTrash` per store: two instances on the same store would overwrite each other's record.
public actor WorktreeTrash {
    public typealias Recheck = @Sendable (Item) async -> Judgement

    struct TrashError: LocalizedError {
        var errorDescription: String? { "The Trash didn't say where the folder went" }
    }

    private static let log = Logger(subsystem: "io.cleanup.CleanUp", category: "worktrees")
    static let tookTooLong = "git took too long; the folder may be partly removed"

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
        let identity = Self.identity(trashURL.path)
        entries.append(TrashedWorktree(
            id: id, path: path, repo: repo, storedAdmin: stored.path, trashURL: trashURL.path,
            bytes: Self.bytes(item), date: Date(), fileID: identity?.0, device: identity?.1))
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
            if let why = Self.leftoverProblem(path) {
                if why != "gone" { problems.append(why) }
                continue
            }
            do {
                let url = try trashItem(URL(fileURLWithPath: path))
                let identity = Self.identity(url.path)
                entries.append(TrashedWorktree(
                    id: UUID(), path: path, repo: nil, storedAdmin: nil, trashURL: url.path,
                    bytes: FolderSize.measure(url).bytes, date: Date(), fileID: identity?.0, device: identity?.1))
                save()
            } catch {
                problems.append(error.localizedDescription)
            }
        }
        if let first = problems.first { return .failure(Skip(reason: first)) }
        return .success(())
    }

    /// nil when the folder may be touched; "gone" when it no longer exists.
    private static func leftoverProblem(_ path: String) -> String? {
        switch kind(path) {
        case .missing: return "gone"
        case .link: return "folder is a link"
        case .other: return "folder is missing"
        case .unknown: return "folder can't be checked"
        case .folder: return nil
        }
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
        if r.timedOut { return .failure(Skip(reason: Self.tookTooLong)) }
        if r.status == 0 { return .success(()) }
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
            if let why = Self.leftoverProblem(path) {
                if why != "gone" { problems.append(why) }
                continue
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
        guard Self.isStillTheTrashedItem(e), Self.kind(e.path) == .missing else { return false }
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
        await repair(repo: repo, path: e.path)
        return true
    }

    private func repair(repo: String, path: String) async {
        let r = await git.repairWorktree(repo: repo, path: path)
        if r.status != 0 || r.timedOut {
            Self.log.error("git worktree repair failed for \(path, privacy: .public): \(r.stderr, privacy: .public)")
        }
    }

    // MARK: Delete now

    public func deleteNow(_ ids: [UUID]) async {
        let fm = FileManager.default
        for id in ids {
            guard let e = entries.first(where: { $0.id == id }) else { continue }
            switch Self.kind(e.trashURL) {
            case .unknown:
                continue
            case .missing:
                // Already gone, unless the Trash itself is out of reach (an unplugged volume); and git's
                // record may only go when the folder is gone from its path too.
                guard Self.trashFolderIsReachable(e) else { continue }
                if e.storedAdmin != nil, Self.kind(e.path) != .missing { continue }
            default:
                // Only the exact recorded Trash entry, and only if it is still the item we trashed.
                guard Self.isStillTheTrashedItem(e) else { continue }
                do { try fm.removeItem(atPath: e.trashURL) } catch { continue }
            }
            if let admin = e.storedAdmin {
                do { try removeStoredAdmin(admin) } catch { continue }
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

    /// Catches up with what happened outside CleanUp: items emptied from the Trash or moved back by hand,
    /// and git records left in the store by an interrupted move. Never deletes anything it can't be sure of.
    public func reconcile() async {
        for e in entries {
            // Only a definite "no such file" means gone; any other error means unknown, so touch nothing.
            guard Self.kind(e.trashURL) == .missing, Self.trashFolderIsReachable(e) else { continue }
            switch Self.kind(e.path) {
            case .missing:
                if let stored = e.storedAdmin {
                    do { try removeStoredAdmin(stored) } catch { continue }
                }
            case .unknown:
                continue
            default:
                guard let repo = e.repo, let stored = e.storedAdmin else { break }  // a leftover moved back by hand
                guard Self.kind(e.path) == .folder, Self.isDirectory(repo), Self.kind(stored) == .folder,
                      let dest = Self.adminDestination(gitFile: e.path + "/.git", repo: repo),
                      Self.kind(dest) == .missing else { continue }
                do { try FileManager.default.moveItem(atPath: stored, toPath: dest) } catch { continue }
                await repair(repo: repo, path: e.path)
            }
            entries.removeAll { $0.id == e.id }
            save()
        }
        await recoverOrphans()
    }

    /// Git records in `<store>/admin` that no entry owns (a crash between the two moves): put each back
    /// if its worktree folder is still in place. Never deletes one.
    private func recoverOrphans() async {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: adminRoot.path)) ?? []
        let owned = Set(entries.map { $0.id.uuidString })
        for name in names where !owned.contains(name) && UUID(uuidString: name) != nil {
            let stored = adminRoot.appendingPathComponent(name).path
            guard Self.isDirectory(stored),
                  let gitdirText = Self.firstLine(stored + "/gitdir"), gitdirText.hasSuffix("/.git"),
                  let commonText = Self.firstLine(stored + "/commondir") else { continue }
            let wt = String(gitdirText.dropLast(5))
            guard Self.kind(wt) == .folder,
                  let original = WorktreeDiscovery.gitDir(fromGitFile: URL(fileURLWithPath: wt + "/.git")) else { continue }
            let common = (commonText.hasPrefix("/")
                ? URL(fileURLWithPath: commonText)
                : URL(fileURLWithPath: commonText, relativeTo: URL(fileURLWithPath: original, isDirectory: true))).standardized.path
            guard common.hasSuffix("/.git") else { continue }
            let repo = String(common.dropLast(5))
            guard Self.isDirectory(repo),
                  let dest = Self.adminDestination(gitFile: wt + "/.git", repo: repo),
                  Self.kind(dest) == .missing else { continue }
            do { try FileManager.default.moveItem(atPath: stored, toPath: dest) } catch { continue }
            await repair(repo: repo, path: wt)
        }
    }

    // MARK: Helpers

    /// Checks the folder, re-checks the judgement, then checks the folder again right before anything moves.
    private func folderProblem(_ path: String, item: Item, recheck: Recheck) async -> String? {
        if let why = Self.folderProblem(path) { return why }
        let judgement = await recheck(item)
        guard judgement.verdict == .idle else { return judgement.fact }
        return Self.folderProblem(path)
    }

    private static func folderProblem(_ path: String) -> String? {
        switch kind(path) {
        case .missing, .other: return "folder is missing"
        case .link: return "folder is a link"
        case .unknown: return "folder can't be checked"
        case .folder: return nil
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: recordURL, options: .atomic)
        } catch {
            Self.log.error("couldn't save the trashed worktrees record: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func bytes(_ item: Item) -> Int64 { item.detail["bytes"].flatMap { Int64($0) } ?? 0 }

    private enum Kind { case missing, link, folder, other, unknown }

    /// `.missing` only when lstat says ENOENT; any other failure is `.unknown`.
    private static func kind(_ path: String) -> Kind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return errno == ENOENT ? .missing : .unknown }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return .link
        case S_IFDIR: return .folder
        default: return .other
        }
    }

    /// An item missing from the Trash only counts as gone when the folder that held it is a real, readable
    /// directory; otherwise the Trash (or its volume) may simply be unreachable.
    private static func trashFolderIsReachable(_ e: TrashedWorktree) -> Bool {
        let parent = URL(fileURLWithPath: e.trashURL).deletingLastPathComponent().path
        return kind(parent) == .folder && access(parent, R_OK | X_OK) == 0
    }

    private static func identity(_ path: String) -> (UInt64, Int64)? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return (UInt64(st.st_ino), Int64(st.st_dev))
    }

    /// The item at `trashURL` exists and, when the record has an identity, is the very item we trashed.
    private static func isStillTheTrashedItem(_ e: TrashedWorktree) -> Bool {
        switch kind(e.trashURL) {
        case .missing, .unknown: return false
        default: break
        }
        guard let id = e.fileID, let dev = e.device else {
            log.error("no recorded identity for the Trash item at \(e.trashURL, privacy: .public); leaving it alone")
            return false
        }
        guard let now = identity(e.trashURL) else { return false }
        return now.0 == id && now.1 == dev
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func real(_ path: String) -> String? { realpath(path, nil).map { String(cString: $0) } }

    private static func firstLine(_ path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
        return line?.isEmpty == false ? line : nil
    }

    /// Git's record folder for the worktree at `path`: a direct child of `<repo>/.git/worktrees/` whose own
    /// `gitdir` file points back at `<path>/.git`. Nil otherwise.
    static func adminFolder(ofWorktree path: String, repo: String) -> String? {
        guard let dir = WorktreeDiscovery.gitDir(fromGitFile: URL(fileURLWithPath: path + "/.git")),
              let resolved = real(dir), isDirectory(resolved),
              let root = real(repo + "/.git/worktrees"),
              URL(fileURLWithPath: resolved).deletingLastPathComponent().path == root,
              let back = firstLine(resolved + "/gitdir"), let backReal = real(back),
              let mine = real(path + "/.git"), backReal == mine else { return nil }
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
