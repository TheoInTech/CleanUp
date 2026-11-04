# CleanUp — Worktrees (storage cleanup) design

**Status:** approved decisions in place (2026-11-04); ready for the owner's final read.

Adds CleanUp's first storage category: git worktrees that AI coding agents leave behind. Extends the approved design in `2026-11-02-cleanup-design.md`, which listed "deleting files" as a v1 non-goal; this is the one deliberate exception, scoped to worktrees whose work is already merged.

## Why

Agents (Codex, Claude Code, Cursor, Copilot, Antigravity, Conductor and others) create a git worktree per task and rarely remove it. On the owner's Mac a read-only survey (2026-11-04) found **138 worktrees using 247 GB**; about **208 GB** of it was in 120 worktrees that were merged and clean. Each one carries its own dependencies and build output (about 1.8 GB of `node_modules` per worktree in one project; the largest was 14 GB). The owner cleans these up by asking an agent, and trusts it because the work is already merged. CleanUp should do the same check and the cleanup in one tap.

**Success:** the owner opens CleanUp, sees how much disk the worktrees take and how much is safe to remove, presses Clean up, and gets the space back without ever losing work that wasn't merged.

## Goals

- Find **every linked worktree** of the user's repositories, whichever agent made it, including sibling folders created with `git worktree add ../name` (most of them on the owner's Mac: 125 of 138 sat next to their project, not in any agent folder).
- Mark each one **safe to remove** only by the owner's rule: its work is merged and nothing is uncommitted (full test below).
- Show storage **visually**: a storage bar under the ring (A) and a size bar on each worktree row (C).
- **Both removal options** (owner's request): Clean up moves to the Trash (recoverable); the result card offers **Delete now** to free the space permanently; a setting removes permanently by default instead.

## Non-goals

- Deleting branches, local or remote. The branch is always kept.
- Cleaning `node_modules`, build output or caches inside worktrees that stay (possible later).
- Touching the main checkout of a repository, ever.
- Any network access (no GitHub API to check merged pull requests).

## Anti-goals (failure even if it "works")

- Removing a worktree with uncommitted, untracked or unmerged work.
- Removing a worktree an agent, editor or dev server is working in right now.
- Following a symlink out of the worktree or deleting anything outside the worktree's own folder.
- Scanning that slows the Mac (the category refreshes rarely and in the background).
- Claiming space is freed while it sits in the Trash.

## Finding worktrees

1. **Candidate markers:** every `.git` *file* (not folder) under the home folder whose `gitdir:` line points into a repository's `.git/worktrees/<name>`. Prune the walk at `node_modules`, `.Trash`, `Library/Caches`, `DerivedData`, `.build`, `Pods`, app containers and Photos libraries. **Skip the macOS-protected folders (Documents, Desktop, Downloads, iCloud Drive) by default (owner decided)**, so scanning never triggers a privacy prompt; a Settings switch "Also look in Documents and Desktop" adds them, and macOS asks for each when it is turned on. On the owner's Mac this took about 5 s; depth limit 7 (my call). Also always check the known agent roots, whatever the depth: `~/.codex/worktrees`, `~/.cursor/worktrees`, `<repo>/.claude/worktrees`, `<repo>/.worktrees`, `~/conductor/workspaces`.
2. **Confirm with git:** for each main repository found, `git worktree list --porcelain` is the source of truth (catches locked, prunable and detached worktrees). A marker git doesn't list is not offered.
3. **Agent label** (display only, never part of the safety test): from the path (`.codex`, `.cursor`, `.claude`, `.worktrees`, `conductor`) or a branch prefix (`codex/`, `claude/`, `cursor/`, `copilot/`); otherwise none.
4. **Leftover agent folders** (my call): folders in the known agent roots that are no longer worktrees and hold only the agent's marker files (Codex leaves 4 such, Cursor 24 on the owner's Mac) are listed as one item, "Leftover agent folders", safe to remove.
5. Needs a real `git` (Xcode or Command Line Tools). Check `xcode-select -p` before calling `/usr/bin/git`, which would otherwise pop the install dialog; without git the category is hidden.

## Safe to remove (all must hold; anything unknown = keep)

1. **Clean:** `git status --porcelain` is empty, untracked files included.
2. **Merged:** the worktree's HEAD is reachable from the repository's default branch, either local (`main`/`master`) or remote (`origin/HEAD`, else `origin/main`/`origin/master`). Also merged: **squash- or rebase-merged** branches, when every file the branch changed since its merge base is identical on the default branch's tip: `git diff --quiet <default-tip> HEAD -- <files changed in $(git merge-base <default-tip> HEAD)..HEAD>`. If the default branch changed those files again since, it counts as not merged (safe side). Each check passes if it holds against **either** the local or the remote default branch (my call: in both cases the work exists outside the worktree, and the branch is kept).
3. **Not in use:** no running process has its working directory inside the worktree (agents, editors' terminals, dev servers), from the process table CleanUp already reads. Also kept if any file in the worktree changed in the last hour (my call).
4. **Not locked** (`git worktree lock`), and not the repository's main checkout.
5. **Its repository still exists.** A worktree whose repository is gone can't be checked: shown, never ticked.

Each kept worktree shows why, as its fact: "3 uncommitted changes", "2 commits not on main", "in use by node", "locked", "can't check: repository missing".

## The category

- **Row:** "Worktrees", a branch-style icon in its own colour (builder's call, distinct from the five category colours), subtitle "120 of 138 ticked", and **GB instead of cores** on the right. Not part of the CPU ring.
- **Items:** folder name; fact "merged 6 days ago · Codex" (or the reason it's kept); a **size bar (C)** under the name, scaled to the largest worktree, green if safe, gray if kept; size in GB. Sorted largest first.
- **Storage bar (A):** under the mood line in the main window, only when worktrees exist. Its full width is all worktree storage: green = safe to remove, gray = kept, striped green = in the Trash from a cleanup. Caption: "208 GB safe to remove · 39 GB kept". In the menu bar popover, the same bar as one compact line under the header that opens the window (my call).
- **Their own button (owner decided).** The main Clean up button stays about battery and never includes worktrees. The Worktrees row (when open) and the storage bar carry their own button, "Clean up 120 worktrees · 208 GB", with its own result card. Quick select ticks the safe worktrees (they only go when that button is pressed). **Always kept** works per worktree path.
- **"?" sheet:** what it is ("A second checkout of your project that an agent made for one task"), why it's safe or kept (the five checks as signal rows), and what you'd lose: "Nothing in git. Files git ignores, like `.env`, go to the Trash with it." No "Stop anyway" for worktrees that fail the test.
- **Never from the widget or the drain notification.** Those clean up battery drain; removing files always takes a tap in the window or the popover (like Apps).
- **Sizes** are measured in the background (allocated size, not following symlinks), cached per worktree and refreshed when its folder changes; "measuring…" until known.
- **Refresh:** at launch, when the window opens if the last scan is over an hour old, and every 6 hours; low priority. Not on the regular few-second refresh.

## Cleaning up

- **Default: move to the Trash** (`FileManager.trashItem`, keep the resulting URL). Re-check every safety condition first against a fresh look, as the other categories do.
- **Git's record goes with it** (my call): the worktree's admin folder (`<repo>/.git/worktrees/<name>`) is moved into CleanUp's own store (Application Support) at the same time, so git forgets the worktree right away: its branch can be checked out elsewhere, and rescans don't show a "missing folder". Undo puts both back and runs `git worktree repair`.
- **The Trash record lasts** (my call): CleanUp keeps a small file of what it moved (path, repository, admin folder, Trash URL, size, date), so "In the Trash · 208 GB" with **Delete now** and **Put back** stays on the Worktrees row after the result card closes and across relaunches. If the folder is emptied from the Trash elsewhere, CleanUp drops the entry and deletes the stored admin folder. If the user puts a folder back from Finder, the next scan sees its marker pointing at a stored admin folder, restores it and runs `git worktree repair`.
- **Result card:** "Moved 120 worktrees to the Trash · 208 GB", the items, **Undo** (move back from the Trash), and **Delete now · frees 208 GB**.
- **Delete now:** asks once ("Delete 120 worktrees permanently? This can't be undone."), then deletes exactly those items from the Trash and their stored admin folders. Never empties the rest of the Trash.
- **Setting "Remove worktrees permanently"** (off by default): Clean up runs `git worktree remove <path>` (never `--force`) after the same re-check, with the same one-time confirmation. If git refuses, the item is skipped with git's reason.
- **Branches are never deleted.**
- Worktrees on another volume go to that volume's Trash (macOS default); the result card counts them the same.

## Constraints

- Same app, same rules as the rest of CleanUp: Swift/SwiftUI, a new category module in `Packages/CleanUpCore` with a pure, unit-tested judge (facts → verdict), every external command through `CommandRunner` with a timeout, nothing on the main thread.
- Test fixtures must cover: clean+merged, dirty, untracked only, unmerged with commits, squash-merged (equal and since-changed), locked, detached HEAD, process inside, changed in the last hour, missing repository, missing folder, leftover agent folders, symlink pointing outside.
- Update the README (category table, privacy line) and note the exception in the original design's non-goals.

## Left to the builder

The exact walk exclusions and depth, the icon and colour, the scan scheduling details, how the striped "in the Trash" segment fades after Delete now, fallback texts for the "?" sheet, and how sizes are cached.
