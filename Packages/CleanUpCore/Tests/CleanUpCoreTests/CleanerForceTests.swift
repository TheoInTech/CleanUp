import Foundation
import os
import Testing
@testable import CleanUpCore

/// "Stop anyway" (force) driven through the Cleaner into every real module, with fakes for the
/// commands: force skips the idle checks only, never a safety guard, and never applies to engines.
@Suite struct CleanerForceTests {
    private let probe = SystemProbe(
        processes: { [:] }, sockets: { _ in [] }, frontmostBundleID: { nil }, battery: { nil },
        swap: { (0, 0) }, uptime: { 0 }, freshSampleInterval: .zero
    )

    private func ok() -> CommandResult { CommandResult(status: 0, stdout: "", stderr: "", timedOut: false) }

    @Test func simulators() async {
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let module = SimulatorsModule(
            run: { cmd, args, _ in calls.withLock { $0.append([cmd] + args) }; return self.ok() },
            lastInFront: { _ in nil }, trackingSince: { .distantPast }
        )
        let udid = "10EBDE8C-B5D1-47E1-8B8A-5621F07127FA"
        let inUse = Item.fixtureSimulator(udid: udid, name: "iPhone 18 Pro", verdict: .inUse)
        let cleaner = Cleaner(modules: [module], probe: probe)
        let plain = await cleaner.clean([inUse], ctx: .testContext())
        #expect(plain.skipped.map(\.0) == [inUse.id])
        #expect(calls.withLock { $0 }.isEmpty)
        let forced = await cleaner.clean([inUse], ctx: .testContext(), forced: [inUse.id])
        #expect(forced.stopped == [inUse.id])
        #expect(calls.withLock { $0 } == [["xcrun", "simctl", "shutdown", udid]])
    }

    @Test func simulatorServicesAreNeverForced() async {
        let module = SimulatorsModule(run: { _, _, _ in Issue.record("must not run"); return self.ok() })
        let services = Item.fixture(SimulatorsModule.engineIdentity, category: .simulators, name: "Simulator services", verdict: .inUse)
        let report = await Cleaner(modules: [module], probe: probe).clean([services], ctx: .testContext(), forced: [services.id])
        #expect(report.skipped.map(\.0) == [services.id])
    }

    @Test func containers() async {
        let calls = OSAllocatedUnfairLock<[[String]]>(initialState: [])
        let module = ContainersModule(run: { cmd, args in calls.withLock { $0.append([cmd] + args) }; return self.ok() })
        let busy = Item.fixtureContainer(name: "evone-postgres", verdict: .inUse)
        let cleaner = Cleaner(modules: [module], probe: probe)
        #expect(await cleaner.clean([busy], ctx: .testContext()).skipped.map(\.0) == [busy.id])
        let forced = await cleaner.clean([busy], ctx: .testContext(), forced: [busy.id])
        #expect(forced.stopped == [busy.id])
        #expect(calls.withLock { $0 } == [["docker", "stop", "evone-postgres"]])
    }

    @Test func containerEnginesAreNeverForced() async {
        let module = ContainersModule(
            run: { _, _ in CommandResult(status: 1, stdout: "", stderr: "", timedOut: false) },
            quitApp: { _ in Issue.record("must not quit"); return true }
        )
        let engine = Item.fixtureEngine(verdict: .inUse)
        let report = await Cleaner(modules: [module], probe: probe).clean([engine], ctx: .testContext(), forced: [engine.id])
        #expect(report.stopped.isEmpty)
        #expect(report.skipped.map(\.0) == [engine.id])
    }

    @Test func devServers() async throws {
        let copy = try throwawayCopy(of: "/bin/sleep", named: "forced-dev-server")
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        let process = Process()
        process.executableURL = copy
        process.arguments = ["120"]
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() } }
        let record = try #require(ProcessTable.snapshot()[process.processIdentifier])

        let busy = Item.fixtureDevServer(ref: record.ref, verdict: .inUse)
        let client = SocketInfo(pid: record.pid, state: .established, localPort: 8081, remotePort: 55_000)
        let ctx = ScanContext.testContext(processes: [record.pid: record], sockets: [client])
        let cleaner = Cleaner(modules: [DevServersModule(termGrace: .seconds(2))], probe: probe)
        #expect(await cleaner.clean([busy], ctx: ctx).skipped.map(\.0) == [busy.id])
        #expect(process.isRunning)
        let forced = await cleaner.clean([busy], ctx: ctx, forced: [busy.id])
        #expect(forced.stopped == [busy.id])
        process.waitUntilExit()
        #expect(!process.isRunning)
    }

    @Test func apps() async {
        let quits = OSAllocatedUnfairLock(initialState: 0)
        let module = AppsModule(apps: { [] }, trackingSince: { .distantPast }, terminator: { _ in quits.withLock { $0 += 1 }; return .quit })
        let steam = Item(
            id: .app(bundleID: "com.valvesoftware.steam"), category: .apps, name: "Steam", symbol: "app",
            judgement: Judgement(verdict: .manual, fact: "not used 3 days", signals: []), cores: 0, memoryBytes: 0,
            processes: [], detail: ["bundleID": "com.valvesoftware.steam", "bundlePath": "/Applications/Steam.app", "pid": "4242"]
        )
        let cleaner = Cleaner(modules: [module], probe: probe)
        // Force changes nothing for apps; the frontmost app is never quit, forced or not.
        #expect(await cleaner.clean([steam], ctx: .testContext(frontmost: "com.valvesoftware.steam"), forced: [steam.id]).skipped.map(\.0) == [steam.id])
        #expect(quits.withLock { $0 } == 0)
        #expect(await cleaner.clean([steam], ctx: .testContext(), forced: [steam.id]).stopped == [steam.id])
        #expect(quits.withLock { $0 } == 1)
    }

    @Test func browserTabs() async {
        let tab = Item.fixtureTab()
        let report = await Cleaner(modules: [BrowserTabsModule()], probe: probe).clean([tab], ctx: .testContext(), forced: [tab.id])
        #expect(report.stopped.isEmpty)
        #expect(report.skipped.first?.1 == "open the browser's task manager")
    }

    @Test func restart() async {
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let module = RestartModule(swap: { (0, 0) }, uptime: { 0 }, restarter: { asked.withLock { $0 += 1 }; return nil })
        let advice = Item.fixture(.restart, category: .restart, name: "Restart your Mac", verdict: .advice)
        let report = await Cleaner(modules: [module], probe: probe).clean([advice], ctx: .testContext(), forced: [advice.id])
        #expect(report.skipped.first?.1 == "restart dialog shown")   // the dialog only; the user decides
        #expect(asked.withLock { $0 } == 1)
    }
}
