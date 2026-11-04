import Foundation
import Testing
@testable import CleanUpCore

@Suite struct WorktreeScannerTests {
    private func makeHome() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("ws-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
    }

    /// Pushes every file's modification time `days` into the past so the recent-change check passes.
    private func age(_ path: String, days: Double = 3) {
        let past = Date().addingTimeInterval(-days * 86_400)
        let fm = FileManager.default
        var paths = [path]
        if let e = fm.enumerator(atPath: path) { for case let rel as String in e { paths.append(path + "/" + rel) } }
        for p in paths { try? fm.setAttributes([.modificationDate: past], ofItemAtPath: p) }
    }

    private func scan(_ scanner: WorktreeScanner, trashed: [TrashedWorktree] = []) async -> WorktreeSnapshot? {
        await scanner.scan(processes: [:], ownPID: 1, includeProtected: false, trashed: trashed, now: Date())
    }

    @Test func scansSafeAndKeptWorktrees() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        repo.commit("big.txt", String(repeating: "x", count: 50_000), on: nil)
        let merged = repo.addWorktree("app-merged", branch: "feat/merged")
        let dirty = repo.addWorktree("app-dirty", branch: "feat/dirty")
        try "wip\n".write(toFile: dirty + "/wip.txt", atomically: true, encoding: .utf8)
        age(merged); age(dirty)

        let snap = try #require(await scan(WorktreeScanner(home: home)))
        #expect(snap.items.count == 2)
        let safe = try #require(snap.items.first { $0.name == "app-merged" })
        let kept = try #require(snap.items.first { $0.name == "app-dirty" })
        #expect(safe.judgement.verdict == .idle)
        #expect(kept.judgement.verdict != .idle)
        #expect(safe.id == .worktree(path: merged))
        #expect(safe.detail["repo"] == repo.root)
        #expect(safe.detail["repoName"] == "app")
        #expect(safe.detail["branch"] == "feat/merged")
        #expect(safe.detail["path"] == merged)
        #expect(snap.safeBytes > 0)
        #expect(snap.keptBytes > 0)
        #expect(snap.safeBytes == Int64(safe.detail["bytes"]!))
        #expect(snap.trashedBytes == 0)
        // Largest first.
        let sizes = snap.items.map { Int64($0.detail["bytes"]!)! }
        #expect(sizes == sizes.sorted(by: >))
    }

    @Test func sameFolderNameInTwoReposStaysSeparate() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let a = try TempRepo.make(in: home.appendingPathComponent("p1").path, name: "alpha")
        let b = try TempRepo.make(in: home.appendingPathComponent("p2").path, name: "beta")
        let wa = a.addWorktree("wt/app", branch: "feat/a")
        let wb = b.addWorktree("wt/app", branch: "feat/b")
        age(wa); age(wb)

        let snap = try #require(await scan(WorktreeScanner(home: home)))
        #expect(snap.items.count == 2)
        #expect(Set(snap.items.map(\.id)).count == 2)
        #expect(Set(snap.items.compactMap { $0.detail["repoName"] }) == ["alpha", "beta"])
        #expect(snap.items.allSatisfy { $0.name == "app" })
    }

    @Test func noGitMeansNoCategory() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let git = GitWorktrees(run: { _, _, _ in CommandResult(status: 2, stdout: "", stderr: "", timedOut: false) })
        #expect(await scan(WorktreeScanner(git: git, home: home)) == nil)
    }

    @Test func leftoversBecomeOneItem() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for n in ["a1", "b2"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent(".codex/worktrees/\(n)"), withIntermediateDirectories: true)
        }
        let snap = try #require(await scan(WorktreeScanner(home: home)))
        let item = try #require(snap.items.first)
        #expect(snap.items.count == 1)
        #expect(item.id == .worktreeLeftovers)
        #expect(item.name == "Leftover agent folders")
        #expect(item.judgement.verdict == .idle)
        #expect(item.judgement.fact == "2 empty folders")
        #expect(item.detail["paths"]?.split(separator: "\n").count == 2)
        #expect(item.detail["bytes"] != nil)
    }

    @Test func missingWorktreeFolderIsKept() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        let wt = repo.addWorktree("app-gone", branch: "feat/gone")
        try FileManager.default.removeItem(atPath: wt)
        #expect(repo.run("worktree", "list", "--porcelain").contains("prunable"))

        let snap = try #require(await scan(WorktreeScanner(home: home)))
        // The scanner leaves it out entirely (discovery finds repositories through the worktrees' own
        // `.git` files), so a missing folder can never be offered for removal. Were it ever listed, it must be kept.
        let item = snap.items.first { $0.id == .worktree(path: wt) }
        #expect(item == nil || item?.judgement.verdict != .idle)
        #expect(item == nil)
    }

    @Test func mainCheckoutIsNeverAnItem() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        _ = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        let snap = try #require(await scan(WorktreeScanner(home: home)))
        #expect(snap.items.isEmpty)
    }

    @Test func freshlyTouchedWorktreeIsKept() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        _ = repo.addWorktree("app-new", branch: "feat/new")
        let snap = try #require(await scan(WorktreeScanner(home: home)))
        #expect(snap.items.first?.judgement.verdict != .idle)
    }

    @Test func trashedBytesSumAndCodable() throws {
        let t = TrashedWorktree(id: UUID(), path: "/a", repo: "/r", storedAdmin: nil, trashURL: "file:///t", bytes: 7, date: Date(timeIntervalSince1970: 0))
        let u = TrashedWorktree(id: UUID(), path: "/b", repo: nil, storedAdmin: "x", trashURL: "file:///u", bytes: 5, date: Date(timeIntervalSince1970: 0))
        let snap = WorktreeSnapshot(date: Date(), items: [], trashed: [t, u])
        #expect(snap.trashedBytes == 12)
        let back = try JSONDecoder().decode(TrashedWorktree.self, from: JSONEncoder().encode(t))
        #expect(back == t)
    }
}

@Suite struct WorktreeRecheckTests {
    private func makeHome() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("wr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
    }

    private func age(_ path: String, days: Double = 3) {
        let past = Date().addingTimeInterval(-days * 86_400)
        let fm = FileManager.default
        var paths = [path]
        if let e = fm.enumerator(atPath: path) { for case let rel as String in e { paths.append(path + "/" + rel) } }
        for p in paths { try? fm.setAttributes([.modificationDate: past], ofItemAtPath: p) }
    }

    private func scan(_ s: WorktreeScanner) async -> WorktreeSnapshot? {
        await s.scan(processes: [:], ownPID: 1, includeProtected: false, trashed: [], now: Date())
    }

    @Test func worktreeThatBecomesDirtyIsKept() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        let wt = repo.addWorktree("app-wt", branch: "feat/wt")
        age(wt)
        let scanner = WorktreeScanner(home: home)
        let item = try #require(await scan(scanner)?.items.first)
        #expect(item.judgement.verdict == .idle)
        try "wip\n".write(toFile: wt + "/wip.txt", atomically: true, encoding: .utf8)
        age(wt)
        let j = await scanner.recheck(item, processes: [:], ownPID: 1, now: Date())
        #expect(j.verdict != .idle)
    }

    @Test func deepFileWrittenAfterCachedScanIsCaught() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        try FileManager.default.createDirectory(atPath: repo.root + "/a/b/c", withIntermediateDirectories: true)
        repo.commit(".gitignore", "*.log\n", on: nil)
        repo.commit("a/b/c/deep.txt", "x", on: nil)
        let wt = repo.addWorktree("app-wt", branch: "feat/wt")
        age(wt)
        let scanner = WorktreeScanner(home: home)
        let item = try #require(await scan(scanner)?.items.first)
        #expect(item.judgement.verdict == .idle)
        // A git-ignored file deep down leaves git clean; only a fresh measure can see it.
        try "later".write(toFile: wt + "/a/b/c/build.log", atomically: true, encoding: .utf8)
        let j = await scanner.recheck(item, processes: [:], ownPID: 1, now: Date())
        #expect(j.verdict != .idle)
        #expect(j.fact.contains("changed"))
        #expect(j.fact.contains("ago"))
    }

    @Test func missingWorktreeCannotBeChecked() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        let wt = repo.addWorktree("app-wt", branch: "feat/wt")
        age(wt)
        let scanner = WorktreeScanner(home: home)
        let item = try #require(await scan(scanner)?.items.first)
        _ = repo.run("worktree", "remove", "--force", wt)
        let j = await scanner.recheck(item, processes: [:], ownPID: 1, now: Date())
        #expect(j.verdict != .idle)
        #expect(j.fact == "can't check it again")
    }

    @Test func leftoverFolderThatGainsAFileIsKept() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = home.appendingPathComponent(".codex/worktrees/a1")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scanner = WorktreeScanner(home: home)
        let item = try #require(await scan(scanner)?.items.first)
        #expect(await scanner.recheck(item, processes: [:], ownPID: 1, now: Date()).verdict == .idle)
        // Any file that isn't an agent marker makes it a real folder.
        try "hi".write(
            to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        let j = await scanner.recheck(item, processes: [:], ownPID: 1, now: Date())
        #expect(j.verdict != .idle)
        #expect(j.fact == "no longer empty")
    }
}

/// A worktree an agent made inside another worktree, in a git-ignored folder: the outer one looks clean,
/// but removing it would take the inner one's work with it.
@Suite struct NestedWorktreeTests {
    private func makeHome() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("wn-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
    }

    private func age(_ path: String, days: Double = 3) {
        let past = Date().addingTimeInterval(-days * 86_400)
        let fm = FileManager.default
        var paths = [path]
        if let e = fm.enumerator(atPath: path) { for case let rel as String in e { paths.append(path + "/" + rel) } }
        for p in paths { try? fm.setAttributes([.modificationDate: past], ofItemAtPath: p) }
    }

    private func scan(_ s: WorktreeScanner) async -> WorktreeSnapshot? {
        await s.scan(processes: [:], ownPID: 1, includeProtected: false, trashed: [], now: Date())
    }

    /// A repo whose main branch ignores `.claude/` and `.build/`, and a merged worktree `app-a` beside it.
    private func makeParent(_ home: URL) throws -> (TempRepo, String) {
        let repo = try TempRepo.make(in: home.appendingPathComponent("Projects").path, name: "app")
        repo.commit(".gitignore", ".claude/\n.build/\n", on: nil)
        let a = repo.addWorktree("app-a", branch: "feat/a")
        return (repo, a)
    }

    /// Adds worktree `b` inside `parent`'s ignored `.claude/worktrees`, with uncommitted work in it.
    private func nest(_ repo: TempRepo, in parent: String) throws -> String {
        let b = parent + "/.claude/worktrees/b"
        repo.run("worktree", "add", "-b", "feat/b", b)
        try "wip\n".write(toFile: b + "/wip.txt", atomically: true, encoding: .utf8)
        return b
    }

    @Test func parentOfNestedWorktreeIsKeptByScan() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (repo, a) = try makeParent(home)
        let b = try nest(repo, in: a)
        age(a)
        #expect(repo.git(in: a, ["status", "--porcelain"]) == "")  // git alone would call it clean

        let snap = try #require(await scan(WorktreeScanner(home: home)))
        let parent = try #require(snap.items.first { $0.id == .worktree(path: a) })
        #expect(parent.judgement.verdict != .idle)
        #expect(parent.judgement.fact == "holds another worktree")
        #expect(snap.items.first { $0.id == .worktree(path: b) }?.judgement.verdict != .idle)
    }

    @Test func parentOfNestedWorktreeIsKeptByRecheck() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (repo, a) = try makeParent(home)
        age(a)
        let scanner = WorktreeScanner(home: home)
        let item = try #require(await scan(scanner)?.items.first { $0.id == .worktree(path: a) })
        #expect(item.judgement.verdict == .idle)
        _ = try nest(repo, in: a)
        age(a)
        let j = await scanner.recheck(item, processes: [:], ownPID: 1, now: Date())
        #expect(j.verdict != .idle)
        #expect(j.fact == "holds another worktree")
    }

    @Test func listedNestedWorktreeKeepsParentEvenWhenTheWalkMissesIt() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (repo, a) = try makeParent(home)
        let b = try nest(repo, in: a)
        try FileManager.default.removeItem(atPath: b)  // git still lists it, but the walk finds no `.git` file
        age(a)
        #expect(repo.run("worktree", "list", "--porcelain").contains("worktree \(b)\n"))

        let scanner = WorktreeScanner(home: home)
        let parent = try #require(await scan(scanner)?.items.first { $0.id == .worktree(path: a) })
        #expect(parent.judgement.verdict != .idle)
        #expect(parent.judgement.fact == "holds another worktree")
        #expect(await scanner.recheck(parent, processes: [:], ownPID: 1, now: Date()).verdict != .idle)
    }

    @Test func swiftPMCheckoutInsideIsStillSafe() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (_, a) = try makeParent(home)
        let clone = a + "/.build/checkouts/swift-argument-parser/.git"
        try FileManager.default.createDirectory(atPath: clone, withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(toFile: clone + "/HEAD", atomically: true, encoding: .utf8)
        age(a)
        let scanner = WorktreeScanner(home: home)
        let item = try #require(await scan(scanner)?.items.first { $0.id == .worktree(path: a) })
        #expect(item.judgement.verdict == .idle)
        #expect(await scanner.recheck(item, processes: [:], ownPID: 1, now: Date()).verdict == .idle)
    }

    @Test func moveToTrashSkipsParentWithTheRealRecheck() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (repo, a) = try makeParent(home)
        age(a)
        let scanner = WorktreeScanner(home: home)
        let item = try #require(await scan(scanner)?.items.first { $0.id == .worktree(path: a) })
        #expect(item.judgement.verdict == .idle)
        let b = try nest(repo, in: a)
        age(a)

        let fakeTrash = home.appendingPathComponent("FakeTrash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let trash = WorktreeTrash(store: home.appendingPathComponent("store"), trashItem: { url in
            let dest = fakeTrash.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        })
        let out = await trash.moveToTrash([item], recheck: { await scanner.recheck($0, processes: [:], ownPID: 1, now: Date()) })
        #expect(out.moved.isEmpty)
        #expect(out.skipped.first?.1 == "holds another worktree")
        #expect(FileManager.default.fileExists(atPath: b + "/wip.txt"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: fakeTrash.path)) ?? []).isEmpty)
        #expect(await trash.entries.isEmpty)
    }
}
