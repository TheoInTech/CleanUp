import Foundation
import Testing
@testable import CleanUpCore

struct WorktreeJudgeTests {
    @Test func mergedCleanQuietWorktreeIsSafe() {
        let j = WorktreeJudge.judge(.fixture(merge: .ancestor, lastCommitAgo: .days(6), agent: "Codex"), now: now)
        #expect(j.verdict == .idle); #expect(j.fact == "merged 6 days ago · Codex")
    }
    @Test func squashMergedIsSafe() { #expect(WorktreeJudge.judge(.fixture(merge: .squash), now: now).verdict == .idle) }
    @Test func uncommittedKeeps() {
        let j = WorktreeJudge.judge(.fixture(uncommitted: 3), now: now)
        #expect(j.verdict == .inUse); #expect(j.fact == "3 uncommitted changes")
        #expect(WorktreeJudge.judge(.fixture(uncommitted: 1), now: now).fact == "1 uncommitted change")
    }
    @Test func unmergedKeeps() {
        let j = WorktreeJudge.judge(.fixture(merge: .notMerged(commitsAhead: 2, base: "main")), now: now)
        #expect(j.verdict == .inUse); #expect(j.fact == "2 commits not on main")
    }
    @Test func processInsideKeeps() { #expect(WorktreeJudge.judge(.fixture(processesInside: ["node"]), now: now).fact == "in use by node") }
    @Test func lockedKeeps() { #expect(WorktreeJudge.judge(.fixture(locked: true), now: now).fact == "locked") }
    @Test func missingRepoKeeps() { #expect(WorktreeJudge.judge(.fixture(repoExists: false), now: now).fact == "can't check: repository missing") }
    @Test func changedInLastHourKeeps() {
        let j = WorktreeJudge.judge(.fixture(lastChangeAgo: .minutes(12)), now: now)
        #expect(j.verdict == .inUse); #expect(j.fact == "changed 12 min ago")
        #expect(WorktreeJudge.judge(.fixture(lastChangeAgo: .minutes(61)), now: now).verdict == .idle)
    }
    @Test func unknownsKeep() {
        #expect(WorktreeJudge.judge(.fixture(uncommitted: nil), now: now).verdict == .inUse)
        #expect(WorktreeJudge.judge(.fixture(merge: .unknown), now: now).verdict == .inUse)
        #expect(WorktreeJudge.judge(.fixture(lastChangeAgo: nil), now: now).fact == "measuring…")
    }
    @Test func agentLabels() {
        #expect(WorktreeAgent.label(path: "/Users/u/.codex/worktrees/a/app", branch: nil) == "Codex")
        #expect(WorktreeAgent.label(path: "/Users/u/.cursor/worktrees/x/app", branch: nil) == "Cursor")
        #expect(WorktreeAgent.label(path: "/Users/u/p/app/.claude/worktrees/x", branch: nil) == "Claude Code")
        #expect(WorktreeAgent.label(path: "/Users/u/p/app-fix", branch: "codex/fix") == "Codex")
        #expect(WorktreeAgent.label(path: "/Users/u/p/app-fix", branch: "fix/thing") == nil)
    }
    @Test func gigabytes() { #expect(Bytes.gb(208_300_000_000) == "208.3 GB"); #expect(Bytes.gb(40_000_000) == "<0.1 GB") }
}
