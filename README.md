<h1 align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/brand/cleanup-logo-dark.png">
    <img src="docs/brand/cleanup-logo-light.png" alt="CleanUp" width="360">
  </picture>
</h1>

**See what is draining your Mac's battery, and stop the idle culprits in one tap.**
A menu bar app, a window and a widget for macOS. It never touches anything that is in use.

<p align="center">
  <a href="https://github.com/TheoInTech/CleanUp/releases/download/v0.1.0/CleanUp-launch-video.mp4">
    <img src="docs/screenshots/video-poster.png" alt="Watch the 60-second launch video: the ring shows simulators, containers, dev servers and apps draining the battery" width="720">
  </a>
</p>

<p align="center">
  <a href="https://github.com/TheoInTech/CleanUp/releases/latest"><b>Download CleanUp for macOS</b></a> · free and open source
</p>

<p align="center">
  <img src="docs/screenshots/main-window.png" alt="CleanUp main window: a ring split by cause, and a checklist of what is idle" width="300">
</p>

<p align="center">
  <img src="docs/screenshots/menubar-popover.png" alt="Menu bar popover" height="240">
  &nbsp;&nbsp;
  <img src="docs/screenshots/widget-medium-busy.png" alt="Medium widget with a Clean up button" height="240">
</p>

## Why

One day a MacBook Pro lasted 30–40 minutes on a full charge. The battery was fine. Forgotten iOS Simulators, Docker containers and dev servers were burning the CPU in the background. CleanUp does that investigation for you.

## Features

- **A ring first, text second.** Each colour is one cause; the centre shows time left on battery.
- **Quick select** stops everything that looks idle. **Choose myself** lets you tick items one by one.
- **Every item is judged on its own**, and every item has a **?** that says what it is and why CleanUp thinks it is idle or in use.
- **Menu bar and widget** do the whole job without opening the window.
- **Warns on its own** when the battery drains fast and idle items are to blame. It only warns; it never stops anything by itself.

## How CleanUp decides something is idle

Every check must pass. Anything uncertain counts as **in use** and is left unticked.

CleanUp has to watch before it can call anything quiet, so **nothing shows as idle for the first 10–30 minutes** after it starts (and again after the Mac wakes from sleep).

| Category | Idle only when |
|---|---|
| **Simulators** | Booted for over 1 h, no app opened in the last hour, the Simulator app not in front for the last 30 min, its apps under 5% CPU, no debugger attached, and nothing (Xcode build, test runner) refers to it. |
| **Containers** | Up over 6 h, under 1% CPU for 10 quiet minutes, no connections to its ports, under 4 kB of network traffic over that window (Docker's exact byte counters), and no shell, `docker attach` or dev container session in it. The engine itself is quit only after 10 minutes with no container in use, no `docker`/`kubectl` command running and almost no CPU of its own. Docker Desktop (tested); OrbStack and Colima (untested). |
| **Dev servers** | Running over 6 h, under 2% CPU, no connection in the last 30 min, and watched by CleanUp for at least 30 min. |
| **Apps** | Never pre-ticked. Shown as "not used for X h"; only you can say you are done with one. They are asked to quit normally, so they can still offer to save. |
| **Browser tabs** | Read-only. CleanUp shows a runaway tab and points you to the browser's own task manager. It never closes tabs. |
| **Restart** | Advice only, when swap is over 75% full and over 8 GB, or the Mac has been up more than 14 days with swap over half full. The button opens the normal macOS Restart dialog. |

## Install

1. Download **CleanUp-0.1.0.dmg** from the [latest release](https://github.com/TheoInTech/CleanUp/releases/latest).
2. Open it and drag **CleanUp** into **Applications**.
3. Open CleanUp. Because this preview isn't notarized by Apple yet, macOS says it can't verify it. Click **Done**, then go to **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to CleanUp. You only do this once.

CleanUp then lives in your menu bar. To add the widget, right-click the desktop and choose **Edit Widgets**.

A signed download that opens without the warning is the [first sponsorship goal](https://github.com/sponsors/TheoInTech).

## Requirements

- macOS 26 or later, Apple Silicon or Intel
- To build it yourself: Xcode 27

## Build

```sh
brew install xcodegen
git clone https://github.com/TheoInTech/CleanUp.git
cd CleanUp
cp Config/Team.xcconfig.example Config/Team.xcconfig
```

Open `Config/Team.xcconfig` and set `DEVELOPMENT_TEAM` to your Team ID. A free Apple ID works: in Xcode go to **Settings → Accounts**, sign in, and copy the ID of your "Personal Team".

```sh
xcodegen generate
open CleanUp.xcodeproj
```

Press **Run** in Xcode.

> If `DEVELOPMENT_TEAM` is empty, the App Group becomes `.io.cleanup`, the app and the widget cannot share data, and the widget will not load.

## Privacy

No network access, no analytics, no accounts. Everything is read and decided on your Mac.

## Known limitations

- The widget's **Clean up** button does nothing if CleanUp is not running. Open the app once.
- With two container engines running at once (say Docker Desktop and Colima), neither can be quit.
- Warnings need notifications to be allowed in **System Settings → Notifications → CleanUp**.
- The plain-language "What is this?" text uses Apple Intelligence. On a Mac without it, CleanUp falls back to built-in descriptions.

## Contributing

To add a category, implement `CategoryModule` and a pure judge function with tests. `Packages/CleanUpCore/Sources/CleanUpCore/Categories/Simulators.swift` is the reference: facts in, `Judgement` out, no side effects in the judge.

```sh
swift test --package-path Packages/CleanUpCore
```

## Support

CleanUp is free, with no ads, accounts or tracking. If it saved your battery, you can [sponsor the project](https://github.com/sponsors/TheoInTech). The first goal is $10 a month, which covers Apple's developer fee so CleanUp can ship as a signed download anyone can install in one click.

### Sponsors

Thank you to everyone keeping CleanUp free.

<!-- Monthly sponsors at $5 and up are listed here. -->
*No sponsors yet. [Be the first](https://github.com/sponsors/TheoInTech).*

## License

[MIT](LICENSE)
