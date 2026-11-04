import Foundation
import Testing
@testable import CleanUpCore

@Suite struct WorktreeTrashTests {
    struct Env {
        let base: String
        let store: URL
        let fakeTrash: URL
        let repo: TempRepo
        let trash: WorktreeTrash
    }

    private struct TrashFailure: LocalizedError { var errorDescription: String? { "trash is unavailable" } }

    private static func real(_ path: String) -> String { realpath(path, nil).map { String(cString: $0) } ?? path }

    private func makeEnv(failTrash: Bool = false) throws -> Env {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let base = Self.real(raw.path)
        let fakeTrash = URL(fileURLWithPath: base + "/FakeTrash")
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let store = URL(fileURLWithPath: base + "/store")
        let repo = try TempRepo.make(in: base + "/projects", name: "app")
        let mover: @Sendable (URL) throws -> URL = { url in
            if failTrash { throw TrashFailure() }
            let dest = fakeTrash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }
        return Env(base: base, store: store, fakeTrash: fakeTrash, repo: repo,
                   trash: WorktreeTrash(store: store, trashItem: mover))
    }

    private func cleanup(_ env: Env) { try? FileManager.default.removeItem(atPath: env.base) }

    private func item(_ path: String, repo: String) -> Item {
        .fixture(.worktree(path: path), category: .worktrees, name: URL(fileURLWithPath: path).lastPathComponent,
                 detail: ["path": path, "repo": repo, "bytes": "1000"])
    }

    private let idle: @Sendable (Item) async -> Judgement = { _ in Judgement(verdict: .idle, fact: "ok", signals: []) }
    private func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }
    private func listed(_ env: Env, _ path: String) -> Bool {
        env.repo.run("worktree", "list", "--porcelain").contains("worktree \(path)\n")
            || env.repo.run("worktree", "list", "--porcelain").hasSuffix("worktree \(path)")
    }
    private func trashContents(_ env: Env) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: env.fakeTrash.path)) ?? []
    }

    @Test func trashMovesFolderAndAdmin() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("app-merged", branch: "feat/merged")
        let out = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        #expect(out.moved.count == 1)
        #expect(out.skipped.isEmpty)
        #expect(!out.permanent)
        #expect(!exists(wt))
        #expect(trashContents(env).count == 1)
        #expect(!listed(env, wt))
        env.repo.run("checkout", "feat/merged")
        #expect(env.repo.run("branch", "--show-current") == "feat/merged")
        let entries = await env.trash.entries
        #expect(entries.count == 1)
        #expect(entries[0].storedAdmin != nil)
        #expect(exists(entries[0].storedAdmin!))
    }

    @Test func putBackRestoresWorktree() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("app-merged", branch: "feat/merged")
        _ = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        let id = try #require(await env.trash.entries.first?.id)
        let failed = await env.trash.putBack([id])
        #expect(failed.isEmpty)
        #expect(exists(wt + "/a.txt"))
        #expect(listed(env, wt))
        #expect(env.repo.git(in: wt, ["status", "--porcelain"]) == "")
        #expect(await env.trash.entries.isEmpty)
        #expect(trashContents(env).isEmpty)
    }

    @Test func deleteNowRemovesOnlyThoseItems() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let a = env.repo.addWorktree("wa", branch: "feat/a")
        let b = env.repo.addWorktree("wb", branch: "feat/b")
        _ = await env.trash.moveToTrash([item(a, repo: env.repo.root), item(b, repo: env.repo.root)], recheck: idle)
        // An unrelated thing in the Trash must survive.
        let other = env.fakeTrash.appendingPathComponent("someone-elses-file.txt")
        try "keep".write(to: other, atomically: true, encoding: .utf8)
        let entries = await env.trash.entries
        let first = try #require(entries.first { $0.path == a })
        let second = try #require(entries.first { $0.path == b })
        await env.trash.deleteNow([first.id])
        #expect(!exists(first.trashURL))
        #expect(!exists(first.storedAdmin!))
        #expect(exists(second.trashURL))
        #expect(exists(second.storedAdmin!))
        #expect(exists(other.path))
        #expect(await env.trash.entries.map(\.id) == [second.id])
    }

    @Test func deleteNowToleratesMissingTrashItem() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let a = env.repo.addWorktree("wa", branch: "feat/a")
        _ = await env.trash.moveToTrash([item(a, repo: env.repo.root)], recheck: idle)
        let e = try #require(await env.trash.entries.first)
        try FileManager.default.removeItem(atPath: e.trashURL)
        await env.trash.deleteNow([e.id])
        #expect(await env.trash.entries.isEmpty)
        #expect(!exists(e.storedAdmin!))
    }

    @Test func recheckSkipsWorktreeThatBecameInUse() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let busy: @Sendable (Item) async -> Judgement = { _ in Judgement(verdict: .inUse, fact: "in use by node", signals: []) }
        let out = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: busy)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.count == 1)
        #expect(out.skipped[0].1 == "in use by node")
        #expect(exists(wt + "/a.txt"))
        #expect(listed(env, wt))
        #expect(trashContents(env).isEmpty)
        #expect(await env.trash.entries.isEmpty)
    }

    @Test func trashMovesSymlinkNotTarget() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let outside = env.base + "/outside"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        try "precious".write(toFile: outside + "/f.txt", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: wt + "/link", withDestinationPath: outside)
        let out = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        #expect(out.moved.count == 1)
        #expect(exists(outside + "/f.txt"))
    }

    @Test func putBackRefusesWhenPathIsTaken() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        _ = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        let e = try #require(await env.trash.entries.first)
        try FileManager.default.createDirectory(atPath: wt, withIntermediateDirectories: true)
        try "mine".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        let failed = await env.trash.putBack([e.id])
        #expect(failed == [e.id])
        #expect(exists(wt + "/new.txt"))
        #expect(!exists(wt + "/a.txt"))
        #expect(exists(e.trashURL))
        #expect(await env.trash.entries.count == 1)
    }

    @Test func putBackRefusesWhenRepoIsGone() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        _ = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        let e = try #require(await env.trash.entries.first)
        try FileManager.default.removeItem(atPath: env.repo.root)
        let failed = await env.trash.putBack([e.id])
        #expect(failed == [e.id])
        #expect(!exists(wt))
        #expect(exists(e.trashURL))
        #expect(await env.trash.entries.count == 1)
    }

    @Test func reconcileHandlesFinderActions() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let a = env.repo.addWorktree("wa", branch: "feat/a")
        let b = env.repo.addWorktree("wb", branch: "feat/b")
        _ = await env.trash.moveToTrash([item(a, repo: env.repo.root), item(b, repo: env.repo.root)], recheck: idle)
        let entries = await env.trash.entries
        let ea = try #require(entries.first { $0.path == a })
        let eb = try #require(entries.first { $0.path == b })
        // (a) emptied from the Trash in Finder.
        try FileManager.default.removeItem(atPath: ea.trashURL)
        // (b) moved back by hand.
        try FileManager.default.moveItem(atPath: eb.trashURL, toPath: b)
        await env.trash.reconcile()
        #expect(await env.trash.entries.isEmpty)
        #expect(!exists(ea.storedAdmin!))
        #expect(!exists(eb.storedAdmin!))
        #expect(listed(env, b))
        #expect(!listed(env, a))
        #expect(env.repo.git(in: b, ["status", "--porcelain"]) == "")
    }

    @Test func reconcileKeepsEntriesStillInTheTrash() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let a = env.repo.addWorktree("wa", branch: "feat/a")
        _ = await env.trash.moveToTrash([item(a, repo: env.repo.root)], recheck: idle)
        await env.trash.reconcile()
        #expect(await env.trash.entries.count == 1)
    }

    @Test func permanentRemovalUsesGitAndRefusesDirty() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let clean = env.repo.addWorktree("wclean", branch: "feat/clean")
        let dirty = env.repo.addWorktree("wdirty", branch: "feat/dirty")
        try "wip".write(toFile: dirty + "/wip.txt", atomically: true, encoding: .utf8)
        let out = await env.trash.removePermanently(
            [item(clean, repo: env.repo.root), item(dirty, repo: env.repo.root)], recheck: idle)
        #expect(out.permanent)
        #expect(out.moved.map(\.id) == [.worktree(path: clean)])
        #expect(out.skipped.count == 1)
        #expect(out.skipped[0].0.id == .worktree(path: dirty))
        #expect(out.skipped[0].1.contains("modified or untracked"))
        #expect(!out.skipped[0].1.contains("\n"))
        #expect(!exists(clean))
        #expect(!listed(env, clean))
        #expect(!exists(env.repo.root + "/.git/worktrees/wclean"))
        #expect(listed(env, dirty))
        #expect(exists(env.repo.root + "/.git/worktrees/wdirty"))
        #expect(exists(dirty + "/wip.txt"))
        // Branches are never deleted.
        #expect(env.repo.run("branch", "--list", "feat/clean").contains("feat/clean"))
        #expect(await env.trash.entries.isEmpty)
    }

    @Test func recordSurvivesRelaunch() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let a = env.repo.addWorktree("wa", branch: "feat/a")
        _ = await env.trash.moveToTrash([item(a, repo: env.repo.root)], recheck: idle)
        let again = WorktreeTrash(store: env.store)
        #expect(await again.entries == env.trash.entries)
        #expect(await again.entries.count == 1)
    }

    @Test func corruptRecordMeansEmpty() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        try FileManager.default.createDirectory(at: env.store, withIntermediateDirectories: true)
        try "{ nope".write(to: env.store.appendingPathComponent("trashed-worktrees.json"), atomically: true, encoding: .utf8)
        #expect(await WorktreeTrash(store: env.store).entries.isEmpty)
        #expect(await WorktreeTrash(store: URL(fileURLWithPath: env.base + "/nowhere")).entries.isEmpty)
    }

    @Test func outcomeCopy() {
        let moved = (0..<120).map { Item.fixture(.worktree(path: "/p/\($0)"), category: .worktrees) }
        let o = WorktreeOutcome(moved: moved, skipped: [], bytes: 208_300_000_000, permanent: false)
        #expect(o.title == "Moved 120 worktrees to the Trash")
        #expect(o.subtitle == "208.3 GB")
        let kept = WorktreeOutcome(moved: moved, skipped: [(moved[0], "x"), (moved[1], "y")], bytes: 208_300_000_000, permanent: true)
        #expect(kept.title == "Removed 120 worktrees")
        #expect(kept.subtitle == "208.3 GB · 2 kept")
        #expect(WorktreeOutcome(moved: [], skipped: [], bytes: 0, permanent: false).title == "Nothing moved")
        let one = [moved[0]]
        #expect(WorktreeOutcome(moved: one, skipped: [], bytes: 0, permanent: false).title == "Moved 1 worktree to the Trash")
        #expect(WorktreeOutcome(moved: one, skipped: [], bytes: 0, permanent: true).title == "Removed 1 worktree")
    }

    // Rulings 1 and 2

    @Test func adminFolderOutsideGitWorktreesIsNeverMoved() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let decoy = env.base + "/decoy"
        try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: true)
        try "precious".write(toFile: decoy + "/f.txt", atomically: true, encoding: .utf8)
        try "gitdir: \(decoy)\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        let out = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.first?.1 == "can't find git's record")
        #expect(exists(decoy + "/f.txt"))
        #expect(exists(wt + "/a.txt"))
        #expect(trashContents(env).isEmpty)
    }

    @Test func adminFolderThroughSymlinkIsComparedByRealPath() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let decoy = env.base + "/decoy"
        try FileManager.default.createDirectory(atPath: decoy, withIntermediateDirectories: true)
        let sneaky = env.repo.root + "/.git/worktrees/sneaky"
        try FileManager.default.createSymbolicLink(atPath: sneaky, withDestinationPath: decoy)
        try "gitdir: \(sneaky)\n".write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        let out = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.first?.1 == "can't find git's record")
        #expect(exists(decoy))
    }

    @Test func missingFolderIsSkipped() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let out = await env.trash.moveToTrash([item(env.base + "/nope", repo: env.repo.root)], recheck: idle)
        #expect(out.skipped.first?.1 == "folder is missing")
        let perm = await env.trash.removePermanently([item(env.base + "/nope", repo: env.repo.root)], recheck: idle)
        #expect(perm.skipped.first?.1 == "folder is missing")
    }

    @Test func symlinkedFolderIsSkipped() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let link = env.base + "/link-to-wa"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: wt)
        let out = await env.trash.moveToTrash([item(link, repo: env.repo.root)], recheck: idle)
        #expect(out.skipped.first?.1 == "folder is a link")
        let perm = await env.trash.removePermanently([item(link, repo: env.repo.root)], recheck: idle)
        #expect(perm.skipped.first?.1 == "folder is a link")
        #expect(exists(wt + "/a.txt"))
        #expect(trashContents(env).isEmpty)
    }

    @Test func failedTrashingPutsTheAdminFolderBack() async throws {
        let env = try makeEnv(failTrash: true); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let out = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.first?.1 == "trash is unavailable")
        #expect(listed(env, wt))
        #expect(env.repo.git(in: wt, ["status", "--porcelain"]) == "")
        #expect(await env.trash.entries.isEmpty)
    }

    // Ruling 7

    @Test func leftoversAreTrashedAndRemoved() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let f1 = env.base + "/home/.codex/worktrees/a1", f2 = env.base + "/home/.codex/worktrees/b2"
        for f in [f1, f2] { try FileManager.default.createDirectory(atPath: f, withIntermediateDirectories: true) }
        let leftovers = Item.fixture(.worktreeLeftovers, category: .worktrees, detail: ["paths": [f1, f2].joined(separator: "\n"), "bytes": "0"])
        let out = await env.trash.moveToTrash([leftovers], recheck: idle)
        #expect(out.moved.count == 1)
        #expect(!exists(f1) && !exists(f2))
        #expect(trashContents(env).count == 2)
        let entries = await env.trash.entries
        #expect(entries.count == 2)
        #expect(entries.allSatisfy { $0.repo == nil && $0.storedAdmin == nil })
        // Put back works for them too.
        let failed = await env.trash.putBack(entries.map(\.id))
        #expect(failed.isEmpty)
        #expect(exists(f1) && exists(f2))

        #expect(trashContents(env).isEmpty)
        let perm = await env.trash.removePermanently([leftovers], recheck: idle)
        #expect(perm.moved.count == 1)
        #expect(!exists(f1) && !exists(f2))
        #expect(trashContents(env).isEmpty)
    }

    // Fix round 1

    private func trashOne(_ env: Env, _ name: String = "wa", branch: String = "feat/a") async throws -> (path: String, entry: TrashedWorktree) {
        let wt = env.repo.addWorktree(name, branch: branch)
        _ = await env.trash.moveToTrash([item(wt, repo: env.repo.root)], recheck: idle)
        return (wt, try #require(await env.trash.entries.first { $0.path == wt }))
    }

    @Test func folderBackByHandWhileRepoMovedKeepsTheAdminFolder() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let (wt, e) = try await trashOne(env)
        try FileManager.default.moveItem(atPath: env.repo.root, toPath: env.base + "/projects/app-renamed")
        try FileManager.default.moveItem(atPath: e.trashURL, toPath: wt)
        await env.trash.reconcile()
        #expect(await env.trash.entries.count == 1)
        #expect(exists(e.storedAdmin!))
        await env.trash.deleteNow([e.id])
        #expect(await env.trash.entries.count == 1)
        #expect(exists(e.storedAdmin!))
        #expect(exists(wt + "/a.txt"))
    }

    @Test func unreadableTrashKeepsEntriesAndAdmins() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let (_, e) = try await trashOne(env)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.fakeTrash.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: env.fakeTrash.path)
        await env.trash.reconcile()
        await env.trash.deleteNow([e.id])
        let failed = await env.trash.putBack([e.id])
        #expect(failed == [e.id])
        #expect(await env.trash.entries.count == 1)
        #expect(exists(e.storedAdmin!))
    }

    @Test func deleteNowKeepsEntryWhileFolderIsBackAtItsPath() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let (wt, e) = try await trashOne(env)
        try FileManager.default.moveItem(atPath: e.trashURL, toPath: wt)
        await env.trash.deleteNow([e.id])
        #expect(await env.trash.entries.count == 1)
        #expect(exists(e.storedAdmin!))
        #expect(exists(wt + "/a.txt"))
    }

    @Test func reusedTrashNameIsNeverDeletedOrRestored() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let (wt, e) = try await trashOne(env)
        try FileManager.default.moveItem(atPath: e.trashURL, toPath: env.base + "/moved-away")
        try FileManager.default.createDirectory(atPath: e.trashURL, withIntermediateDirectories: true)
        try "impostor".write(toFile: e.trashURL + "/x.txt", atomically: true, encoding: .utf8)
        await env.trash.deleteNow([e.id])
        let failed = await env.trash.putBack([e.id])
        #expect(failed == [e.id])
        #expect(exists(e.trashURL + "/x.txt"))
        #expect(!exists(wt))
        #expect(await env.trash.entries.count == 1)
        #expect(exists(e.storedAdmin!))
    }

    @Test func oldRecordsWithoutIdentityStillDecode() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","path":"/a","trashURL":"/t","bytes":1,"date":0}]
        """
        let decoded = try JSONDecoder().decode([TrashedWorktree].self, from: Data(json.utf8))
        #expect(decoded.count == 1)
        #expect(decoded[0].fileID == nil && decoded[0].device == nil)
    }

    @Test func reconcileRecoversAnOrphanedAdminFolder() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let admin = env.repo.root + "/.git/worktrees/wa"
        let orphan = env.store.appendingPathComponent("admin/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: admin, toPath: orphan.path)
        #expect(!listed(env, wt))
        await env.trash.reconcile()
        #expect(exists(admin))
        #expect(!exists(orphan.path))
        #expect(listed(env, wt))
        #expect(env.repo.git(in: wt, ["status", "--porcelain"]) == "")
    }

    @Test func orphanWhoseFolderIsGoneIsLeftAlone() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let wt = env.repo.addWorktree("wa", branch: "feat/a")
        let orphan = env.store.appendingPathComponent("admin/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: orphan.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(atPath: env.repo.root + "/.git/worktrees/wa", toPath: orphan.path)
        try FileManager.default.removeItem(atPath: wt)
        await env.trash.reconcile()
        #expect(exists(orphan.path))
    }

    @Test func gitTimeoutSaysTheFolderMayBePartlyRemoved() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let slow = GitWorktrees(run: { _, _, _ in CommandResult(status: 15, stdout: "", stderr: "", timedOut: true) })
        let trash = WorktreeTrash(store: env.store, git: slow)
        let folder = env.base + "/folder"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let out = await trash.removePermanently([item(folder, repo: env.repo.root)], recheck: idle)
        #expect(out.skipped.first?.1 == "git took too long; the folder may be partly removed")
    }

    @Test func adminFolderMustBeADirectChildPointingBack() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let a = env.repo.addWorktree("wa", branch: "feat/a")
        let b = env.repo.addWorktree("wb", branch: "feat/b")
        // wa's .git names wb's record: its gitdir file points at wb, not wa.
        try "gitdir: \(env.repo.root)/.git/worktrees/wb\n".write(toFile: a + "/.git", atomically: true, encoding: .utf8)
        // A nested folder inside git's record folder.
        let nested = env.repo.root + "/.git/worktrees/wb/nested"
        try FileManager.default.createDirectory(atPath: nested, withIntermediateDirectories: true)
        try "gitdir: \(nested)\n".write(toFile: b + "/.git", atomically: true, encoding: .utf8)
        let out = await env.trash.moveToTrash([item(a, repo: env.repo.root), item(b, repo: env.repo.root)], recheck: idle)
        #expect(out.moved.isEmpty)
        #expect(out.skipped.map(\.1) == ["can't find git's record", "can't find git's record"])
        #expect(exists(a + "/a.txt") && exists(b + "/a.txt") && exists(nested))
    }

    // Fix round 2

    @Test func vanishedTrashFolderKeepsEntriesAndAdmins() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let (_, e) = try await trashOne(env)
        try FileManager.default.removeItem(at: env.fakeTrash)  // the volume went away
        await env.trash.reconcile()
        await env.trash.deleteNow([e.id])
        #expect(await env.trash.entries.count == 1)
        #expect(exists(e.storedAdmin!))
    }

    @Test func recordWithoutIdentityIsNeverDeletedOrRestored() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let (wt, e) = try await trashOne(env)
        let url = env.store.appendingPathComponent("trashed-worktrees.json")
        var rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        for i in rows.indices { rows[i].removeValue(forKey: "fileID"); rows[i].removeValue(forKey: "device") }
        try JSONSerialization.data(withJSONObject: rows).write(to: url)
        let old = WorktreeTrash(store: env.store)
        await old.deleteNow([e.id])
        #expect(await old.putBack([e.id]) == [e.id])
        #expect(exists(e.trashURL + "/a.txt"))
        #expect(!exists(wt))
        #expect(await old.entries.count == 1)
        #expect(exists(e.storedAdmin!))
    }

    @Test func pathThatBecameALinkIsNotRestoredByReconcile() async throws {
        let env = try makeEnv(); defer { cleanup(env) }
        let (wt, e) = try await trashOne(env)
        let real = env.base + "/real-folder"
        try FileManager.default.moveItem(atPath: e.trashURL, toPath: real)
        try FileManager.default.createSymbolicLink(atPath: wt, withDestinationPath: real)
        await env.trash.reconcile()
        #expect(await env.trash.entries.count == 1)
        #expect(exists(e.storedAdmin!))
        #expect(!listed(env, wt))
    }
}
