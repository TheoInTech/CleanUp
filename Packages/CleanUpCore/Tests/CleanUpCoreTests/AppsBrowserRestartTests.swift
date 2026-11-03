import Foundation
import Testing
@testable import CleanUpCore

/// Records what an injected closure was called with, so tests can prove "never called" as well as "called".
private actor CallLog<T: Sendable> {
    private(set) var entries: [T] = []
    func add(_ entry: T) { entries.append(entry) }
}

private let trackingStart = now.addingTimeInterval(-.days(1))

private func appsModule(
    _ apps: [RunningAppInfo],
    trackingSince: Date = trackingStart,
    terminator: @escaping AppTerminator = { _ in .quit },
    opener: @escaping @Sendable (URL) async -> Bool = { _ in true }
) -> AppsModule {
    AppsModule(apps: { apps }, trackingSince: { trackingSince }, terminator: terminator, opener: opener)
}

// MARK: - Apps

@Suite struct AppsTests {
    @Test func appsAreNeverIdle() async {
        let items = await AppsModule(apps: { [.fixture("com.valvesoftware.steam", lastUsedAgo: .days(3))] }, trackingSince: { trackingStart }).scan(.testContext())
        #expect(items.count == 1)
        #expect(items.allSatisfy { $0.judgement.verdict == .manual })
    }

    @Test func frontmostAndFinderExcluded() async {
        let items = await AppsModule(apps: { [.fixture("com.apple.finder"), .fixture("com.brave.Browser")] }, trackingSince: { trackingStart })
            .scan(.testContext(frontmost: "com.brave.Browser"))
        #expect(items.isEmpty)
    }

    @Test func dockOwnAppAndSystemAppsExcluded() async {
        let apps: [RunningAppInfo] = [
            .fixture("com.apple.dock"),
            .fixture("io.cleanup.CleanUp"),
            .fixture("com.apple.Maps", path: "/System/Applications/Maps.app"),
            .fixture("com.valvesoftware.steam", pid: 10),
        ]
        let items = await appsModule(apps).scan(.testContext())
        #expect(items.map(\.id) == [.app(bundleID: "com.valvesoftware.steam")])
    }

    @Test func ownPIDIsExcluded() async {
        let items = await appsModule([.fixture("com.example.me", pid: getpid())]).scan(.testContext())
        #expect(items.isEmpty)
    }

    @Test func factSaysHowLongUnused() async {
        let items = await appsModule([.fixture("com.valvesoftware.steam", lastUsedAgo: .hours(5))]).scan(.testContext())
        #expect(items.first?.judgement.fact == "not used 5 h")
    }

    @Test func noActivationRecordedMeansSinceCleanUpStarted() async {
        // Launched before tracking began (here: no process info at all), never seen in front.
        let items = await appsModule([.fixture("com.valvesoftware.steam", pid: 10)]).scan(.testContext())
        #expect(items.first?.judgement.fact == "not used since CleanUp started")

        let old = ProcessInfoRecord.fixture(pid: 10, path: "/Applications/steam.app/Contents/MacOS/steam", startedAgo: .days(9))
        let withProcess = await appsModule([.fixture("com.valvesoftware.steam", pid: 10)])
            .scan(.testContext(processes: processTable(old)))
        #expect(withProcess.first?.judgement.fact == "not used since CleanUp started")
    }

    @Test func launchedAfterTrackingStartedCountsFromLaunch() async {
        let recent = ProcessInfoRecord.fixture(pid: 10, path: "/Applications/steam.app/Contents/MacOS/steam", startedAgo: .hours(2))
        let items = await appsModule([.fixture("com.valvesoftware.steam", pid: 10)])
            .scan(.testContext(processes: processTable(recent)))
        #expect(items.first?.judgement.fact == "not used 2 h")
    }

    @Test func activationBeforeRelaunchDoesNotCountAsUse() async {
        let recent = ProcessInfoRecord.fixture(pid: 10, path: "/Applications/steam.app/Contents/MacOS/steam", startedAgo: .hours(2))
        let items = await appsModule([.fixture("com.valvesoftware.steam", lastUsedAgo: .days(4), pid: 10)])
            .scan(.testContext(processes: processTable(recent)))
        #expect(items.first?.judgement.fact == "not used 2 h")
    }

    @Test func coresAndMemoryCoverOnlyProcessesInsideTheBundle() async throws {
        let main = ProcessInfoRecord.fixture(pid: 10, path: "/Applications/steam.app/Contents/MacOS/steam", residentBytes: 100)
        let helper = ProcessInfoRecord.fixture(pid: 11, path: "/Applications/steam.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", residentBytes: 50)
        let lookalike = ProcessInfoRecord.fixture(pid: 12, path: "/Applications/steam.app2/Contents/MacOS/steam", residentBytes: 7)
        let items = await appsModule([.fixture("com.valvesoftware.steam", pid: 10)]).scan(.testContext(
            processes: processTable(main, helper, lookalike), cpu: [10: 30, 11: 20, 12: 400]
        ))
        let item = try #require(items.first)
        #expect(abs(item.cores - 0.5) < 0.0001)
        #expect(item.memoryBytes == 150)
        #expect(item.processes.map(\.pid) == [10, 11])
        #expect(item.detail["bundleID"] == "com.valvesoftware.steam")
        #expect(item.detail["pid"] == "10")
    }

    @Test func containerEnginesAndTheSimulatorAreNotApps() async {
        // Quitting them stops containers or simulators: they are judged as engines, with their guards.
        let apps: [RunningAppInfo] = [
            .fixture("com.docker.docker", name: "Docker Desktop", path: "/Applications/Docker.app", pid: 20),
            .fixture("dev.kdrag0n.MacVirt", name: "OrbStack", path: "/Applications/OrbStack.app", pid: 21),
            .fixture("com.apple.iphonesimulator", name: "Simulator", path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app", pid: 22),
            .fixture("com.valvesoftware.steam", pid: 10),
        ]
        let items = await appsModule(apps).scan(.testContext())
        #expect(items.map(\.id) == [.app(bundleID: "com.valvesoftware.steam")])
    }

    @Test func busyTabsListedOnTheirOwnAreNotCountedAgainInTheirBrowser() async throws {
        let bundle = "/Applications/Brave Browser.app"
        let main = ProcessInfoRecord.fixture(pid: 30, path: bundle + "/Contents/MacOS/Brave Browser")
        let busyTab = ProcessInfoRecord.fixture(pid: 31, name: "Brave Browser Helper (Renderer)",
                                                path: bundle + "/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)")
        let quietTab = ProcessInfoRecord.fixture(pid: 32, name: "Brave Browser Helper (Renderer)", path: busyTab.path)
        let ctx = ScanContext.testContext(processes: processTable(main, busyTab, quietTab), cpu: [30: 10, 31: 140, 32: 20])
        let tabs = await BrowserTabsModule().scan(ctx)
        #expect(tabs.map(\.id) == [.browserTab(pid: 31)])
        let brave = try #require(await appsModule([.fixture("com.brave.Browser", name: "Brave Browser", path: bundle, pid: 30)]).scan(ctx).first)
        #expect(abs(brave.cores - 0.3) < 0.0001)   // the browser and its quiet tab; the busy tab is its own row
    }

    // MARK: stop / undo

    private func steamItem(_ module: AppsModule) async throws -> Item {
        let main = ProcessInfoRecord.fixture(pid: 10, path: "/Applications/steam.app/Contents/MacOS/steam", startedAgo: .days(2))
        return try #require(await module.scan(.testContext(processes: processTable(main))).first)
    }

    @Test func stopTerminatesTheVerifiedApp() async throws {
        let log = CallLog<AppTerminationRequest>()
        let module = appsModule([.fixture("com.valvesoftware.steam", pid: 10)], terminator: { await log.add($0); return .quit })
        let item = try await steamItem(module)
        let result = await module.stop(item, ctx: .testContext())
        #expect(result == .stopped(UndoToken(identity: item.id, action: "open", arguments: ["/Applications/steam.app"])))
        let calls = await log.entries
        #expect(calls.count == 1)
        #expect(calls.first?.pid == 10)
        #expect(calls.first?.bundleID == "com.valvesoftware.steam")
        #expect(calls.first?.launchedAt == now.addingTimeInterval(-.days(2)))
    }

    @Test func stopFailsWhenAppDoesNotQuit() async throws {
        let module = appsModule([.fixture("com.valvesoftware.steam", pid: 10)], terminator: { _ in .didntQuit })
        let result = await module.stop(try await steamItem(module), ctx: .testContext())
        #expect(result == .failed(reason: "didn't quit"))
    }

    @Test func stopSkipsWhenPidNowBelongsToSomethingElse() async throws {
        let module = appsModule([.fixture("com.valvesoftware.steam", pid: 10)], terminator: { _ in .mismatch })
        let result = await module.stop(try await steamItem(module), ctx: .testContext())
        #expect(result == .skipped(reason: "already gone"))
        let gone = appsModule([.fixture("com.valvesoftware.steam", pid: 10)], terminator: { _ in .notRunning })
        #expect(await gone.stop(try await steamItem(gone), ctx: .testContext()) == .skipped(reason: "already gone"))
    }

    @Test func stopNeverQuitsTheFrontmostApp() async throws {
        let log = CallLog<AppTerminationRequest>()
        let module = appsModule([.fixture("com.valvesoftware.steam", pid: 10)], terminator: { await log.add($0); return .quit })
        let item = try await steamItem(module)
        let result = await module.stop(item, ctx: .testContext(frontmost: "com.valvesoftware.steam"))
        #expect(result == .skipped(reason: "\(item.name) is in front"))
        #expect(await log.entries.isEmpty)
    }

    @Test func stopRefusesProtectedApps() async {
        let log = CallLog<AppTerminationRequest>()
        let module = appsModule([], terminator: { await log.add($0); return .quit })
        for bundleID in ["com.apple.finder", "com.apple.dock", "io.cleanup.CleanUp", "com.docker.docker", "dev.kdrag0n.MacVirt", "com.apple.iphonesimulator"] {
            let item = Item(
                id: .app(bundleID: bundleID), category: .apps, name: "X", symbol: "app",
                judgement: Judgement(verdict: .manual, fact: "", signals: []), cores: 0, memoryBytes: 0,
                processes: [], detail: ["bundleID": bundleID, "bundlePath": "/Applications/X.app", "pid": "10"]
            )
            guard case .skipped = await module.stop(item, ctx: .testContext()) else {
                Issue.record("\(bundleID) was not skipped")
                continue
            }
        }
        #expect(await log.entries.isEmpty)
    }

    @Test func defaultTerminatorNeverTouchesAMismatchedProcess() async {
        let terminate = AppsModule.nativeTerminator(timeout: .milliseconds(200))
        // Our own pid with a bundle id that is not ours: must be refused, not quit.
        let own = await terminate(AppTerminationRequest(pid: getpid(), bundleID: "com.example.not-this-process", launchedAt: nil))
        #expect(own == .mismatch || own == .notRunning)
        // A pid that cannot exist.
        let missing = await terminate(AppTerminationRequest(pid: Int32.max - 1, bundleID: "com.example.nope", launchedAt: nil))
        #expect(missing == .notRunning)
    }

    @Test func undoReopensTheApp() async {
        let log = CallLog<URL>()
        let module = appsModule([], opener: { await log.add($0); return true })
        let token = UndoToken(identity: .app(bundleID: "x"), action: "open", arguments: ["/Applications/steam.app"])
        #expect(await module.undo(token))
        #expect(await log.entries == [URL(fileURLWithPath: "/Applications/steam.app")])
        #expect(!(await module.undo(UndoToken(identity: .app(bundleID: "x"), action: "boot", arguments: ["/Applications/steam.app"]))))
        #expect(!(await module.undo(UndoToken(identity: .app(bundleID: "x"), action: "open", arguments: []))))
    }
}

@Suite struct ActivationLogTests {
    /// A suite name nothing has used before, so each test starts empty.
    private func freshSuite() -> String { "io.cleanup.tests.\(UUID().uuidString)" }

    @Test func recordsAndPersistsActivations() async {
        let suite = freshSuite()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let first = ActivationLog(suiteName: suite, now: now)
        #expect(await first.lastActivated("com.a") == nil)
        await first.record(bundleID: "com.a", at: now.addingTimeInterval(-100))
        await first.record(bundleID: "com.a", at: now.addingTimeInterval(-50))
        #expect(await first.lastActivated("com.a") == now.addingTimeInterval(-50))

        let second = ActivationLog(suiteName: suite, now: now.addingTimeInterval(500))
        #expect(await second.lastActivated("com.a") == now.addingTimeInterval(-50))
        #expect(await second.trackingSince == now)   // fixed on first run, not reset by later launches
        #expect(await second.launchedAt == now.addingTimeInterval(500))   // this launch only: no gap behind it
    }

    @Test func olderActivationDoesNotOverwriteNewer() async {
        let suite = freshSuite()
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let log = ActivationLog(suiteName: suite, now: now)
        await log.record(bundleID: "com.a", at: now)
        await log.record(bundleID: "com.a", at: now.addingTimeInterval(-10))
        #expect(await log.lastActivated("com.a") == now)
    }
}

// MARK: - Browser tabs

@Suite struct BrowserTabsTests {
    @Test func browserTabsAreCheckOnly() async {
        let m = BrowserTabsModule()
        #expect(await m.stop(.fixtureTab(), ctx: .testContext()) == .skipped(reason: "open the browser's task manager"))
    }

    private func renderer(_ pid: Int32, _ bundle: String, _ helper: String) -> ProcessInfoRecord {
        .fixture(pid: pid, path: "/Applications/\(bundle).app/Contents/Frameworks/X/\(helper).app/Contents/MacOS/\(helper)")
    }

    @Test func busyRendererOfEveryFamilyIsListed() async {
        let table = processTable(
            renderer(1, "Brave Browser", "Brave Browser Helper (Renderer)"),
            renderer(2, "Google Chrome", "Google Chrome Helper (Renderer)"),
            renderer(3, "Microsoft Edge", "Microsoft Edge Helper (Renderer)"),
            renderer(4, "Arc", "Arc Helper (Renderer)"),
            .fixture(pid: 5, path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent"),
            .fixture(pid: 6, path: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/plugin-container"),
            .fixture(pid: 7, name: "Web Content", path: "/Applications/Firefox.app/Contents/MacOS/plugin-container.app/Contents/MacOS/Web Content")
        )
        let items = await BrowserTabsModule().scan(.testContext(processes: table, cpu: [1: 140, 2: 90, 3: 60, 4: 51, 5: 200, 6: 75, 7: 80]))
        #expect(items.map(\.name) == ["Brave tab", "Chrome tab", "Edge tab", "Arc tab", "Web page (WebKit)", "Firefox tab", "Firefox tab"])
        #expect(items.allSatisfy { $0.judgement.verdict == .check && $0.category == .browserTabs })
        #expect(items.first?.id == .browserTab(pid: 1))
        #expect(items.first?.judgement.fact == "using 1.4 cores")
        #expect(abs((items.first?.cores ?? 0) - 1.4) < 0.0001)
    }

    @Test func electronAppsAreNotBrowsers() async {
        let table = processTable(
            renderer(1, "Code", "Code Helper (Renderer)"),
            renderer(2, "Slack", "Slack Helper (Renderer)"),
            renderer(3, "Discord", "Discord Helper (Renderer)"),
            // A known browser name, but not inside that browser's own app.
            .fixture(pid: 4, path: "/tmp/evil/Slack.app/Contents/Frameworks/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)")
        )
        let items = await BrowserTabsModule().scan(.testContext(processes: table, cpu: [1: 300, 2: 300, 3: 300, 4: 300]))
        #expect(items.isEmpty)
    }

    @Test func webKitPageIsNamedNeutrally() async throws {
        let webkit = ProcessInfoRecord.fixture(pid: 5, path: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent")
        let item = try #require(await BrowserTabsModule().scan(.testContext(processes: processTable(webkit), cpu: [5: 200])).first)
        #expect(item.name == "Web page (WebKit)")
        #expect(item.judgement.signals.contains { $0.text == "A WebKit page, possibly from another app" })
    }

    @Test func quietRenderersAndOtherHelpersAreIgnored() async {
        let table = processTable(
            renderer(1, "Brave Browser", "Brave Browser Helper (Renderer)"),
            renderer(2, "Brave Browser", "Brave Browser Helper (GPU)"),
            renderer(3, "Brave Browser", "Brave Browser Helper"),
            .fixture(pid: 4, path: "/Applications/Steam.app/Contents/MacOS/steam")
        )
        let items = await BrowserTabsModule().scan(.testContext(processes: table, cpu: [1: 50, 2: 300, 3: 300, 4: 300]))
        #expect(items.isEmpty)
        #expect(await BrowserTabsModule().scan(.testContext(processes: table, cpu: [:])).isEmpty)
    }

    @Test func itemCarriesMemoryAndProcessRef() async throws {
        let record = ProcessInfoRecord.fixture(
            pid: 1, path: "/Applications/Arc.app/Contents/Frameworks/Arc Helper (Renderer).app/Contents/MacOS/Arc Helper (Renderer)",
            startedAgo: .hours(3), residentBytes: 123
        )
        let item = try #require(await BrowserTabsModule().scan(.testContext(processes: processTable(record), cpu: [1: 100])).first)
        #expect(item.memoryBytes == 123)
        #expect(item.processes == [record.ref])
    }
}

// MARK: - Restart

@Suite struct RestartTests {
    @Test func incidentNeedsRestart() {
        #expect(RestartModule.shouldAdviseRestart(swapUsed: 22_424 << 20, swapTotal: 23_552 << 20, uptime: 19 * 86_400))
        #expect(!RestartModule.shouldAdviseRestart(swapUsed: 1 << 30, swapTotal: 4 << 30, uptime: 2 * 86_400))
    }

    @Test func thresholdsAreStrict() {
        let gib: UInt64 = 1 << 30
        // Rule 1: > 75% of swap AND > 8 GiB.
        #expect(RestartModule.shouldAdviseRestart(swapUsed: 9 * gib, swapTotal: 10 * gib, uptime: 0))
        #expect(!RestartModule.shouldAdviseRestart(swapUsed: 8 * gib, swapTotal: 8 * gib, uptime: 0))        // not > 8 GiB
        #expect(!RestartModule.shouldAdviseRestart(swapUsed: 15 * gib, swapTotal: 20 * gib, uptime: 0))     // exactly 75%
        #expect(!RestartModule.shouldAdviseRestart(swapUsed: 7 * gib, swapTotal: 8 * gib, uptime: 0))       // high ratio, small
        // Rule 2: uptime > 14 days AND > 50% of swap.
        #expect(RestartModule.shouldAdviseRestart(swapUsed: 3 * gib, swapTotal: 4 * gib, uptime: 15 * 86_400))
        #expect(!RestartModule.shouldAdviseRestart(swapUsed: 3 * gib, swapTotal: 4 * gib, uptime: 14 * 86_400))
        #expect(!RestartModule.shouldAdviseRestart(swapUsed: 2 * gib, swapTotal: 4 * gib, uptime: 30 * 86_400))
        // No swap at all.
        #expect(!RestartModule.shouldAdviseRestart(swapUsed: 0, swapTotal: 0, uptime: 90 * 86_400))
    }

    private func module(
        used: UInt64 = 22_424 << 20, total: UInt64 = 23_552 << 20, uptime: TimeInterval = 19 * 86_400,
        restarter: @escaping @Sendable () async -> String? = { nil }
    ) -> RestartModule {
        RestartModule(swap: { (used, total) }, uptime: { uptime }, restarter: restarter)
    }

    @Test func adviceItemForTheIncident() async throws {
        let item = try #require(await module().scan(.testContext()).first)
        #expect(item.id == .restart)
        #expect(item.category == .restart)
        #expect(item.judgement.verdict == .advice)
        #expect(item.judgement.fact == "swap 22 GB · up 19 days")
        #expect(item.processes.isEmpty)
    }

    @Test func noItemWhenMachineIsFine() async {
        #expect(await module(used: 1 << 30, total: 4 << 30, uptime: 2 * 86_400).scan(.testContext()).isEmpty)
    }

    @Test func stopShowsTheRestartDialogOnly() async throws {
        let log = CallLog<Bool>()
        let m = module(restarter: { await log.add(true); return nil })
        let item = try #require(await m.scan(.testContext()).first)
        #expect(await m.stop(item, ctx: .testContext()) == .skipped(reason: "restart dialog shown"))
        #expect(await log.entries.count == 1)
    }

    @Test func stopReportsScriptFailure() async throws {
        let m = module(restarter: { "not allowed" })
        let item = try #require(await m.scan(.testContext()).first)
        #expect(await m.stop(item, ctx: .testContext()) == .failed(reason: "not allowed"))
    }

    @Test func undoIsNotPossible() async {
        #expect(!(await module().undo(UndoToken(identity: .restart, action: "x", arguments: []))))
    }
}
