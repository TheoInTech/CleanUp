import Foundation
import os
import Testing
@testable import CleanUpCore

private let t0 = fixedNow

/// A fake machine behind a `SystemProbe`: the clock, the battery, and per-pid CPU use are set by the test.
private final class FakeMachine: Sendable {
    struct State: Sendable {
        var now = fixedNow
        var battery: BatteryReading?
        /// Cores each pid keeps busy (2.0 = two full cores).
        var load: [Int32: Double] = [:]
        var cpuNanos: [Int32: UInt64] = [:]
        var frontmost: String?
        var swap: (used: UInt64, total: UInt64) = (0, 0)
    }

    let state = OSAllocatedUnfairLock(initialState: State())

    /// Moves the clock forward, accumulating CPU time for every loaded pid.
    func advance(_ interval: TimeInterval) {
        state.withLock { s in
            s.now = s.now.addingTimeInterval(interval)
            for (pid, cores) in s.load { s.cpuNanos[pid, default: 0] += UInt64(cores * interval * 1_000_000_000) }
        }
    }

    var probe: SystemProbe {
        SystemProbe(
            now: { self.state.withLock { $0.now } },
            processes: {
                self.state.withLock { s in
                    Dictionary(uniqueKeysWithValues: s.load.keys.map { pid in
                        (pid, ProcessInfoRecord(
                            pid: pid, ppid: 1, pgid: pid, uid: getuid(), name: "p\(pid)", path: "/x/p\(pid)", arguments: [],
                            cwd: nil, startTime: fixedNow.addingTimeInterval(-.hours(1)),
                            cpuTimeNanos: s.cpuNanos[pid] ?? 0, residentBytes: 0
                        ))
                    })
                }
            },
            sockets: { pids in pids.map { SocketInfo(pid: $0, state: .listen, localPort: 8000 + Int($0), remotePort: nil) } },
            frontmostBundleID: { self.state.withLock { $0.frontmost } },
            battery: { self.state.withLock { $0.battery } },
            swap: { self.state.withLock { $0.swap } },
            uptime: { .days(2) },
            ownPID: 1
        )
    }
}

/// Every engine suite nests here, so `--filter EngineTests` runs them all.
@Suite struct EngineTests {}

extension EngineTests {
    // MARK: - Selection

    @Suite struct SelectionTests {
        @Test func quickSelectTicksOnlyIdleNotKeptNotApps() {
            let s = Snapshot.incident()          // 4 idle + 2 in-use sims, 6 idle containers, Steam app
            var keep = KeepList(defaults: .ephemeral()); keep.add(.container(name: "evone-routing"), name: "evone-routing")
            let sel = Selection.quick(s, keep: keep)
            #expect(sel.ticked.contains(.simulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF")))
            #expect(!sel.ticked.contains(.simulator(udid: "10EBDE8C-B5D1-47E1-8B8A-5621F07127FA")))
            #expect(!sel.ticked.contains(.container(name: "evone-routing")))
            #expect(!sel.ticked.contains { $0.rawValue.hasPrefix("app:") })
        }

        @Test func untickingContainerUnticksEngine() {
            let s = Snapshot.incidentAllContainersIdle(); var sel = Selection.quick(s, keep: .empty)
            #expect(sel.ticked.contains(.engine(name: "Docker Desktop")))
            sel.toggle(s.item(.container(name: "evone-postgres")), in: s)
            #expect(!sel.ticked.contains(.engine(name: "Docker Desktop")))
        }

        @Test func quickSelectOnIncidentTicksElevenIdleItems() {
            let s = Snapshot.incident()
            let sel = Selection.quick(s, keep: .empty)
            // 4 idle simulators + 7 idle containers; the engine stays unticked (evone-postgres is in use).
            #expect(sel.count == 11)
            #expect(!sel.ticked.contains(.engine(name: "Docker Desktop")))
            #expect(!sel.ticked.contains(.container(name: "evone-postgres")))
            #expect(abs(sel.freedCores(in: s) - (1.2 + 1.1 + 1.0 + 0.9 + 0.7)) < 1e-9)
        }

        @Test func quickSelectNeverTicksAppsEvenWhenIdle() {
            let app = Item.fixture(.app(bundleID: "com.example.idle"), category: .apps, verdict: .idle, cores: 1)
            let s = Snapshot.with([CategorySummary(id: .apps, items: [app])])
            #expect(Selection.quick(s, keep: .empty).ticked.isEmpty)
        }

        @Test func keptContainerKeepsItsEngineUnticked() {
            let s = Snapshot.incidentAllContainersIdle()
            var keep = KeepList.empty; keep.add(.container(name: "evone-routing"), name: "evone-routing")
            let sel = Selection.quick(s, keep: keep)
            #expect(!sel.ticked.contains(.container(name: "evone-routing")))
            #expect(!sel.ticked.contains(.engine(name: "Docker Desktop")))
            #expect(sel.ticked.contains(.container(name: "evone-postgres")))
        }

        @Test func keptEngineIsNotTicked() {
            let s = Snapshot.incidentAllContainersIdle()
            var keep = KeepList.empty; keep.add(.engine(name: "Docker Desktop"), name: "Docker Desktop")
            let sel = Selection.quick(s, keep: keep)
            #expect(!sel.ticked.contains(.engine(name: "Docker Desktop")))
            #expect(sel.ticked.contains(.container(name: "evone-postgres")))
        }

        @Test func tickingEngineIsRefusedWhileOneOfItsContainersIsUnticked() {
            let s = Snapshot.incidentAllContainersIdle()
            var sel = Selection.quick(s, keep: .empty)
            let engine = s.item(.engine(name: "Docker Desktop"))
            sel.toggle(s.item(.container(name: "evone-routing")), in: s)      // untick a container → engine unticked
            sel.toggle(engine, in: s)                                          // refused
            #expect(!sel.ticked.contains(engine.id))
            sel.toggle(s.item(.container(name: "evone-routing")), in: s)      // tick it back
            sel.toggle(engine, in: s)                                          // now allowed
            #expect(sel.ticked.contains(engine.id))
        }

        @Test func containerOfAnotherEngineDoesNotBlock() {
            let docker = Item.fixtureContainer(name: "a", engine: "Docker Desktop")
            let orb = Item.fixtureContainer(name: "b", engine: "OrbStack")
            let engine = Item.fixtureEngine("Docker Desktop")
            let s = Snapshot.with([CategorySummary(id: .containers, items: [docker, orb, engine])])
            var sel = Selection(ticked: [docker.id])
            sel.toggle(engine, in: s)
            #expect(sel.ticked.contains(engine.id))
            sel.toggle(orb, in: s); sel.toggle(orb, in: s)   // tick then untick the OrbStack container
            #expect(sel.ticked.contains(engine.id))
        }

        @Test func containerWithoutEngineBlocksEveryEngine() {
            let unknown = Item.fixtureContainer(name: "mystery", engine: nil)
            let engine = Item.fixtureEngine("OrbStack")
            let s = Snapshot.with([CategorySummary(id: .containers, items: [unknown, engine])])
            var sel = Selection(ticked: [])
            sel.toggle(engine, in: s)
            #expect(!sel.ticked.contains(engine.id))
            #expect(Selection.quick(s, keep: .empty).ticked == [unknown.id, engine.id])
            var all = Selection.quick(s, keep: .empty)
            all.toggle(unknown, in: s)
            #expect(all.ticked.isEmpty)
        }

        @Test func simulatorServicesEngineHasNoContainerRule() {
            let services = Item.fixture(.engine(name: "simulator-services"), category: .simulators, verdict: .idle, cores: 0.4)
            let container = Item.fixtureContainer(name: "c", engine: nil)
            let s = Snapshot.with([
                CategorySummary(id: .simulators, items: [services]),
                CategorySummary(id: .containers, items: [container]),
            ])
            var sel = Selection(ticked: [])
            sel.toggle(services, in: s)
            #expect(sel.ticked.contains(services.id))
        }

        @Test func inUseAndAdviceItemsCannotBeTicked() {
            let s = Snapshot.incident()
            var sel = Selection(ticked: [])
            sel.toggle(s.item(.simulator(udid: "10EBDE8C-B5D1-47E1-8B8A-5621F07127FA")), in: s)
            #expect(sel.ticked.isEmpty)
            sel.toggle(s.item(.app(bundleID: "com.valvesoftware.steam")), in: s)   // apps are ticked by hand
            #expect(sel.ticked == [.app(bundleID: "com.valvesoftware.steam")])
        }

        @Test func categoryTickState() {
            let s = Snapshot.incident()
            var sel = Selection.quick(s, keep: .empty)
            // 4 of 6 ticked (2 in use): half, matching "4 of 6 ticked", never full.
            #expect(sel.state(of: .simulators, in: s) == .some)
            #expect(sel.state(of: .apps, in: s) == .none)
            sel.toggle(s.item(.simulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF")), in: s)
            #expect(sel.state(of: .simulators, in: s) == .some)
            #expect(sel.state(of: .devServers, in: s) == .none)
        }

        @Test func categoryTickStateIsFullOnlyWhenEveryItemIsTicked() {
            let idle: [Item] = [
                .fixtureSimulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF", name: "A", verdict: .idle, cores: 1),
                .fixtureSimulator(udid: "1AC8D351-981F-439F-9A2D-AB2DF85DE448", name: "B", verdict: .idle, cores: 1),
            ]
            let s = Snapshot.with([CategorySummary(id: .simulators, items: idle)])
            var sel = Selection.quick(s, keep: .empty)
            #expect(sel.state(of: .simulators, in: s) == .all)
            sel.toggle(idle[0], in: s)
            #expect(sel.state(of: .simulators, in: s) == .some)
            sel.toggle(idle[1], in: s)
            #expect(sel.state(of: .simulators, in: s) == .none)
        }

        @Test func busyBrowserTabsCannotBeTicked() {
            let tab = Item.fixtureTab()
            let s = Snapshot.with([CategorySummary(id: .browserTabs, items: [tab])])
            var sel = Selection(ticked: [])
            sel.toggle(tab, in: s)
            #expect(sel.ticked.isEmpty)
            #expect(!Selection.isTickable(tab))
            var carried = Selection(ticked: [tab.id])
            carried.reconcile(with: s)
            #expect(carried.ticked.isEmpty)
        }

        @Test func reconcileUnticksTheEngineWhenANewContainerAppears() {
            let before = Snapshot.incidentAllContainersIdle()
            var sel = Selection.quick(before, keep: .empty)
            #expect(sel.ticked.contains(.engine(name: "Docker Desktop")))
            let containers = before.categories.first { $0.id == .containers }!.items + [.fixtureContainer(name: "brand-new", cores: 0.2)]
            let after = Snapshot.with(before.categories.map { $0.id == .containers ? CategorySummary(id: .containers, items: containers) : $0 })
            sel.reconcile(with: after)
            #expect(!sel.ticked.contains(.engine(name: "Docker Desktop")))
            #expect(sel.ticked.contains(.container(name: "evone-routing")))
        }

        @Test func reconcileDropsGoneAndNowInUseTicks() {
            let before = Snapshot.incident()
            var sel = Selection.quick(before, keep: .empty)
            #expect(sel.count == 11)
            // Two idle simulators: one shut down, one now in use.
            let sims: [Item] = before.categories[0].items
                .filter { $0.id != .simulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF") }
                .map { $0.id == .simulator(udid: "1AC8D351-981F-439F-9A2D-AB2DF85DE448")
                    ? .fixtureSimulator(udid: "1AC8D351-981F-439F-9A2D-AB2DF85DE448", name: "Orbit Duo Layout QA", verdict: .inUse, cores: 1.1) : $0 }
            let after = Snapshot.with([CategorySummary(id: .simulators, items: sims)] + before.categories.dropFirst())
            sel.reconcile(with: after)
            #expect(sel.count == 9)
            #expect(!sel.ticked.contains(.simulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF")))
            #expect(!sel.ticked.contains(.simulator(udid: "1AC8D351-981F-439F-9A2D-AB2DF85DE448")))
            #expect(abs(sel.freedCores(in: after) - (1.0 + 0.9 + 0.7)) < 1e-9)
            #expect(sel.count == after.allItems.filter { sel.ticked.contains($0.id) }.count)
        }

        @Test func freedCoresIgnoresTicksNotInTheSnapshot() {
            let s = Snapshot.incident()
            let sel = Selection(ticked: [.simulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF"), .container(name: "gone")])
            #expect(sel.freedCores(in: s) == 1.2)
            #expect(sel.count == 2)
        }
    }

    // MARK: - Keep list

    @Suite struct KeepListTests {
        @Test func persistsInTheGivenDefaults() {
            let defaults = UserDefaults.ephemeral()
            var keep = KeepList(defaults: defaults)
            keep.add(.container(name: "evone-routing"), name: "evone-routing")
            keep.add(.simulator(udid: "X"), name: "iPhone Duo")

            let reloaded = KeepList(defaults: defaults)
            #expect(reloaded.contains(.container(name: "evone-routing")))
            #expect(reloaded.entries.map(\.name) == ["evone-routing", "iPhone Duo"])
            #expect(reloaded.entries.map(\.id) == [.container(name: "evone-routing"), .simulator(udid: "X")])

            var again = reloaded
            again.remove(.container(name: "evone-routing"))
            #expect(!KeepList(defaults: defaults).contains(.container(name: "evone-routing")))
            #expect(KeepList(defaults: defaults).contains(.simulator(udid: "X")))
        }

        @Test func copiesDoNotClobberEachOther() {
            let defaults = UserDefaults.ephemeral()
            var app = KeepList(defaults: defaults)
            var menu = KeepList(defaults: defaults)     // loaded before the app's addition
            app.add(.container(name: "a"), name: "a")
            menu.add(.container(name: "b"), name: "b")
            #expect(KeepList(defaults: defaults).entries.map(\.name) == ["a", "b"])
            app.remove(.container(name: "a"))
            #expect(KeepList(defaults: defaults).entries.map(\.name) == ["b"])
            #expect(menu.contains(.container(name: "a")))   // a copy's in-memory view refreshes on its next write
        }

        @Test func emptyIsInMemory() {
            var keep = KeepList.empty
            keep.add(.app(bundleID: "a"), name: "A")
            #expect(keep.contains(.app(bundleID: "a")))
            #expect(!KeepList.empty.contains(.app(bundleID: "a")))
        }
    }

    // MARK: - Status

    @Suite struct StatusTests {
        @Test func drainingFastNeedsSustainedDrain() {
            let b = BatteryReading(onBattery: true, percent: 40, drainWatts: 95, minutesLeft: 35, healthPercent: 93, cycleCount: 221)
            #expect(StatusCalculator.mood(battery: b, coresBusy: 10.5, drainHistory: Array(repeating: 95, count: 5)) == .drainingFast)
            #expect(StatusCalculator.mood(battery: b, coresBusy: 10.5, drainHistory: [95, 10, 95, 95, 95]) == .busy)
        }

        @Test func desktopMacNeverDrainingFast() {
            #expect(StatusCalculator.mood(battery: nil, coresBusy: 12, drainHistory: []) == .busy)
        }

        @Test func drainingFastNeedsLowTimeLeftAndEnoughSamples() {
            let plenty = BatteryReading(onBattery: true, percent: 90, drainWatts: 30, minutesLeft: 120, healthPercent: 93, cycleCount: 1)
            #expect(StatusCalculator.mood(battery: plenty, coresBusy: 1, drainHistory: Array(repeating: 30, count: 5)) == .allGood)
            let low = BatteryReading(onBattery: true, percent: 20, drainWatts: 30, minutesLeft: 119, healthPercent: 93, cycleCount: 1)
            #expect(StatusCalculator.mood(battery: low, coresBusy: 1, drainHistory: Array(repeating: 20, count: 5)) == .drainingFast)
            #expect(StatusCalculator.mood(battery: low, coresBusy: 1, drainHistory: [30]) == .allGood)      // one reading isn't sustained
            #expect(StatusCalculator.mood(battery: low, coresBusy: 1, drainHistory: [30, 30]) == .drainingFast)   // coverage is the caller's job
            #expect(StatusCalculator.mood(battery: low, coresBusy: 1, drainHistory: Array(repeating: 19.9, count: 5)) == .allGood)
            let unknown = BatteryReading(onBattery: true, percent: 20, drainWatts: 30, minutesLeft: nil, healthPercent: 93, cycleCount: 1)
            #expect(StatusCalculator.mood(battery: unknown, coresBusy: 1, drainHistory: Array(repeating: 30, count: 5)) == .allGood)
            let plugged = BatteryReading(onBattery: false, percent: 20, drainWatts: 30, minutesLeft: 30, healthPercent: 93, cycleCount: 1)
            #expect(StatusCalculator.mood(battery: plugged, coresBusy: 1, drainHistory: Array(repeating: 30, count: 5)) == .allGood)
        }

        @Test func busyFromFourCores() {
            #expect(StatusCalculator.mood(battery: nil, coresBusy: 4, drainHistory: []) == .busy)
            #expect(StatusCalculator.mood(battery: nil, coresBusy: 3.99, drainHistory: []) == .allGood)
        }
    }

    // MARK: - Scanner

    @Suite struct ScannerTests {
        @Test func scannerSurvivesHangingCategory() async {
            let scanner = Scanner(modules: [HangingModule(id: .simulators), StubModule(id: .devServers, items: [.fixtureDevServer()])], categoryTimeout: .milliseconds(200))
            let snap = await scanner.scan(runExternal: true)
            #expect(snap.categories.map(\.id) == [.devServers])
        }

        @Test func timedOutCategoryKeepsItsPreviousItems() async throws {
            let machine = FakeMachine()
            let sim = Item.fixtureSimulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF", name: "iPhone Duo", verdict: .idle, cores: 1)
            let scanner = Scanner(
                modules: [HangingModule(id: .simulators, items: [sim], answeredScans: 1), StubModule(id: .devServers, items: [.fixtureDevServer()])],
                categoryTimeout: .milliseconds(200), probe: machine.probe
            )
            let first = await scanner.scan(runExternal: true)
            #expect(first.categories.map(\.id) == [.simulators, .devServers])
            let clock = ContinuousClock()
            let started = clock.now
            let second = await scanner.scan(runExternal: true)
            #expect(clock.now - started < .seconds(3))
            #expect(second.categories.map(\.id) == [.simulators, .devServers])
            let stale = try #require(second.categories.first?.items.first)
            #expect(stale.id == sim.id)
            #expect(stale.judgement.verdict == .inUse)
            #expect(stale.judgement.fact == "couldn't check")
            #expect(stale.judgement.signals.last == Signal(kind: .neutral, text: "Couldn't check just now"))
            #expect(Selection.quick(second, keep: .empty).ticked.isEmpty == false)        // the dev server is fresh
            #expect(!Selection.quick(second, keep: .empty).ticked.contains(sim.id))       // the stale simulator isn't
        }

        @Test func lateResultFromAnOlderContextIsNotFresh() async throws {
            let sim = Item.fixtureSimulator(udid: "U", name: "S", verdict: .idle, cores: 1)
            let scanner = Scanner(
                modules: [SlowModule(id: .simulators, items: [sim], delays: [0.3])],
                categoryTimeout: .milliseconds(150), probe: FakeMachine().probe
            )
            let first = await scanner.scan(runExternal: true)          // times out, nothing earlier to show
            #expect(first.categories.isEmpty)
            try await Task.sleep(for: .milliseconds(300))               // the first scan's answer is in by now
            let second = await scanner.scan(runExternal: true)
            #expect(second.categories.first?.items.first?.judgement.verdict == .inUse)   // judged on scan 1's context
            let third = await scanner.scan(runExternal: true)          // a fresh call for this context answers at once
            #expect(third.categories.first?.items == [sim])
        }

        @Test func onlyIdleVerdictsAreDowngraded() {
            let app = Item.fixture(.app(bundleID: "a"), category: .apps, verdict: .manual)
            #expect(Scanner.unchecked(app) == app)
            let idle = Item.fixtureContainer(name: "c")
            #expect(Scanner.unchecked(idle).judgement.verdict == .inUse)
            #expect(Scanner.unchecked(idle).detail == idle.detail)
        }

        @Test func emptyCategoriesAndUnadvisedRestartAreOmitted() async {
            let notAdvice = Item.fixture(.restart, category: .restart, verdict: .inUse)
            let scanner = Scanner(
                modules: [StubModule(id: .apps), StubModule(id: .restart, items: [notAdvice])],
                probe: FakeMachine().probe
            )
            #expect(await scanner.scan(runExternal: true).categories.isEmpty)

            let advice = Item.fixture(.restart, category: .restart, verdict: .advice)
            let advised = Scanner(modules: [StubModule(id: .restart, items: [advice])], probe: FakeMachine().probe)
            #expect(await advised.scan(runExternal: true).categories.map(\.id) == [.restart])
        }

        @Test func categoriesComeInDisplayOrder() async {
            let scanner = Scanner(
                modules: [
                    StubModule(id: .apps, items: [.fixture(.app(bundleID: "a"), category: .apps, verdict: .manual)]),
                    StubModule(id: .simulators, items: [.fixtureSimulator(udid: "U", name: "S", verdict: .idle, cores: 0)]),
                ],
                probe: FakeMachine().probe
            )
            #expect(await scanner.scan(runExternal: true).categories.map(\.id) == [.simulators, .apps])
        }

        @Test func modulesShareOneContextWithRunExternalPassedThrough() async throws {
            let machine = FakeMachine()
            machine.state.withLock { $0.load = [100: 2.0, 200: 0.5]; $0.frontmost = "com.apple.iphonesimulator" }
            let a = StubModule(id: .simulators), b = StubModule(id: .devServers)
            let scanner = Scanner(modules: [a, b], probe: machine.probe)
            _ = await scanner.scan(runExternal: false)
            let ctxA = try #require(a.log.contexts.first)
            let ctxB = try #require(b.log.contexts.first)
            #expect(ctxA.runExternal == false)
            #expect(ctxA.now == ctxB.now)
            #expect(Set(ctxA.processes.keys) == [100, 200])
            #expect(Set(ctxA.sockets.map(\.pid)) == [100, 200])
            #expect(ctxA.frontmostBundleID == "com.apple.iphonesimulator")
            #expect(ctxA.ownPID == 1)
            #expect(ctxA.cpu.isEmpty)    // first refresh: no CPU delta yet
        }

        @Test func coresBusyIsTheSumOfAllCPU() async {
            let machine = FakeMachine()
            machine.state.withLock { $0.load = [100: 2.0, 200: 0.5, 300: 8.0] }
            let scanner = Scanner(modules: [], probe: machine.probe)
            _ = await scanner.scan(runExternal: true)
            machine.advance(10)
            let snap = await scanner.scan(runExternal: true)
            #expect(abs(snap.coresBusy - 10.5) < 0.01)
            #expect(snap.mood == .busy)
            #expect(snap.date == fixedNow.addingTimeInterval(10))
            #expect(snap.uptime == .days(2))
        }

        @Test func drainingFastOnlyAfterFiveMinutesOfHeavyDrain() async {
            let machine = FakeMachine()
            machine.state.withLock { $0.battery = .incident(); $0.load = [100: 1] }
            let scanner = Scanner(modules: [], probe: machine.probe)

            // Five quick refreshes in a row are not five minutes of drain.
            for _ in 0..<5 {
                #expect(await scanner.scan(runExternal: true).mood != .drainingFast)
                machine.advance(5)
            }
            // Background refreshes every 60 s: drain is sustained once samples cover the 5-minute window.
            var moods: [Mood] = []
            for _ in 0..<5 {
                machine.advance(60)
                moods.append(await scanner.scan(runExternal: true).mood)
            }
            #expect(moods.last == .drainingFast)

            // One light minute breaks it.
            machine.state.withLock { $0.battery = BatteryReading(onBattery: true, percent: 40, drainWatts: 8, minutesLeft: 35, healthPercent: 93, cycleCount: 221) }
            machine.advance(60)
            #expect(await scanner.scan(runExternal: true).mood != .drainingFast)
        }

        @Test func pluggingInClearsDrainHistory() async {
            let machine = FakeMachine()
            machine.state.withLock { $0.battery = .incident() }
            let scanner = Scanner(modules: [], probe: machine.probe)
            for _ in 0..<6 { _ = await scanner.scan(runExternal: true); machine.advance(60) }
            #expect(await scanner.scan(runExternal: true).mood == .drainingFast)
            machine.state.withLock { $0.battery = .incident(onBattery: false) }
            machine.advance(60)
            #expect(await scanner.scan(runExternal: true).mood == .allGood)
            machine.state.withLock { $0.battery = .incident() }
            machine.advance(60)
            #expect(await scanner.scan(runExternal: true).mood == .allGood)
        }
    }

    // MARK: - Cleaner

    @Suite struct CleanerTests {
        @Test func cleanerCountsOnlySuccesses() async {
            let c = Cleaner(modules: [StubModule(id: .containers, results: [.stopped(nil), .failed(reason: "timeout")])])
            let r = await c.clean([.fixtureContainer(cores: 1.0), .fixtureContainer(cores: 0.5)], ctx: .testContext())
            #expect(r.stopped.count == 1); #expect(r.failed.count == 1); #expect(r.freedCores == 1.0)
        }

        @Test func enginesStopAfterTheirContainers() async {
            let order = OSAllocatedUnfairLock<[ItemIdentity]>(initialState: [])
            let containers = StubModule(id: .containers, items: [.fixtureEngine()], order: order)   // fresh listing: engine, no containers
            let sims = StubModule(id: .simulators, order: order)
            let services = Item.fixture(.engine(name: "simulator-services"), category: .simulators)
            let sim = Item.fixtureSimulator(udid: "U", name: "S", verdict: .idle, cores: 1)
            let items: [Item] = [.fixtureEngine(), services, .fixtureContainer(name: "a"), sim, .fixtureContainer(name: "b")]
            let report = await Cleaner(modules: [containers, sims], probe: FakeMachine().probe).clean(items, ctx: .testContext())

            let stopped = order.withLock { $0 }
            let engine = stopped.firstIndex(of: .engine(name: "Docker Desktop"))!
            #expect(engine > stopped.firstIndex(of: .container(name: "a"))!)
            #expect(engine > stopped.firstIndex(of: .container(name: "b"))!)
            #expect(stopped.firstIndex(of: services.id)! > stopped.firstIndex(of: sim.id)!)
            #expect(containers.log.stopped == [.container(name: "a"), .container(name: "b"), .engine(name: "Docker Desktop")])
            #expect(report.stopped.count == 5)
        }

        @Test func engineIsSkippedWhenOneOfItsContainersWasNotStopped() async {
            let containers = StubModule(id: .containers, results: [.stopped(nil), .skipped(reason: "now has 1 connection")])
            let items: [Item] = [.fixtureContainer(name: "a"), .fixtureContainer(name: "b"), .fixtureEngine()]
            let report = await Cleaner(modules: [containers], probe: FakeMachine().probe).clean(items, ctx: .testContext())
            #expect(report.stopped == [.container(name: "a")])
            #expect(report.skipped.map(\.0) == [.container(name: "b"), .engine(name: "Docker Desktop")])
            #expect(!containers.log.stopped.contains(.engine(name: "Docker Desktop")))
        }

        @Test func otherEnginesContainersDoNotHoldAnEngineBack() async {
            let orb = Item.fixtureContainer(name: "orb", engine: "OrbStack")
            let containers = StubModule(id: .containers, items: [orb, .fixtureEngine("Docker Desktop")], results: [.failed(reason: "x")])
            let items: [Item] = [orb, .fixtureEngine("Docker Desktop")]
            let report = await Cleaner(modules: [containers], probe: FakeMachine().probe).clean(items, ctx: .testContext())
            #expect(report.stopped == [.engine(name: "Docker Desktop")])
        }

        // Quitting an engine stops every container in it, so the containers are listed afresh first.

        @Test func directEngineStopIsSkippedWhileAContainerIsRunning() async throws {
            let machine = FakeMachine()
            machine.state.withLock { $0.now = fixedNow.addingTimeInterval(42) }
            let running = Item.fixtureContainer(name: "evone-postgres", verdict: .inUse)
            let containers = StubModule(id: .containers, items: [running, .fixtureEngine()])
            let report = await Cleaner(modules: [containers], probe: machine.probe).clean([.fixtureEngine()], ctx: .testContext())
            #expect(report.stopped.isEmpty)
            #expect(report.skipped.map(\.0) == [.engine(name: "Docker Desktop")])
            #expect(report.skipped.first?.1 == "a container is still running")
            #expect(containers.log.stopped.isEmpty)
            let listing = try #require(containers.log.contexts.first)
            #expect(listing.runExternal)
            #expect(listing.now == fixedNow.addingTimeInterval(42))   // a fresh context, not the one passed in
        }

        @Test func forcedEngineIsStillSkippedWhileAContainerIsRunning() async {
            let running = Item.fixtureContainer(name: "evone-postgres", verdict: .inUse)
            let containers = StubModule(id: .containers, items: [running, .fixtureEngine()])
            let engine = Item.fixtureEngine()
            let report = await Cleaner(modules: [containers], probe: FakeMachine().probe)
                .clean([engine], ctx: .testContext(), forced: [engine.id])
            #expect(report.stopped.isEmpty)
            #expect(report.skipped.first?.1 == "a container is still running")
            #expect(containers.log.stopped.isEmpty)
        }

        @Test func forcedIDsReachTheirModuleAndNothingElseIsForced() async {
            let forced = Item.fixtureContainer(name: "evone-postgres", verdict: .inUse)
            let other = Item.fixtureContainer(name: "evone-routing", verdict: .idle)
            let containers = StubModule(id: .containers)
            _ = await Cleaner(modules: [containers], probe: FakeMachine().probe)
                .clean([forced, other], ctx: .testContext(), forced: [forced.id])
            #expect(containers.log.forced == [forced.id])
            #expect(Set(containers.log.stopped) == [forced.id, other.id])
        }

        @Test func staleQuickSelectionCannotQuitTheEngine() async {
            // The widget ticks from the stored snapshot; a container has started since.
            let stale = Snapshot.incidentAllContainersIdle()
            let ticked = Selection.quick(stale, keep: .empty)
            let items = stale.allItems.filter { ticked.ticked.contains($0.id) && $0.category == .containers }
            #expect(items.contains { $0.id == .engine(name: "Docker Desktop") })
            let containers = StubModule(id: .containers, items: [.fixtureContainer(name: "brand-new", verdict: .inUse), .fixtureEngine()])
            let report = await Cleaner(modules: [containers], probe: FakeMachine().probe).clean(items, ctx: .testContext())
            #expect(report.stopped.count == 8)                                       // the containers in the batch
            #expect(report.skipped.map(\.0) == [.engine(name: "Docker Desktop")])
            #expect(!containers.log.stopped.contains(.engine(name: "Docker Desktop")))
        }

        @Test func secondEngineStartingBlocksTheIdleOne() async {
            // Snapshot: only OrbStack, idle and ticked. Since then Docker Desktop launched and a container
            // started on OrbStack; with two engines up the module tags it "Docker Desktop" and judges both in use.
            let listing: [Item] = [
                .fixtureContainer(name: "new-on-orbstack", engine: "Docker Desktop"),
                .fixtureEngine("Docker Desktop", verdict: .inUse),
                .fixtureEngine("OrbStack", verdict: .inUse),
            ]
            let containers = StubModule(id: .containers, items: listing)
            let staleOrbStack = Item.fixtureEngine("OrbStack", verdict: .idle)
            let report = await Cleaner(modules: [containers], probe: FakeMachine().probe).clean([staleOrbStack], ctx: .testContext())
            #expect(report.stopped.isEmpty)
            #expect(report.skipped.map(\.0) == [.engine(name: "OrbStack")])
            #expect(report.skipped.first?.1 == "couldn't check containers")
            #expect(containers.log.stopped.isEmpty)
        }

        @Test func freshlyInUseEngineIsSkippedEvenWithNoContainerListed() async {
            let containers = StubModule(id: .containers, items: [.fixtureEngine(verdict: .inUse)])
            let report = await Cleaner(modules: [containers], probe: FakeMachine().probe).clean([.fixtureEngine()], ctx: .testContext())
            #expect(report.skipped.first?.1 == "a container is still running")
            #expect(containers.log.stopped.isEmpty)
        }

        @Test func containerWithoutEngineInTheListingBlocksTheEngine() async {
            let containers = StubModule(id: .containers, items: [.fixtureContainer(name: "mystery", engine: nil), .fixtureEngine("OrbStack")])
            let report = await Cleaner(modules: [containers], probe: FakeMachine().probe).clean([.fixtureEngine("OrbStack")], ctx: .testContext())
            #expect(report.skipped.first?.1 == "a container is still running")
        }

        @Test func engineIsSkippedWhenContainersCantBeListed() async {
            // docker didn't answer: the containers module claims nothing, not even the engine.
            let silent = StubModule(id: .containers, items: [])
            let report = await Cleaner(modules: [silent], probe: FakeMachine().probe).clean([.fixtureEngine()], ctx: .testContext())
            #expect(report.skipped.first?.1 == "couldn't check containers")
            #expect(silent.log.stopped.isEmpty)
        }

        @Test func engineIsSkippedWhenTheListingHangs() async {
            let cleaner = Cleaner(modules: [HangingModule(id: .containers)], probe: FakeMachine().probe, engineCheckTimeout: .milliseconds(150))
            let clock = ContinuousClock(), started = clock.now
            let report = await cleaner.clean([.fixtureEngine()], ctx: .testContext())
            #expect(clock.now - started < .seconds(3))
            #expect(report.skipped.first?.1 == "couldn't check containers")
        }

        @Test func simulatorServicesNeedNoContainerListing() async {
            let services = Item.fixture(.engine(name: "simulator-services"), category: .simulators)
            let sims = StubModule(id: .simulators)
            let report = await Cleaner(modules: [sims], probe: FakeMachine().probe).clean([services], ctx: .testContext())
            #expect(report.stopped == [services.id])
        }

        @Test func collectsUndoTokensAndSkips() async {
            let token = UndoToken(identity: .simulator(udid: "U"), action: "boot", arguments: ["U"])
            let sims = StubModule(id: .simulators, results: [.stopped(token), .skipped(reason: "in use")])
            let items: [Item] = [
                .fixtureSimulator(udid: "U", name: "S", verdict: .idle, cores: 1),
                .fixtureSimulator(udid: "V", name: "T", verdict: .idle, cores: 1),
                .fixture(.devServer(cwd: "/p", command: "x"), category: .devServers),   // no module for it
            ]
            let report = await Cleaner(modules: [sims], probe: FakeMachine().probe).clean(items, ctx: .testContext())
            #expect(report.undo == [token])
            #expect(report.stopped == [.simulator(udid: "U")])
            #expect(report.skipped.map(\.0) == [.simulator(udid: "V")])
            #expect(report.failed.map(\.0) == [.devServer(cwd: "/p", command: "x")])
        }

        @Test func cleanBuildsAFreshContext() async throws {
            let machine = FakeMachine()
            machine.state.withLock { $0.load = [4242: 0.1]; $0.frontmost = "com.example.front"; $0.now = fixedNow.addingTimeInterval(99) }
            let sims = StubModule(id: .simulators)
            let cleaner = Cleaner(modules: [sims], probe: machine.probe)
            _ = await cleaner.clean([.fixtureSimulator(udid: "U", name: "S", verdict: .idle, cores: 1)])
            let ctx = try #require(sims.log.contexts.first)
            #expect(Set(ctx.processes.keys) == [4242])
            #expect(ctx.sockets.map(\.pid) == [4242])
            #expect(ctx.frontmostBundleID == "com.example.front")
            #expect(ctx.now == fixedNow.addingTimeInterval(99))
            #expect(ctx.runExternal)
        }

        @Test func noRetryWhenNoEngineCameBack() async {
            let containers = StubModule(id: .containers, undoFailing: [.container(name: "a"), .engine(name: "Docker Desktop")])
            let cleaner = Cleaner(modules: [containers], probe: FakeMachine().probe, undoRetries: 2, undoRetryDelay: .milliseconds(10))
            let failed = await cleaner.undo([
                UndoToken(identity: .container(name: "a"), action: "start", arguments: ["a"]),
                UndoToken(identity: .engine(name: "Docker Desktop"), action: "launch", arguments: ["/Applications/Docker.app"]),
            ])
            #expect(failed.count == 2)
            #expect(containers.log.undone.count == 2)
        }

        @Test func undoRoutesTokensToTheirModulesEnginesFirst() async {
            let order = OSAllocatedUnfairLock<[ItemIdentity]>(initialState: [])
            let containers = StubModule(id: .containers, order: order)
            let sims = StubModule(id: .simulators, order: order)
            let tokens = [
                UndoToken(identity: .container(name: "a"), action: "start", arguments: ["a"]),
                UndoToken(identity: .simulator(udid: "U"), action: "boot", arguments: ["U"]),
                UndoToken(identity: .engine(name: "Docker Desktop"), action: "launch", arguments: ["/Applications/Docker.app"]),
            ]
            let failed = await Cleaner(modules: [containers, sims], probe: FakeMachine().probe).undo(tokens)
            #expect(failed.isEmpty)
            let undone = containers.log.undone.map(\.identity)
            #expect(undone == [.engine(name: "Docker Desktop"), .container(name: "a")])
            #expect(sims.log.undone.map(\.identity) == [.simulator(udid: "U")])
        }

        @Test func failedContainerUndoIsRetriedWhileItsEngineStarts() async {
            let containers = StubModule(id: .containers, undoFailing: [.container(name: "a")])
            let cleaner = Cleaner(modules: [containers], probe: FakeMachine().probe, undoRetries: 2, undoRetryDelay: .milliseconds(10))
            let tokens = [
                UndoToken(identity: .engine(name: "Docker Desktop"), action: "launch", arguments: ["/Applications/Docker.app"]),
                UndoToken(identity: .container(name: "a"), action: "start", arguments: ["a"]),
            ]
            let failed = await cleaner.undo(tokens)
            #expect(failed.map(\.identity) == [.container(name: "a")])
            // engine once, container once plus two retries
            #expect(containers.log.undone.count == 4)
        }
    }

    // MARK: - Drain monitor

    // `shouldWarn` is mutating, which `#expect` can't call inside its own expansion: results are hoisted.
    @Suite struct DrainMonitorTests {
        @Test func pluggedInNeverWarns() {
            var m = DrainMonitor()
            let warned = m.shouldWarn(snapshot: .incident(onBattery: false), idleShare: 0.8, now: .now)
            #expect(!warned)
        }

        @Test func warnsAtMostEvery30Minutes() {
            var m = DrainMonitor(); let s = Snapshot.incident(mood: .drainingFast)
            let first = m.shouldWarn(snapshot: s, idleShare: 0.6, now: t0)
            let after20 = m.shouldWarn(snapshot: s, idleShare: 0.6, now: t0.addingTimeInterval(20 * 60))
            let after31 = m.shouldWarn(snapshot: s, idleShare: 0.6, now: t0.addingTimeInterval(31 * 60))
            #expect(first)
            #expect(!after20)
            #expect(after31)
        }

        @Test func needsAThirdOfTheLoadToBeIdle() {
            var m = DrainMonitor(); let s = Snapshot.incident(mood: .drainingFast)
            let low = m.shouldWarn(snapshot: s, idleShare: 0.29, now: t0)
            #expect(!low)
            #expect(m.lastWarning == nil)
            let enough = m.shouldWarn(snapshot: s, idleShare: 0.3, now: t0)
            #expect(enough)
            #expect(m.lastWarning == t0)
        }

        @Test func busyIsNotDraining() {
            var m = DrainMonitor()
            let warned = m.shouldWarn(snapshot: .incident(mood: .busy), idleShare: 0.9, now: t0)
            #expect(!warned)
        }
    }

    // MARK: - Snapshot store and signal

    @Suite struct SnapshotStoreTests {
        private func tempURL() -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("cleanup-store-\(UUID().uuidString)")
                .appendingPathComponent("snapshot.json")
        }

        @Test func roundTrips() throws {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let snapshot = Snapshot.incident()
            try SnapshotStore.write(snapshot, to: url)
            #expect(SnapshotStore.read(from: url) == snapshot)
            try SnapshotStore.write(.empty, to: url)
            #expect(SnapshotStore.read(from: url) == .empty)
        }

        @Test func readIsNilOnAnyError() throws {
            let url = tempURL()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            #expect(SnapshotStore.read(from: url) == nil)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: url)
            #expect(SnapshotStore.read(from: url) == nil)
        }
    }

    @Suite struct CleanupSignalTests {
        @Test func nameIsExact() {
            #expect(CleanupSignal.name == "io.cleanup.cleanIdle")
        }

        @Test func postReachesObserver() async throws {
            let received = OSAllocatedUnfairLock(initialState: 0)
            let token = CleanupSignal.observe { received.withLock { $0 += 1 } }
            defer { CleanupSignal.cancel(token) }
            CleanupSignal.post()
            let deadline = ContinuousClock.now + .seconds(3)
            while received.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let count = received.withLock { $0 }
            #expect(count >= 1)
        }
    }
}

private extension Snapshot {
    static func with(_ categories: [CategorySummary]) -> Snapshot {
        Snapshot(date: fixedNow, battery: nil, coresBusy: 0, swapUsedBytes: 0, swapTotalBytes: 0, uptime: 0, categories: categories, mood: .allGood)
    }
}

extension EngineTests {
    @Suite struct DrainWarningTests {
        @Test func incidentNamesTheTwoBiggestIdleGroups() throws {
            let s = Snapshot.incident()
            let sel = Selection.quick(s, keep: .empty)
            let warning = try #require(DrainWarning.make(snapshot: s, selection: sel))
            #expect(warning.summary == "4 idle simulators + 7 old containers")
            #expect(warning.idleCount == 11)
            #expect(warning.title == "Battery draining fast · 35 min left")
            #expect(warning.actionTitle == "Clean up 11 idle")
        }

        @Test func engineAddsCoresButIsNotCountedAsAContainer() throws {
            let s = Snapshot.incidentAllContainersIdle()
            let sel = Selection.quick(s, keep: .empty)
            #expect(sel.ticked.contains(.engine(name: "Docker Desktop")))
            let warning = try #require(DrainWarning.make(snapshot: s, selection: sel))
            // 8 containers, not 9: the engine's core counts toward the group but the engine is not a container.
            #expect(warning.summary == "4 idle simulators + 8 old containers")
            #expect(warning.idleCount == 13)
        }

        @Test func singularNouns() throws {
            let sim = Item.fixtureSimulator(cores: 2)
            let box = Item.fixtureContainer(name: "db", cores: 1, engine: nil)
            let s = Snapshot.with([CategorySummary(id: .simulators, items: [sim]), CategorySummary(id: .containers, items: [box])])
            let warning = try #require(DrainWarning.make(snapshot: s, selection: Selection.quick(s, keep: .empty)))
            #expect(warning.summary == "1 idle simulator + 1 old container")
        }

        @Test func onlyTheTopTwoGroupsAreNamed() throws {
            let s = Snapshot.with([
                CategorySummary(id: .simulators, items: [.fixtureSimulator(cores: 1)]),
                CategorySummary(id: .containers, items: [.fixtureContainer(name: "db", cores: 0.5, engine: nil)]),
                CategorySummary(id: .devServers, items: [Item.fixture(.devServer(cwd: "/x", command: "vite"), category: .devServers, name: "vite", verdict: .idle, cores: 2)]),
            ])
            let warning = try #require(DrainWarning.make(snapshot: s, selection: Selection.quick(s, keep: .empty)))
            #expect(warning.summary == "1 old dev server + 1 idle simulator")
            #expect(warning.idleCount == 3)
        }

        @Test func nothingToOfferIsNil() {
            #expect(DrainWarning.make(snapshot: .incident(), selection: Selection()) == nil)
        }

        @Test func titleWithoutMinutes() {
            #expect(DrainWarning(summary: "x", idleCount: 1, minutesLeft: nil).title == "Battery draining fast")
        }

        @Test func idleShareIsFreedCoresOverBusyCores() {
            let s = Snapshot.incident()
            let sel = Selection.quick(s, keep: .empty)
            #expect(abs(DrainWarning.idleShare(of: sel, in: s) - 4.9 / 10.5) < 1e-9)
            #expect(DrainWarning.idleShare(of: Selection(), in: .empty) == 0)   // nothing busy: the 0.1 floor avoids dividing by zero
        }
    }
}
