import Foundation
import Testing
@testable import CleanUpCore

@Suite struct WorktreeDiscoveryTests {
    /// A fake home folder under the temp directory, resolved past /private/var.
    private func makeHome() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("wd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return URL(fileURLWithPath: String(cString: realpath(raw.path, nil)))
    }

    private func dir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func gitFile(in folder: URL, _ content: String) throws {
        try dir(folder)
        try content.write(to: folder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
    }

    @Test func findsSiblingAndAgentWorktrees() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let app = home.appendingPathComponent("Projects/app")
        try dir(app.appendingPathComponent(".git"))
        try gitFile(in: home.appendingPathComponent("Projects/app-fix"), "gitdir: \(app.path)/.git/worktrees/app-fix\n")
        try gitFile(in: home.appendingPathComponent(".codex/worktrees/a/app"), "gitdir: \(app.path)/.git/worktrees/a\n")
        #expect(WorktreeDiscovery.repositories(home: home, includeProtected: false) == [app.path])
    }

    @Test func submodulesAreNotWorktrees() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let sub = home.appendingPathComponent("sub")
        try gitFile(in: sub, "gitdir: ../.git/modules/x\n")
        #expect(WorktreeDiscovery.repo(fromGitFile: sub.appendingPathComponent(".git")) == nil)
        #expect(WorktreeDiscovery.repositories(home: home, includeProtected: false).isEmpty)
    }

    @Test func gitDirResolvesAbsoluteAndRelative() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let abs = home.appendingPathComponent("abs")
        try gitFile(in: abs, "gitdir: /r/app/.git/worktrees/abs\n")
        #expect(WorktreeDiscovery.gitDir(fromGitFile: abs.appendingPathComponent(".git")) == "/r/app/.git/worktrees/abs")
        #expect(WorktreeDiscovery.repo(fromGitFile: abs.appendingPathComponent(".git")) == "/r/app")

        let rel = home.appendingPathComponent("p/rel")
        try gitFile(in: rel, "gitdir: ../app/.git/worktrees/rel\n")
        let expected = home.appendingPathComponent("p/app/.git/worktrees/rel").path
        #expect(WorktreeDiscovery.gitDir(fromGitFile: rel.appendingPathComponent(".git")) == expected)
        #expect(WorktreeDiscovery.repo(fromGitFile: rel.appendingPathComponent(".git")) == home.appendingPathComponent("p/app").path)

        let junk = home.appendingPathComponent("junk")
        try gitFile(in: junk, "hello\n")
        #expect(WorktreeDiscovery.gitDir(fromGitFile: junk.appendingPathComponent(".git")) == nil)
        #expect(WorktreeDiscovery.gitDir(fromGitFile: home.appendingPathComponent("missing/.git")) == nil)
    }

    @Test func skipsNodeModulesAndLibrary() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try gitFile(in: home.appendingPathComponent("proj/node_modules/x"), "gitdir: /r/a/.git/worktrees/x\n")
        try gitFile(in: home.appendingPathComponent("Library/y"), "gitdir: /r/b/.git/worktrees/y\n")
        try gitFile(in: home.appendingPathComponent("Pics/a.photoslibrary/z"), "gitdir: /r/c/.git/worktrees/z\n")
        #expect(WorktreeDiscovery.repositories(home: home, includeProtected: true).isEmpty)
    }

    @Test func protectedFoldersOnlyWhenAsked() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try gitFile(in: home.appendingPathComponent("Documents/w"), "gitdir: /r/a/.git/worktrees/w\n")
        #expect(WorktreeDiscovery.repositories(home: home, includeProtected: false).isEmpty)
        #expect(WorktreeDiscovery.repositories(home: home, includeProtected: true) == ["/r/a"])
    }

    @Test func depthLimit() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // .git at level 7 below home: six folders then the marker.
        try gitFile(in: home.appendingPathComponent("a/b/c/d/e/f"), "gitdir: /r/seven/.git/worktrees/w\n")
        // .git at level 8.
        try gitFile(in: home.appendingPathComponent("a/b/c/d/e/f/g"), "gitdir: /r/eight/.git/worktrees/w\n")
        try gitFile(in: home.appendingPathComponent("x/b/c/d/e/f/g"), "gitdir: /r/eight/.git/worktrees/w\n")
        #expect(WorktreeDiscovery.repositories(home: home, includeProtected: false) == ["/r/seven"])
    }

    @Test func doesNotFollowSymlinks() throws {
        let home = try makeHome()
        let outside = try makeHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        try gitFile(in: outside.appendingPathComponent("wt"), "gitdir: /r/a/.git/worktrees/wt\n")
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("link"), withDestinationURL: outside)
        #expect(WorktreeDiscovery.repositories(home: home, includeProtected: false).isEmpty)
    }

    @Test func leftoverAgentFolders() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let old = home.appendingPathComponent(".codex/worktrees/old")
        try dir(old)
        try "x".write(to: old.appendingPathComponent(".codex-worktree-name"), atomically: true, encoding: .utf8)
        try gitFile(in: home.appendingPathComponent(".codex/worktrees/live/app"), "gitdir: /r/a/.git/worktrees/live\n")
        try dir(home.appendingPathComponent(".cursor/worktrees/empty"))
        let big = home.appendingPathComponent(".cursor/worktrees/big")
        try dir(big)
        try Data(count: 2_000_000).write(to: big.appendingPathComponent("blob"))
        let found = WorktreeDiscovery.leftoverAgentFolders(home: home).map(\.path).sorted()
        #expect(found == [home.appendingPathComponent(".cursor/worktrees/empty").path, old.path].sorted())
    }
}
