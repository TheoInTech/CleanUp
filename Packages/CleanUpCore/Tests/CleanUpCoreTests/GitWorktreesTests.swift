import Foundation
import Testing
@testable import CleanUpCore

@Suite struct GitWorktreesTests {
    let git = GitWorktrees()

    private func facts(_ repo: TempRepo, _ path: String, processes: [Int32: ProcessInfoRecord] = [:], ownPID: Int32 = 1) async -> WorktreeFacts {
        let entries = await git.list(repo: repo.root) ?? []
        let e = entries.first { $0.path == path }!
        return await git.facts(e, repo: repo.root, processes: processes, ownPID: ownPID, lastChange: nil)
    }

    @Test func parsesPorcelain() {
        let out = "worktree /r\nHEAD aaa\nbranch refs/heads/main\n\nworktree /r-a\nHEAD bbb\nbranch refs/heads/fix/a\nlocked\n\nworktree /r-b\nHEAD ccc\ndetached\nprunable gitdir file points to non-existent location\n"
        #expect(GitWorktrees.parsePorcelain(out).map(\.path) == ["/r", "/r-a", "/r-b"])
        #expect(GitWorktrees.parsePorcelain(out)[1] == GitWorktreeEntry(path: "/r-a", head: "bbb", branch: "fix/a", locked: true, prunable: false))
        #expect(GitWorktrees.parsePorcelain(out)[2].branch == nil)
        #expect(GitWorktrees.parsePorcelain(out)[2].prunable)
    }

    @Test func availableWhenGitIsInstalled() async {
        #expect(await git.available())
    }

    @Test func listSkipsMainCheckout() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        let entries = await git.list(repo: repo.root)
        #expect(entries?.map(\.path) == [wt])
        #expect(entries?.first?.branch == "feat/x")
    }

    @Test func mergedBranchIsAncestor() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.commit("b.txt", "b\n", on: nil, in: wt)
        repo.run("merge", "feat/x")
        let f = await facts(repo, wt)
        #expect(f.merge == .ancestor)
        #expect(f.uncommitted == 0)
        #expect(f.repoExists)
        #expect(f.lastCommit != nil)
    }

    @Test func freshWorktreeWithNoCommitsIsMerged() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        #expect(await facts(repo, wt).merge == .ancestor)
    }

    @Test func unmergedBranchCountsCommits() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.commit("b.txt", "b\n", on: nil, in: wt)
        repo.commit("c.txt", "c\n", on: nil, in: wt)
        #expect(await facts(repo, wt).merge == .notMerged(commitsAhead: 2, base: "main"))
    }

    @Test func squashMergedIsSquash() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.commit("a.txt", "one\ntwo\n", on: nil, in: wt)
        repo.squashMerge("feat/x")
        #expect(await facts(repo, wt).merge == .squash)
    }

    @Test func squashMergedThenMainChangedIsNotMerged() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.commit("a.txt", "one\ntwo\n", on: nil, in: wt)
        repo.squashMerge("feat/x")
        repo.commit("a.txt", "one\ntwo\nthree\n", on: nil)
        #expect(await facts(repo, wt).merge == .notMerged(commitsAhead: 1, base: "main"))
    }

    @Test func untrackedFileKeepsWorktree() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        try "x".write(toFile: wt + "/new.txt", atomically: true, encoding: .utf8)
        let f = await facts(repo, wt)
        #expect(f.merge == .ancestor)
        #expect(f.uncommitted == 1)
    }

    @Test func lockedIsReported() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.run("worktree", "lock", wt)
        #expect(await facts(repo, wt).locked)
    }

    @Test func processInsideIsReported() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        let table = processTable(
            .fixture(pid: 10, name: "node", cwd: wt + "/src"),
            .fixture(pid: 11, name: "zsh", cwd: wt + "-other"),
            .fixture(pid: 12, name: "me", cwd: wt)
        )
        let f = await facts(repo, wt, processes: table, ownPID: 12)
        #expect(f.processesInside == ["node"])
    }

    @Test func missingRepoIsReported() async {
        let entry = GitWorktreeEntry(path: "/nonexistent/wt", head: "abc", branch: "x", locked: false, prunable: false)
        let f = await git.facts(entry, repo: "/nonexistent/repo", processes: [:], ownPID: 1, lastChange: nil)
        #expect(!f.repoExists)
        #expect(f.merge == .unknown)
        #expect(f.uncommitted == nil)
    }

    @Test func nonAsciiFileNeverMergedIsNotSquash() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.commit("café.txt", "x\n", on: nil, in: wt)
        #expect(await facts(repo, wt).merge == .notMerged(commitsAhead: 1, base: "main"))
    }

    @Test func nonAsciiFileSquashMergedIsSquash() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.commit("café.txt", "x\n", on: nil, in: wt)
        repo.squashMerge("feat/x")
        #expect(await facts(repo, wt).merge == .squash)
    }

    @Test func renameNotOnBaseIsNotMerged() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        repo.git(in: wt, ["mv", "a.txt", "b.txt"])
        repo.git(in: wt, ["commit", "-m", "rename"])
        #expect(await facts(repo, wt).merge == .notMerged(commitsAhead: 1, base: "main"))
    }

    @Test func processInsideThroughSymlinkIsReported() async throws {
        let repo = try TempRepo.make()
        let wt = repo.addWorktree("wt", branch: "feat/x")
        let link = (wt as NSString).deletingLastPathComponent + "/link"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: wt)
        let entry = GitWorktreeEntry(path: link, head: "", branch: "feat/x", locked: false, prunable: false)
        let table = processTable(.fixture(pid: 10, name: "node", cwd: wt + "/src"))
        let f = await git.facts(entry, repo: repo.root, processes: table, ownPID: 1, lastChange: nil)
        #expect(f.processesInside == ["node"])
        #expect(f.path == link)
    }
    /// Every git call a fake runner saw, in order.
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [[String]] = []
        func add(_ args: [String]) { lock.withLock { all.append(args) } }
        var args: [[String]] { lock.withLock { all } }
    }

    @Test func readOnlyGitCallsNeverTakeTheIndexLock() async throws {
        let calls = Calls()
        let fake = GitWorktrees(run: { tool, args, _ in
            if tool == "/usr/bin/git" { calls.add(args) }
            // Not an ancestor, so the squash check (and its diffs) runs too.
            return CommandResult(status: args.contains("--is-ancestor") ? 1 : 0, stdout: "", stderr: "", timedOut: false)
        })
        let dir = FileManager.default.temporaryDirectory.path  // a folder that exists, so facts asks git
        _ = await fake.list(repo: dir)
        let entry = GitWorktreeEntry(path: dir, head: "abc", branch: "x", locked: false, prunable: false)
        _ = await fake.facts(entry, repo: dir, processes: [:], ownPID: 1, lastChange: nil)
        let reads = calls.args
        #expect(reads.count > 5)
        #expect(reads.contains { $0.contains("status") })
        #expect(reads.contains { $0.contains("diff") })
        #expect(reads.allSatisfy { $0.first == "--no-optional-locks" })

        _ = await fake.removeWorktree(repo: dir, path: dir + "/wt")
        _ = await fake.repairWorktree(repo: dir, path: dir + "/wt")
        let writes = calls.args.dropFirst(reads.count)
        #expect(writes.count == 2)
        #expect(writes.allSatisfy { !$0.contains("--no-optional-locks") })
    }
}
