# Worktrees Storage Category Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Worktrees storage category that finds stale git worktrees left by AI coding agents, marks them safe only when merged and clean, shows their storage as a bar, and moves them to the Trash with Undo and Delete now.

**Architecture:** A self-contained `Worktrees/` area in `CleanUpCore` (pure judge, git probe, discovery walk, folder sizes, scanner actor, Trash actor with a persisted record). Worktrees are `Item`s with a new `CategoryID.worktrees` so existing rows, the "?" sheet and the keep list can show them, but they live in their own `WorktreeSnapshot`, never in `Snapshot.categories`, so the main Scanner, Cleaner, Quick select, widget and drain warning never see them. The app gets a `WorktreesModel` and new views (storage bar, Worktrees section with its own button, popover line, settings).

**Tech Stack:** Swift 6.2+ (strict concurrency), SwiftUI, Swift Testing, `/usr/bin/git` through `CommandRunner`, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-04-worktrees-design.md` (extends `docs/superpowers/specs/2026-11-02-cleanup-design.md`).

## Global Constraints

- macOS 26+; no network access, accounts or telemetry.
- Every external command goes through `CommandRunner.run(_:_:timeout:)` with a timeout (git: 10 s), never on the main thread; scanning runs at `.utility` priority.
- Anything unknown counts as kept (never ticked). No `git worktree remove --force`, ever. Branches are never deleted. The main checkout of a repository is never touched.
- Never follow a symlink out of a worktree; never delete anything outside the worktree's own folder (and its git admin folder).
- Worktrees are never included in the main Clean up button, Quick select of `Snapshot`, the widget's snapshot, the widget's Clean up or the drain notification.
- Scanning skips `~/Documents`, `~/Desktop`, `~/Downloads` and `~/Library/Mobile Documents` unless the setting "Also look in Documents and Desktop" is on; it never walks `~/Library` otherwise (avoids "data from other apps" prompts).
- Exact copy (from the spec): category name "Worktrees"; own button "Clean up N worktrees · X GB"; storage caption "X GB safe to remove · Y GB kept"; result title "Moved N worktrees to the Trash"; "Delete now · frees X GB"; confirmation "Delete N worktrees permanently? This can't be undone."; settings "Also look in Documents and Desktop", "Remove worktrees permanently"; kept facts "N uncommitted changes", "N commits not on main", "in use by <process>", "locked", "can't check: repository missing", "changed N min ago"; "?" lose line "Nothing in git. Files git ignores, like `.env`, go to the Trash with it."
- GB shown with one decimal (`String(format: "%.1f GB", bytes / 1e9)`), sizes below 0.1 GB as "<0.1 GB".
- Tests: Swift Testing, in `Packages/CleanUpCore/Tests/CleanUpCoreTests/`; git-backed tests create throwaway repos under `FileManager.default.temporaryDirectory`, never touch the user's repos or the real Trash.

## Review Focus

1. A worktree whose only change is a new untracked file is kept ("1 uncommitted change") — Task 2 test `untrackedFileKeepsWorktree`.
2. A squash-merged branch whose files main has changed again since is kept, not offered — Task 2 test `squashMergedThenMainChangedIsNotMerged`.
3. An agent starts working in a worktree after the scan but before Clean up: the re-check skips it — Task 6 test `recheckSkipsWorktreeThatBecameInUse`.
4. A symlink inside a worktree points at a big folder outside it: not counted in its size, and trashing moves only the link — Task 4 test `symlinkTargetsAreNotCounted`, Task 6 test `trashMovesSymlinkNotTarget`.
5. Two worktrees with the same folder name in different repos (e.g. `~/.codex/worktrees/a/app` and `~/.codex/worktrees/b/app`) stay separate items and show which repo each belongs to — Task 5 test `sameFolderNameInTwoReposStaysSeparate`.

---

### Task 1: Model and pure judge

**Files:**
- Modify: `Packages/CleanUpCore/Sources/CleanUpCore/Model/CategoryID.swift` (add `case worktrees`)
- Modify: `Packages/CleanUpCore/Sources/CleanUpCore/Model/ItemIdentity.swift` (add identities)
- Modify: every exhaustive `switch` over `CategoryID` the compiler flags (`App/Views/Palette.swift`, `Explain/FallbackTexts.swift`, `Explain/Explainer.swift`, `Engine/DrainWarning.swift`)
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/WorktreeJudge.swift`
- Test: `Packages/CleanUpCore/Tests/CleanUpCoreTests/WorktreeJudgeTests.swift`

**Interfaces:**
- Produces:
  - `ItemIdentity.worktree(path: String) -> ItemIdentity` (`"worktree:<path>"`), `ItemIdentity.worktreeLeftovers` (`"worktree-leftovers"`).
  - `public enum MergeState: Sendable, Equatable { case ancestor, squash, notMerged(commitsAhead: Int, base: String), unknown }`
  - `public struct WorktreeFacts: Sendable, Equatable { path: String; repo: String; branch: String?; agent: String?; uncommitted: Int?; merge: MergeState; locked: Bool; processesInside: [String]; lastChange: Date?; lastCommit: Date?; repoExists: Bool }` (memberwise `public init`)
  - `public enum WorktreeJudge { static let recentChange: TimeInterval = 3600; static func judge(_ f: WorktreeFacts, now: Date) -> Judgement }` — verdict `.idle` = safe, `.inUse` = kept.
  - `public enum WorktreeAgent { static func label(path: String, branch: String?) -> String? }`
  - `public enum Bytes { static func gb(_ bytes: Int64) -> String }`
- `DrainWarning.noun` returns nil for `.worktrees`; `Palette` gets indigo `0x5E5CE6`, name "Worktrees", symbol "arrow.triangle.branch".

- [ ] **Step 1: Write the failing tests**

```swift
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
```

Add `WorktreeFacts.fixture(...)` to `TestSupport.swift` (defaults: clean `uncommitted: 0`, `merge: .ancestor`, `locked: false`, no processes, `lastChangeAgo: .days(6)`, `lastCommitAgo: .days(6)`, `repoExists: true`, `agent: nil`).

- [ ] **Step 2: Run to verify they fail** — `swift test --package-path Packages/CleanUpCore --filter WorktreeJudge` → compile errors (types missing).
- [ ] **Step 3: Implement.** Reason order (first wins as `fact`): repo missing, uncommitted, not merged, process inside, locked, measuring (lastChange nil), changed recently, unknown merge ("can't tell if it's merged"). Signals: one row per check, `.idle` when it passes. Safe fact: `"merged \(RelativeAge.short(age)) ago"` from `lastCommit`, plus `" · \(agent)"`. Agent rules: path contains `/.codex/` → Codex, `/.cursor/` → Cursor, `/.claude/worktrees/` or `/.claude-worktrees/` → Claude Code, `/conductor/` → Conductor, `antigravity` → Antigravity, `/.worktrees/` → VS Code; else branch prefix `codex/`, `claude/`, `cursor/`, `copilot/` → Codex, Claude Code, Cursor, Copilot. Update the flagged switches.
- [ ] **Step 4: Run** — same filter passes; full `swift test` passes; `xcodebuild -scheme CleanUp build` succeeds.
- [ ] **Step 5: Commit** — `feat(worktrees): model and judge`.

### Task 2: Git probe (facts from real git)

**Files:**
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/GitWorktrees.swift`
- Modify: `Packages/CleanUpCore/Tests/CleanUpCoreTests/TestSupport.swift` (add `TempRepo`)
- Test: `Packages/CleanUpCore/Tests/CleanUpCoreTests/GitWorktreesTests.swift`

**Interfaces:**
- Consumes: `WorktreeFacts`, `MergeState` (Task 1).
- Produces:
  - `public struct GitWorktreeEntry: Sendable, Equatable { path: String; head: String; branch: String?; locked: Bool; prunable: Bool }`
  - `public struct GitWorktrees: Sendable { typealias Run = @Sendable (String, [String], Duration) async -> CommandResult; init(run: Run? = nil); func available() async -> Bool; func list(repo: String) async -> [GitWorktreeEntry]?; func facts(_ e: GitWorktreeEntry, repo: String, processes: [Int32: ProcessInfoRecord], ownPID: Int32, lastChange: Date?) async -> WorktreeFacts; static func parsePorcelain(_ out: String) -> [GitWorktreeEntry] }`
  - `list` excludes the first block (the main checkout); `available()` runs `/usr/bin/xcode-select -p` then `/usr/bin/git --version`.
- Test support: `TempRepo` with `static func make() throws -> TempRepo`, `func commit(_ file: String, _ text: String, on branch: String?)`, `func addWorktree(_ name: String, branch: String) -> String` (path), `func run(_ args: String...) -> String`, `func squashMerge(_ branch: String)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func parsesPorcelain() {
    let out = "worktree /r\nHEAD aaa\nbranch refs/heads/main\n\nworktree /r-a\nHEAD bbb\nbranch refs/heads/fix/a\nlocked\n\nworktree /r-b\nHEAD ccc\ndetached\nprunable gitdir file points to non-existent location\n"
    #expect(GitWorktrees.parsePorcelain(out).map(\.path) == ["/r", "/r-a", "/r-b"])
    #expect(GitWorktrees.parsePorcelain(out)[1] == GitWorktreeEntry(path: "/r-a", head: "bbb", branch: "fix/a", locked: true, prunable: false))
    #expect(GitWorktrees.parsePorcelain(out)[2].branch == nil)
}
@Test func listSkipsMainCheckout() async throws { /* repo + 1 worktree → list returns 1 entry, its path */ }
@Test func mergedBranchIsAncestor() async throws { /* worktree branch merged into main (git merge) → merge == .ancestor, uncommitted == 0 */ }
@Test func freshWorktreeWithNoCommitsIsMerged() async throws { /* worktree on a new branch, no commits → .ancestor */ }
@Test func unmergedBranchCountsCommits() async throws { /* 2 commits on branch, not merged → .notMerged(commitsAhead: 2, base: "main") */ }
@Test func squashMergedIsSquash() async throws { /* branch changes a.txt; main squash-merges it → .squash */ }
@Test func squashMergedThenMainChangedIsNotMerged() async throws { /* as above, then main edits a.txt again → .notMerged(...) */ }
@Test func untrackedFileKeepsWorktree() async throws { /* merged, plus new untracked file → uncommitted == 1 */ }
@Test func lockedIsReported() async throws { /* git worktree lock <path> → locked == true */ }
@Test func processInsideIsReported() async throws {
    // a ProcessInfoRecord with cwd == "<wt>/src" and name "node" → processesInside == ["node"]; ownPID's own cwd ignored
}
@Test func missingRepoIsReported() async { /* facts for an entry whose repo path doesn't exist → repoExists == false, merge == .unknown */ }
```

- [ ] **Step 2: Run to verify they fail** — `--filter GitWorktrees` → compile errors.
- [ ] **Step 3: Implement.** Commands (all `git -C <dir> …`, 10 s timeout): `worktree list --porcelain`; `status --porcelain --untracked-files=normal` (line count → `uncommitted`, nil on failure); default refs, first that resolves with `rev-parse --verify --quiet <ref>^{commit}`, locals `main`, `master` and remotes `origin/HEAD`, `origin/main`, `origin/master`; merged if for **any** resolved ref `merge-base --is-ancestor HEAD <ref>` exits 0 → `.ancestor`; else squash check per ref:

```
mb    = git merge-base <ref> HEAD
files = git diff --name-only <mb> HEAD
files empty                                  → .ancestor
git diff --quiet <ref> HEAD -- <files…> == 0 → .squash
```

  else `.notMerged(commitsAhead: rev-list --count <ref>..HEAD, base: <ref short name, "origin/" stripped>)` using the first resolved ref; no ref resolves → `.unknown`. `lastCommit` from `log -1 --format=%ct`. `agent` from `WorktreeAgent.label`. `processesInside`: names of records (not `ownPID`) whose `cwd == path || cwd.hasPrefix(path + "/")`, deduplicated, sorted.
- [ ] **Step 4: Run** — filter passes; full suite passes.
- [ ] **Step 5: Commit** — `feat(worktrees): git probe`.

### Task 3: Discovery walk and leftover agent folders

**Files:**
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/WorktreeDiscovery.swift`
- Test: `Packages/CleanUpCore/Tests/CleanUpCoreTests/WorktreeDiscoveryTests.swift`

**Interfaces:**
- Produces:
  - `public enum WorktreeDiscovery { static let maxDepth = 7; static let skipped: Set<String>; static let protected: [String]; static let agentRoots: [String] }` — `skipped` = `["node_modules", ".Trash", "DerivedData", ".build", "Pods", "Library"]` + names ending `.photoslibrary`; `protected` = `["Documents", "Desktop", "Downloads", "Library/Mobile Documents"]` (relative to home); `agentRoots` = `[".codex/worktrees", ".cursor/worktrees", "conductor/workspaces"]`.
  - `static func repositories(home: URL, includeProtected: Bool) -> [String]` — main repo paths (sorted, unique) owning at least one linked worktree marker found by the walk or in the agent roots (any depth up to 4 below a root).
  - `static func repo(fromGitFile url: URL) -> String?` — reads `gitdir: <…>/.git/worktrees/<name>`, returns the path before `/.git/worktrees/`; nil for submodules (`/.git/modules/`) and anything else.
  - `static func leftoverAgentFolders(home: URL) -> [URL]` — direct children of `.codex/worktrees` and `.cursor/worktrees` with no `.git` within 3 levels and under 1 MB allocated.

- [ ] **Step 1: Write the failing tests** (build a fake home under a temp dir)

```swift
@Test func findsSiblingAndAgentWorktrees() { /* home/Projects/app/.git (dir) + home/Projects/app-fix/.git (file → app/.git/worktrees/app-fix) + home/.codex/worktrees/a/app/.git (file) → repositories == [home/Projects/app] */ }
@Test func submodulesAreNotWorktrees() { /* .git file pointing into .git/modules/x → repo(fromGitFile:) == nil */ }
@Test func skipsNodeModulesAndLibrary() { /* markers inside node_modules and Library are not found */ }
@Test func protectedFoldersOnlyWhenAsked() { /* marker under home/Documents found only with includeProtected: true */ }
@Test func depthLimit() { /* marker 8 levels deep is not found; 7 is */ }
@Test func doesNotFollowSymlinks() { /* home/link -> outside dir containing a marker → not found */ }
@Test func leftoverAgentFolders() { /* .codex/worktrees/old/.codex-worktree-name only → listed; .codex/worktrees/live/app/.git → not listed */ }
```

- [ ] **Step 2: Run to verify they fail** — `--filter WorktreeDiscovery`.
- [ ] **Step 3: Implement** with `FileManager.enumerator(at:includingPropertiesForKeys:options:)` (`.skipsPackageDescendants`, no link following; call `skipDescendants()` for skipped/protected names and when `level > maxDepth`). A `.git` that is a *file* is a marker; a `.git` directory ends descent into that folder's `.git`.
- [ ] **Step 4: Run** — passes; full suite passes.
- [ ] **Step 5: Commit** — `feat(worktrees): discovery`.

### Task 4: Folder sizes and cache

**Files:**
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/FolderSize.swift`
- Test: `Packages/CleanUpCore/Tests/CleanUpCoreTests/FolderSizeTests.swift`

**Interfaces:**
- Produces:
  - `public struct FolderMeasure: Sendable, Equatable, Codable { bytes: Int64; newest: Date? }`
  - `public enum FolderSize { static func measure(_ url: URL) -> FolderMeasure }` — sums `totalFileAllocatedSize` of regular files, counts a symlink as itself (never followed), `newest` = latest `contentModificationDate` seen.
  - `public actor SizeCache { init(maxAge: TimeInterval = 6 * 3600); func measure(_ url: URL, now: Date) -> FolderMeasure }` — reuses an entry while the folder's own mtime and its `.git` file's mtime are unchanged and the entry is younger than `maxAge`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func sumsAllocatedBytes() { /* two 100 KB files → bytes >= 200_000 */ }
@Test func symlinkTargetsAreNotCounted() { /* link to an outside 5 MB file → bytes < 1_000_000 */ }
@Test func newestModification() { /* file touched 2 min ago is `newest` */ }
@Test func cacheReusesUntilFolderChanges() async { /* second measure returns cached; after adding a file at top level, re-measures */ }
```

- [ ] **Step 2: Fail** → **Step 3: Implement** → **Step 4: Pass** (`--filter FolderSize`, then full suite) → **Step 5: Commit** `feat(worktrees): folder sizes`.

### Task 5: Worktree scanner

**Files:**
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/WorktreeScanner.swift`
- Test: `Packages/CleanUpCore/Tests/CleanUpCoreTests/WorktreeScannerTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces:
  - `public struct WorktreeSnapshot: Sendable { date: Date; items: [Item]; trashed: [TrashedWorktree]; var safeBytes: Int64; var keptBytes: Int64; var trashedBytes: Int64 }` (bytes computed from `item.detail["bytes"]` and `verdict`; `TrashedWorktree` from Task 6 — define it in this task's file as a forward-declared Codable struct `{ id: UUID; path: String; repo: String?; storedAdmin: String?; trashURL: String; bytes: Int64; date: Date }` that Task 6 uses).
  - `public actor WorktreeScanner { init(git: GitWorktrees = .init(), home: URL = FileManager.default.homeDirectoryForCurrentUser, sizes: SizeCache = .init()); func scan(processes: [Int32: ProcessInfoRecord], ownPID: Int32, includeProtected: Bool, trashed: [TrashedWorktree], now: Date) async -> WorktreeSnapshot? }` — nil when `git.available()` is false.
  - Items: `Item(id: .worktree(path:), category: .worktrees, name: <folder name>, symbol: "arrow.triangle.branch", judgement: WorktreeJudge.judge(facts, now:), cores: 0, memoryBytes: 0, processes: [], detail: ["path", "repo", "repoName", "branch", "agent", "bytes"])`; one extra item `id: .worktreeLeftovers`, name "Leftover agent folders", verdict `.idle`, fact "N empty folders", when any exist. Sorted by bytes, largest first; items without a measured size sort last with fact "measuring…" (kept).

- [ ] **Step 1: Write the failing tests** (TempRepo inside a fake home)

```swift
@Test func scansSafeAndKeptWorktrees() async throws { /* one merged clean, one dirty → 2 items; first safe; safeBytes > 0; keptBytes > 0 */ }
@Test func sameFolderNameInTwoReposStaysSeparate() async throws { /* two repos each with worktree folder "app" under different parents → 2 items, distinct ids, detail["repoName"] differs */ }
@Test func noGitMeansNoCategory() async { /* GitWorktrees(run:) answering xcode-select with status 2 → scan returns nil */ }
@Test func leftoversBecomeOneItem() async throws { /* two leftover Codex folders → one item id .worktreeLeftovers, fact "2 empty folders" */ }
@Test func mainCheckoutIsNeverAnItem() async throws { /* repo with no worktrees → items empty */ }
```

- [ ] **Step 2: Fail** → **Step 3: Implement** (repos from `WorktreeDiscovery.repositories`, entries from `git.list`, sizes from `sizes.measure`, facts from `git.facts(…, lastChange: measure.newest)`; run per-repo work concurrently, at most 4 at a time) → **Step 4: Pass** → **Step 5: Commit** `feat(worktrees): scanner`.

### Task 6: Trash, Put back, Delete now, permanent removal

**Files:**
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/WorktreeTrash.swift`
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/WorktreeOutcome.swift`
- Test: `Packages/CleanUpCore/Tests/CleanUpCoreTests/WorktreeTrashTests.swift`

**Interfaces:**
- Consumes: `TrashedWorktree`, `GitWorktrees`, `Item` from Tasks 2 and 5.
- Produces:
  - `public actor WorktreeTrash { init(store: URL, git: GitWorktrees = .init(), trashItem: @escaping @Sendable (URL) throws -> URL = { url in var out: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &out); return out! as URL }); var entries: [TrashedWorktree] { get }; func moveToTrash(_ items: [Item], recheck: @Sendable (Item) async -> Judgement) async -> WorktreeOutcome; func removePermanently(_ items: [Item], recheck: @Sendable (Item) async -> Judgement) async -> WorktreeOutcome; func putBack(_ ids: [UUID]) async -> [UUID]; func deleteNow(_ ids: [UUID]) async; func reconcile() async }`
  - Record file: `<store>/trashed-worktrees.json`; stored git admin folders: `<store>/admin/<uuid>`. App passes `store` = `~/Library/Application Support/io.cleanup.CleanUp/Worktrees`.
  - `public struct WorktreeOutcome: Sendable, Equatable { moved: [Item]; skipped: [(Item, String)] (compare by ids); bytes: Int64; permanent: Bool; var title: String; var subtitle: String? }` — title `"Moved N worktrees to the Trash"` (or `"Removed N worktrees"` when permanent; `"Nothing moved"` when none), subtitle `Bytes.gb(bytes)` plus `" · N kept"` when any skipped.

- [ ] **Step 1: Write the failing tests** (TempRepo; `trashItem` closure moves into a temp "Trash" dir)

```swift
@Test func trashMovesFolderAndAdmin() async throws {
    // merged clean worktree → outcome.moved.count == 1; folder gone from its path; exists in fake Trash;
    // `git -C repo worktree list` no longer lists it; its branch can be checked out in the main repo
}
@Test func putBackRestoresWorktree() async throws { /* after trash, putBack → folder back, `worktree list` lists it again, entries empty */ }
@Test func deleteNowRemovesOnlyThoseItems() async throws { /* two trashed, deleteNow(first) → first gone from fake Trash and store; second still there */ }
@Test func recheckSkipsWorktreeThatBecameInUse() async throws { /* recheck returns .inUse "in use by node" → skipped with that reason; folder untouched */ }
@Test func trashMovesSymlinkNotTarget() async throws { /* worktree contains link to outside dir → after trash the outside dir still exists */ }
@Test func putBackRefusesWhenPathIsTaken() async throws { /* new folder created at the original path → putBack returns that id as failed; nothing overwritten */ }
@Test func reconcileHandlesFinderActions() async throws {
    // (a) fake Trash item deleted → reconcile drops the entry and its stored admin folder
    // (b) folder moved back to its path by hand → reconcile restores admin + repair; `worktree list` lists it
}
@Test func permanentRemovalUsesGitAndRefusesDirty() async throws {
    // clean → `git worktree remove` succeeds, outcome.permanent; dirty (recheck says idle but git refuses) → skipped with git's message
}
@Test func recordSurvivesRelaunch() async throws { /* new WorktreeTrash on the same store → entries equal */ }
@Test func outcomeCopy() { /* 120 moved, 208.3 GB, 0 skipped → title "Moved 120 worktrees to the Trash", subtitle "208.3 GB" */ }
```

- [ ] **Step 2: Fail** → **Step 3: Implement.** `moveToTrash` per item: `recheck` must return `.idle` else skip with its `fact`; admin folder = `repo(fromGitFile:)`'s gitdir; move admin to store, then `trashItem(folder)`; if trashing fails, move admin back and record a skip with the error. Leftover item: trash each leftover folder (no admin). `putBack`: refuse if the original path exists; move folder back, admin back, `git -C <repo> worktree repair <path>`. `deleteNow`: `removeItem` on the Trash URL and stored admin; drop entries. `removePermanently`: `git -C <repo> worktree remove <path>` (no `--force`); skip with stderr's first line on non-zero. `reconcile`: see test. Save the record after every change (atomic write).
- [ ] **Step 4: Pass** → **Step 5: Commit** `feat(worktrees): trash and undo`.

### Task 7: App model

**Files:**
- Create: `App/WorktreesModel.swift`
- Create: `Packages/CleanUpCore/Sources/CleanUpCore/Worktrees/WorktreeSelection.swift`
- Modify: `App/AppModel.swift` (own a `WorktreesModel`, call its triggers), `App/CleanUpApp.swift` if needed for environment injection
- Test: `Packages/CleanUpCore/Tests/CleanUpCoreTests/WorktreeSelectionTests.swift`

**Interfaces:**
- Consumes: Tasks 5–6, `KeepList`, `AppModel.Mode`.
- Produces:
  - `public struct WorktreeSelection: Sendable, Equatable { var ticked: Set<ItemIdentity>; mutating func apply(_ s: WorktreeSnapshot, keep: KeepList, quick: Bool); mutating func toggle(_ item: Item); func items(in s: WorktreeSnapshot) -> [Item]; func bytes(in s: WorktreeSnapshot) -> Int64 }` — in quick mode ticks newly safe, not-kept items only (an item the user unticked stays unticked, like `TickController`); always drops ids that are gone or no longer `.idle`.
  - `@MainActor @Observable final class WorktreesModel { var snapshot: WorktreeSnapshot?; var selection: WorktreeSelection; var outcome: WorktreeOutcome?; var isScanning: Bool; var includeProtected: Bool /* key "worktreesIncludeProtected" */; var removePermanently: Bool /* key "worktreesRemovePermanently" */; func refresh(force: Bool) async; func windowOpened() async; func cleanUp() async; func undoLast() async; func deleteNow(_ ids: [UUID]) async; func putBack(_ ids: [UUID]) async }`
  - Refresh rules: at launch; `windowOpened()` refreshes when the last scan is older than 1 hour; a 6-hour timer; `force` after any action. `reconcile()` runs before each scan.
  - `cleanUp` re-checks each ticked item by re-running `GitWorktrees.facts` + `WorktreeJudge.judge` (fresh process table), then `moveToTrash` or `removePermanently` per the setting.

- [ ] **Step 1: Write the failing tests** for `WorktreeSelection` (`quickTicksSafeNotKept`, `untickedStaysUnticked`, `goneOrKeptItemsDrop`, `manualModeTicksNothing`, `bytesSumsTicked`).
- [ ] **Step 2: Fail** → **Step 3: Implement** both → **Step 4:** tests pass; app builds.
- [ ] **Step 5: Commit** `feat(worktrees): app model`.

### Task 8: Views

**Files:**
- Create: `App/Views/StorageBar.swift`, `App/Views/WorktreesSection.swift`
- Modify: `App/Views/MainView.swift` (bar under the mood line; section after the categories), `App/Views/MenuBarPopover.swift` (one compact bar line under the header, opens the window), `App/Views/SettingsView.swift` (two toggles in a "Worktrees" section), `App/Views/ExplainSheet.swift` (worktree "?" text, no "Stop anyway"), `Explain/FallbackTexts.swift` (worktree texts), `App/DebugSnapshot.swift` (render a sample section)

**Interfaces:**
- Consumes: `WorktreesModel` (Task 7), `ItemRow`/`TickCircle`/`IconTile`/`glass` styles.
- Produces: `StorageBar(safe: Int64, kept: Int64, trashed: Int64, compact: Bool)` — full width = sum; green safe, gray kept, green with diagonal stripes for trashed; caption "X GB safe to remove · Y GB kept" (plus " · Z GB in the Trash" when any). `WorktreesSection` — the row (indigo icon, "Worktrees", "N of M ticked", total GB), items with a size bar under each name scaled to the largest item (green if safe, gray if kept), the own button "Clean up N worktrees · X GB" (hidden when nothing ticked), its result card (`WorktreeOutcome` title/subtitle, Undo, "Delete now · frees X GB"), an "In the Trash · X GB" row with Delete now / Put back when entries exist, and `.confirmationDialog` "Delete N worktrees permanently? This can't be undone." before Delete now or a permanent cleanup.
- FallbackTexts for `.worktrees`: what it is "A second checkout of your project that an agent made for one task."; lose "Nothing in git. Files git ignores, like `.env`, go to the Trash with it."

- [ ] **Step 1:** Build the views; render with `-debugSnapshotDir` and look at the PNGs: storage bar, an opened Worktrees section (safe and kept rows with size bars), the result card, the "In the Trash" row, Settings with the two toggles.
- [ ] **Step 2:** Verify by reading the renders: bars proportional, copy exactly as in Global Constraints, kept items untickable and dimmed, main Clean up button label unchanged (cores only).
- [ ] **Step 3:** `xcodebuild -scheme CleanUp -configuration Debug build` and `Release build` with 0 warnings; full `swift test`.
- [ ] **Step 4: Commit** `feat(worktrees): storage bar, section and settings`.

### Task 9: Docs and live check

**Files:**
- Modify: `README.md` (category table row for Worktrees; privacy line "reads and moves only worktree folders, never anything else, and never deletes without Delete now or the permanent setting"; known limitation "squash merges are recognised only when the files still match main")
- Modify: `docs/superpowers/specs/2026-11-02-cleanup-design.md` (under Non-goals: "Exception (2026-11-04): merged, clean git worktrees — see 2026-11-04-worktrees-design.md")

- [ ] **Step 1:** Update both docs.
- [ ] **Step 2: Live read-only check** — run the Debug app with `-debugWorktreeReport YES` (add in `DebugSnapshot.swift`: log item count, safe count, safe/kept bytes, then quit, without cleaning). Compare with the 2026-11-04 survey (138 worktrees, 120 safe, ~208 GB) and explain any difference (e.g. the one-hour rule, squash detection, depth).
- [ ] **Step 3: Commit** `docs: worktrees category`.
