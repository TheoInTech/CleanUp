# CleanUp — design

A native macOS app that shows, at a glance, what is draining the battery or slowing the Mac, and stops the idle culprits in one tap. Lives in the menu bar, has a desktop widget, and warns on its own. Open source (MIT).

## Why

On 2026-11-01 a MacBook Pro (M5 Max, 36 GB, battery health 93%) was lasting 30–40 minutes on a full charge. The battery was fine. The cause was forgotten background work: 6 booted iOS Simulators (~5.4 cores), Docker Desktop's VM (~1.3 cores, 12 containers, some idle for weeks), a heavy browser tab, stale dev servers (Expo, Next, proxies) left running for up to 19 days, and 22 GB of swap after 19 days without a restart. Load average was ~450. Stopping the idle simulators alone dropped it to ~18.

Finding this took a terminal session with `ps`, `pmset`, `ioreg`, `simctl`, `docker` and `lsof`. CleanUp packages that investigation so anyone can do it in one or two taps, without reading anything.

**Success:** the owner notices drain, clicks the menu bar icon, presses one button, and the Mac is calm again, without ever stopping something that was being used.

## Goals

- Show **what is causing** drain/slowness as a picture first (a ring split by cause), text second.
- **Quick select**: one button stops everything that looks idle. Items that look in use are never pre-ticked.
- **Choose myself**: tick individual items, then one button.
- Every category opens into **individual items**, each judged on its own (some simulators in use, some stale; some containers in use, some stale).
- Every item has **"?"**: what is this, why we think it's idle/in use, and safe to stop? — with a Keep / Stop anyway choice.
- **Menu bar** and **widget** can do the whole job without opening the main window.
- **Warns on its own** when the battery is draining fast and something idle is to blame.
- Uses **Liquid Glass** throughout.
- Uses on-device **Apple Intelligence** (Foundation Models) to write the plain "What is this?" text, free and local.

## Non-goals (v1)

- Deleting files, caches, or "disk cleaning" of any kind. Exception (2026-11-04): merged, clean git worktrees — see 2026-11-04-worktrees-design.md.
- Closing individual browser tabs (browsers are shown read-only with a hint).
- Stopping anything automatically without a tap (warnings only).
- Paid "Pro" features. Not built in v1; the rules engine should not make them hard to add later.
- Mac App Store distribution (impossible: sandboxed apps can't stop other processes).
- Any network access, analytics, accounts or telemetry.

## Anti-goals (failure even if it "works")

- Stopping something that was in use. When unsure, an item counts as **in use** and stays unticked.
- A text-heavy UI. If a screen needs a paragraph, the design is wrong.
- CleanUp itself using noticeable battery or CPU.
- Scareware tone (fake urgency, big red scores, "your Mac is infected"). Calm, honest, specific.
- Only working on the author's setup. It must work on any Mac, with or without Xcode or Docker.

## Decided by the owner

- Main screen layout **A: ring + checklist** (chosen over a "mood face + cause cards" layout).
- Per-item ticks inside each category; no blanket "Stop all" for a category.
- Quick select / Choose myself as a two-way switch above the list.
- "What is this?" and "Safe to stop?" on every item, helped by local Apple Intelligence.
- Automatic warning: yes.
- Liquid Glass look.
- Name: **CleanUp**. Open source.
- Money: free source code; later a paid signed download (pay-what-you-want) plus GitHub Sponsors from day one. Pro tier decided later.

## Screens

Mockups (HTML approximations) are in `.superpowers/brainstorm/*/content/`: `main-screen-v2.html` (A), `menubar-widget.html`, `per-item.html`, `glass.html`.

### Main window
- **Ring** at the top: each colored segment is one category's share of CPU in use; gray is everything else. Center shows **time left** on battery (e.g. "35m"), or **cores busy** when plugged in.
- **Status line** under the ring, one of three states with an emoji: 😌 All good / 🟠 Busy / 🔥 Draining fast.
- **Switch**: Quick select | Choose myself.
- **Category rows** (colored to match the ring): icon, name, "4 of 6 ticked", cores used, chevron. Tick circle is full / half / empty.
- **Item rows** when opened: tick, name, one short fact ("idle 2 days", "Orbit opened 13 min ago"), badge 💤 idle (green) or ● in use (blue), "?".
- **Button** at the bottom names what it does: "Clean up 15 idle · frees 6.1 cores". Disabled with "Nothing idle" when empty.
- After cleanup: ring animates down, a short toast "Stopped 15 · Undo" (Undo where possible, see Actions).

### "?" sheet (per item)
Icon + name + one-line context; **What is this?** (1–2 sentences); **Why we think it's idle / in use** as 2–3 signal rows; **Safe to stop?** badge (✓ Safe / ⚠︎ Probably being used / ✕ Don't stop) + one line on what you'd lose; buttons **Keep** and **Stop** (or **Stop anyway**). Small "✨ Explained by Apple Intelligence, on this Mac" when AI wrote it.

### Menu bar
Icon is a tiny ring colored green/amber/red plus minutes left on battery (just the ring when plugged in). Clicking opens a glass popover: mini ring + status, top 3 categories with their ticks, **Clean up** button, "Open full view".

### Widget
- **Small:** ring with status emoji, time left, **Clean up** button (interactive). Calm state turns green with 😌 "All good".
- **Medium:** adds the top 3 categories beside the ring.

### Warning
System notification, at most once per 30 minutes, only when draining fast for several minutes **and** idle items explain a meaningful share of it. Title "Battery draining fast · 35 min left", body names the idle culprits ("4 idle simulators + 6 old containers"), actions **Clean up 10 idle** (works from the notification) and **Show me**.

## Categories (v1)

Each category is a self-contained module: detect items, measure each item's CPU/memory, judge idle vs in use with visible reasons, stop/undo. Categories with nothing to show are hidden (no Xcode → no Simulators row).

| Category | Detect | Idle signals (all must hold to be "idle") | Stop | Undo |
|---|---|---|---|---|
| **Simulators** | `xcrun simctl list devices booted -j`; attribute CPU by matching processes whose path contains the device UDID, plus that device's runtime processes | no app launched in the device recently; its window not frontmost; no other process referencing the UDID (e.g. `xcodebuild -destination id=…`, a test runner, an agent helper); low CPU from its apps | `simctl shutdown <udid>` | `simctl boot` |
| **Containers** (Docker Desktop, OrbStack, Colima via `docker`) | `docker ps` + `docker stats --no-stream` | near-zero CPU; no established connections to its published ports; network traffic flat between samples; running a long time | `docker stop` | `docker start` |
| **Dev servers** | processes listening on TCP whose executable is a dev runtime (node, bun, deno, python, ruby, go binaries, java, php…), not inside an app bundle; show project folder name from cwd | no established connections recently; running > a few hours; or orphaned (parent shell gone) | SIGTERM to its process group, SIGKILL after a grace period | none (show the command so the user can rerun) |
| **Apps** | regular GUI apps (NSWorkspace) | shown as "not used for X h" but **never pre-ticked** (see below) | normal quit (`terminate`, which lets the app ask to save) | relaunch |
| **Browser tabs** | browser renderer processes with high CPU | read-only: always "check" | none; "?" tells you to open the browser's task manager (e.g. Shift+Esc in Chromium) | — |
| **Restart needed** | swap used vs total, uptime | read-only advice when swap is nearly full or uptime is very long | button opens the normal macOS Restart dialog (never restarts silently) | — |

The safe/idle verdict always comes from these rules, never from the AI. Thresholds are the builder's call but must lean toward "in use".

**Apps are never pre-ticked (owner decided).** Quick select, the widget and the notification never quit apps. Apps can only be ticked by hand in the main window or menu bar popover, so a "Save changes?" dialog always appears in front of the user.

**Engines are items too (owner decided).** When every container is stopped (or would be, after this cleanup), the container engine itself shows as its own item, e.g. "Docker Desktop · idle engine" (also OrbStack, Colima), which can be ticked and quit. Same for leftover CoreSimulator services once no simulator is booted. This keeps "frees X cores" honest. Undo = relaunch the engine.

**"Keep" is remembered (owner decided).** Tapping Keep adds the item to an "Always kept" list that Quick select never ticks again; the list lives in Settings, where each entry can be removed. Each item needs a stable identity: simulator UDID, container name, dev server project folder + command, app bundle ID.

**Signals combine with AND in every category (my call).** "Orphaned" for a dev server is a supporting reason shown in "?", never enough on its own: a `nohup` server with a live client is in use.

**Never shown / never stopped:** system processes (root-owned, `/System`, `/usr/libexec`, etc.), Finder, Dock, WindowServer, CleanUp itself, the frontmost app.

## Battery and load

- Drain watts from the battery's instantaneous amperage × voltage (IOKit `AppleSmartBattery`); time left from the system's estimate, smoothed.
- Status: 🔥 when projected time left is short **and** drain stays high for several minutes; 🟠 when load is high; 😌 otherwise. Exact thresholds are the builder's call.
- Cores busy = total CPU% / 100. Swap from `vm.swapusage`. Battery health (max capacity, cycles) shown only inside a small info popover, to tell users "it's not your battery".

## Apple Intelligence

- Foundation Models, on-device only. Input: the item's facts (category, name, executable path, project folder, signals). Output (guided generation): a 1–2 sentence plain "What is this?" and one line "what you'd lose". Cached per item identity.
- If Apple Intelligence is unavailable, use built-in short texts per category and for well-known executables. The app must be fully usable without it.

## Constraints

- **macOS 26 or newer** (Liquid Glass + Foundation Models). Apple Silicon first; Intel Macs supported if cheap.
- Native Swift + SwiftUI app, `MenuBarExtra` + window, WidgetKit extension, App Intents for widget/notification buttons, starts at login (`SMAppService`). My call.
- **Not sandboxed** main app (it has to run `docker`/`xcrun` and signal processes). The widget extension *is* sandboxed, so it reads a snapshot shared through an App Group and asks the running main app to do the cleanup.
- **CleanUp must be light:** read process data through system APIs (libproc/sysctl), not by spawning `ps`; refresh often only while a window/popover is open, slowly in the background; every external command (`docker`, `xcrun`) runs off the main thread with a timeout. During the incident, plain `ps`/`simctl` calls took 30+ seconds under load, so nothing may block the UI.
- SF Symbols in colored tiles instead of emoji for item icons (emoji only for the three status moods). My call.
- **Building from source (my call):** works with a free Apple ID "Personal Team". The Team ID lives in one xcconfig file contributors edit; the App Group uses the team-prefixed form (`<TEAMID>.cleanup`), which macOS allows without a paid account. If the widget can't load (e.g. unsigned build), the menu bar and window still work fully.
- MIT license, README with screenshots, build-from-source instructions, GitHub Sponsors link in About. Signed + notarized DMG is a later step (needs the owner's Apple Developer account).

## Left to the builder

Exact thresholds and sampling intervals; ring animation; color for each category; copy for built-in fallback texts; how the widget triggers the main app; test strategy (rules engine and per-category judges should be unit-testable with recorded snapshots, e.g. the 2026-11-01 incident).
