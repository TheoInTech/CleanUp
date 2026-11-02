import Foundation
import Testing
@testable import CleanUpCore

// MARK: - Judge

@Test func staleSimulatorIsIdle() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .days(2), lastLaunchAgo: nil), now: now)
    #expect(j.verdict == .idle); #expect(j.fact == "idle 2 days")
}
@Test func recentAppLaunchIsInUse() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .hours(3), lastLaunchAgo: .minutes(13), app: "Orbit"), now: now)
    #expect(j.verdict == .inUse); #expect(j.fact == "Orbit opened 13 min ago")
}
@Test func referencedByBuildIsInUse() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .days(2), referencedBy: ["xcodebuild"]), now: now)
    #expect(j.verdict == .inUse); #expect(j.fact == "used by xcodebuild")
}
@Test func frontmostSimulatorAppIsInUse() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .days(2), frontmost: true), now: now)
    #expect(j.verdict == .inUse); #expect(j.fact == "Simulator is in front")
}
@Test func unknownBootTimeIsInUse() {
    #expect(SimulatorJudge.judge(.fixture(bootedAgo: nil), now: now).verdict == .inUse)
}
@Test func recentlyBootedIsInUse() {
    #expect(SimulatorJudge.judge(.fixture(bootedAgo: .minutes(20)), now: now).verdict == .inUse)
}
@Test func oldAppLaunchCountsIdleSinceThatLaunch() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .days(2), lastLaunchAgo: .hours(5)), now: now)
    #expect(j.verdict == .idle); #expect(j.fact == "idle 5 h")
}
@Test func exactlySixtyMinutesIsIdle() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .minutes(60), lastLaunchAgo: .minutes(60)), now: now)
    #expect(j.verdict == .idle)
}
@Test func idleJudgementCarriesIdleSignals() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .days(2)), now: now)
    #expect(!j.signals.isEmpty); #expect(j.signals.allSatisfy { $0.kind != .inUse })
}
@Test func inUseJudgementCarriesInUseSignal() {
    let j = SimulatorJudge.judge(.fixture(bootedAgo: .days(2), referencedBy: ["xcodebuild"]), now: now)
    #expect(j.signals.contains { $0.kind == .inUse })
}

@Test func relativeAgeFormats() {
    #expect(RelativeAge.short(.minutes(13)) == "13 min")
    #expect(RelativeAge.short(.hours(3)) == "3 h")
    #expect(RelativeAge.short(.days(2)) == "2 days")
    #expect(RelativeAge.short(.days(1)) == "1 day")
    #expect(RelativeAge.short(.hours(23.9)) == "23 h")
    #expect(RelativeAge.short(30) == "<1 min")
    #expect(RelativeAge.short(-5) == "<1 min")
}

// MARK: - simctl parsing

@Test func parsesSimctlBootedJSON() throws {
    let devices = try SimulatorsModule.parseBooted(fixtureSimctlJSON)
    #expect(devices.count == 6); #expect(devices.contains { $0.name == "EVOne SE check" })
    #expect(devices.contains { $0.udid == "13CCBF93-1281-497A-B7F3-1B8D2D531B4F" })
}
@Test func parseBootedIgnoresShutdownDevices() throws {
    let json = #"{"devices":{"rt":[{"udid":"A","name":"a","state":"Shutdown"},{"udid":"B","name":"b","state":"Booted"}]}}"#
    #expect(try SimulatorsModule.parseBooted(json).map(\.udid) == ["B"])
}
@Test func parseBootedEmptyAndInvalid() throws {
    #expect(try SimulatorsModule.parseBooted(#"{"devices":{}}"#).isEmpty)
    #expect(throws: (any Error).self) { try SimulatorsModule.parseBooted("not json") }
}

// MARK: - Attribution

private let udidA = "10EBDE8C-B5D1-47E1-8B8A-5621F07127FA"
private let udidB = "31049A9E-927D-49D6-9304-E80B2D6514C3"
private let devices = [(udid: udidA, name: "iPhone 18 Pro"), (udid: udidB, name: "iPhone 17")]
private let home = "/Users/test/Library/Developer/CoreSimulator/Devices/"
private let runtimeRoot = "/Library/Developer/CoreSimulator/Volumes/iOS/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot"

private func simTable() -> [Int32: ProcessInfoRecord] {
    processTable(
        .fixture(pid: 100, name: "launchd_sim", path: runtimeRoot + "/sbin/launchd_sim",
                 arguments: ["launchd_sim", home + udidA + "/data/var/run/launchd_bootstrap.plist"], startedAgo: .days(2), residentBytes: 1_000),
        .fixture(pid: 101, ppid: 100, name: "backboardd", path: runtimeRoot + "/usr/libexec/backboardd", startedAgo: .days(2) - 5, residentBytes: 2_000),
        .fixture(pid: 102, ppid: 101, name: "deep", path: runtimeRoot + "/usr/libexec/deep", startedAgo: .days(2) - 9, residentBytes: 3_000),
        .fixture(pid: 103, ppid: 100, name: "Orbit",
                 path: home + udidA + "/data/Containers/Bundle/Application/AAAA/Orbit.app/Orbit", startedAgo: .minutes(13)),
        .fixture(pid: 200, name: "launchd_sim", path: runtimeRoot + "/sbin/launchd_sim",
                 arguments: ["launchd_sim", home + udidB + "/data/var/run/launchd_bootstrap.plist"], startedAgo: .days(3)),
        .fixture(pid: 300, name: "xcodebuild", path: "/usr/bin/xcodebuild",
                 arguments: ["xcodebuild", "-destination", "id=" + udidB, "build"]),
        .fixture(pid: 400, name: "SimRenderServer", path: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/SimRenderServer")
    )
}

@Test func attributesProcessesByLauncherDescentAndPath() {
    let items = SimulatorsModule.buildItems(devices: devices, ctx: .testContext(processes: simTable(), cpu: [101: 50, 103: 30]))
    let a = items.first { $0.id == .simulator(udid: udidA) }
    #expect(a != nil)
    #expect(Set(a!.processes.map(\.pid)) == [100, 101, 102, 103])
    #expect(abs(a!.cores - 0.8) < 0.0001)
    #expect(a!.memoryBytes >= 6_000)
    #expect(a!.detail["udid"] == udidA)
    #expect(a!.category == .simulators)
}

@Test func bootedAtIsEarliestAndLastLaunchIsLatestAppProcess() {
    let ctx = ScanContext.testContext(processes: simTable())
    let f = SimulatorsModule.facts(udid: udidA, name: "iPhone 18 Pro", ctx: ctx)
    #expect(f.bootedAt == now.addingTimeInterval(-.days(2)))
    #expect(f.lastAppLaunch == now.addingTimeInterval(-.minutes(13)))
    #expect(f.lastAppName == "Orbit")
    #expect(f.referencedBy.isEmpty)
}

@Test func buildReferencesDeviceByDestinationArgument() {
    let ctx = ScanContext.testContext(processes: simTable())
    #expect(SimulatorsModule.facts(udid: udidB, name: "iPhone 17", ctx: ctx).referencedBy == ["xcodebuild"])
    let items = SimulatorsModule.buildItems(devices: devices, ctx: ctx)
    #expect(items.first { $0.id == .simulator(udid: udidB) }?.judgement.verdict == .inUse)
}

@Test func frontmostSimulatorFlagComesFromBundleID() {
    let ctx = ScanContext.testContext(processes: simTable(), frontmost: "com.apple.iphonesimulator")
    #expect(SimulatorsModule.facts(udid: udidA, name: "x", ctx: ctx).simulatorAppFrontmost)
    let other = ScanContext.testContext(processes: simTable(), frontmost: "com.apple.Safari")
    #expect(!SimulatorsModule.facts(udid: udidA, name: "x", ctx: other).simulatorAppFrontmost)
}

@Test func deviceWithNoAttributableProcessesIsInUse() {
    let items = SimulatorsModule.buildItems(devices: [(udid: udidA, name: "x")], ctx: .testContext())
    #expect(items.count == 1); #expect(items[0].judgement.verdict == .inUse)
}

@Test func staleDeviceIsIdleItem() {
    let table = processTable(
        .fixture(pid: 100, name: "launchd_sim", arguments: ["launchd_sim", home + udidA + "/data/var/run/x.plist"], startedAgo: .days(2)),
        .fixture(pid: 101, ppid: 100, name: "backboardd", startedAgo: .days(2))
    )
    let items = SimulatorsModule.buildItems(devices: [(udid: udidA, name: "iPhone 18 Pro")], ctx: .testContext(processes: table))
    #expect(items.first?.judgement.verdict == .idle); #expect(items.first?.judgement.fact == "idle 2 days")
}

// MARK: - Referencing processes

private let frameworkBin = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl"

@Test func simctlSpawnAtFrameworkPathMarksDeviceInUse() {
    // Terminal-run `simctl spawn <UDID> log stream` has no wrapper process; the real simctl lives
    // inside CoreSimulator.framework and must still count as a consumer.
    let table = simTable().merging(processTable(
        .fixture(pid: 600, name: "simctl", path: frameworkBin, arguments: ["simctl", "spawn", udidA, "log", "stream"])
    )) { $1 }
    let ctx = ScanContext.testContext(processes: table)
    #expect(SimulatorsModule.facts(udid: udidA, name: "x", ctx: ctx).referencedBy == ["simctl"])
    let item = SimulatorsModule.buildItems(devices: devices, ctx: ctx).first { $0.id == .simulator(udid: udidA) }
    #expect(item?.judgement.verdict == .inUse)
}

@Test func simulatorServicesMentioningUDIDDoNotCount() {
    let table = simTable().merging(processTable(
        .fixture(pid: 601, name: "com.apple.CoreSimulator.CoreSimulatorService",
                 path: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService",
                 arguments: ["CoreSimulatorService", udidA]),
        .fixture(pid: 602, name: "SimLaunchHost.arm64", path: "/Library/Developer/CoreSimulator/SimLaunchHost.arm64",
                 arguments: ["SimLaunchHost.arm64", udidA])
    )) { $1 }
    let ctx = ScanContext.testContext(processes: table)
    #expect(SimulatorsModule.facts(udid: udidA, name: "x", ctx: ctx).referencedBy.isEmpty)
}

@Test func ourOwnDescendantsMentioningUDIDAreIgnored() {
    let me = getpid()
    let table = simTable().merging(processTable(
        .fixture(pid: me, name: "xctest"),
        .fixture(pid: 700, ppid: me, name: "simctl", path: frameworkBin, arguments: ["simctl", "list", udidA]),
        .fixture(pid: 701, ppid: 700, name: "helper", arguments: ["helper", udidA])
    )) { $1 }
    let ctx = ScanContext.testContext(processes: table)
    #expect(SimulatorsModule.facts(udid: udidA, name: "x", ctx: ctx).referencedBy.isEmpty)
}

// MARK: - Engine item

private func engineTable(cpu: Double) -> ([Int32: ProcessInfoRecord], [Int32: Double]) {
    (processTable(
        .fixture(pid: 500, name: "com.apple.CoreSimulator.CoreSimulatorService", path: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/XPCServices/com.apple.CoreSimulator.CoreSimulatorService.xpc/Contents/MacOS/com.apple.CoreSimulator.CoreSimulatorService"),
        .fixture(pid: 501, name: "SimMetalHost"),
        .fixture(pid: 502, name: "SimRenderServer"),
        .fixture(pid: 503, name: "unrelated")
    ), [500: cpu * 50, 501: cpu * 30, 502: cpu * 20, 503: 900])
}

@Test func engineItemEmittedWhenNothingBootedAndBusy() {
    let (procs, cpu) = engineTable(cpu: 0.5)   // 0.5 cores total
    let items = SimulatorsModule.buildItems(devices: [], ctx: .testContext(processes: procs, cpu: cpu))
    #expect(items.count == 1)
    #expect(items[0].id == .engine(name: "simulator-services")); #expect(items[0].name == "Simulator services")
    #expect(items[0].judgement.verdict == .idle)
    #expect(Set(items[0].processes.map(\.pid)) == [500, 501, 502])
    #expect(abs(items[0].cores - 0.5) < 0.0001)
}
@Test func engineItemNotEmittedWhenQuiet() {
    let (procs, cpu) = engineTable(cpu: 0.1)
    #expect(SimulatorsModule.buildItems(devices: [], ctx: .testContext(processes: procs, cpu: cpu)).isEmpty)
}
@Test func engineItemNotEmittedWhenADeviceIsBooted() {
    let (procs, cpu) = engineTable(cpu: 0.5)
    let items = SimulatorsModule.buildItems(devices: [(udid: udidA, name: "x")], ctx: .testContext(processes: procs, cpu: cpu))
    #expect(!items.contains { $0.id == .engine(name: "simulator-services") })
}
@Test func engineItemIgnoresOtherUsersProcesses() {
    let procs = processTable(.fixture(pid: 501, uid: 0, name: "SimMetalHost"))
    #expect(SimulatorsModule.buildItems(devices: [], ctx: .testContext(processes: procs, cpu: [501: 100])).isEmpty)
}

@Test func engineItemWithheldWhileALauncherExists() {
    var (procs, cpu) = engineTable(cpu: 0.5)
    procs[900] = .fixture(pid: 900, name: "launchd_sim", arguments: ["launchd_sim", home + udidA + "/data/var/run/x.plist"], startedAgo: 5)
    cpu[900] = 0
    #expect(SimulatorsModule.buildItems(devices: [], ctx: .testContext(processes: procs, cpu: cpu)).isEmpty)
}
@Test func stopEngineSkipsWhenASimulatorIsStarting() async {
    let (procs, cpu) = engineTable(cpu: 0.5)
    let items = SimulatorsModule.buildItems(devices: [], ctx: .testContext(processes: procs, cpu: cpu))
    let engine = try! #require(items.first)
    var starting = procs
    starting[900] = .fixture(pid: 900, name: "launchd_sim", arguments: ["launchd_sim", home + udidA + "/data/var/run/x.plist"], startedAgo: 5)
    let result = await SimulatorsModule().stop(engine, ctx: .testContext(processes: starting))
    #expect(result == .skipped(reason: "a simulator is starting"))
}

// MARK: - Stop guard

@Test func stopSkipsAnythingNotIdle() async {
    let item = Item(
        id: .simulator(udid: udidA), category: .simulators, name: "x", symbol: "iphone",
        judgement: Judgement(verdict: .inUse, fact: "Orbit opened 13 min ago", signals: []),
        cores: 0, memoryBytes: 0, processes: [], detail: ["udid": udidA]
    )
    let result = await SimulatorsModule().stop(item, ctx: .testContext())
    guard case .skipped = result else { Issue.record("expected skipped, got \(result)"); return }
}
@Test func stopRejectsMalformedUDID() async {
    let item = Item(
        id: .simulator(udid: "--all"), category: .simulators, name: "x", symbol: "iphone",
        judgement: Judgement(verdict: .idle, fact: "idle 2 days", signals: []),
        cores: 0, memoryBytes: 0, processes: [], detail: ["udid": "--all"]
    )
    let result = await SimulatorsModule().stop(item, ctx: .testContext())
    guard case .failed = result else { Issue.record("expected failed, got \(result)"); return }
}

// MARK: - Signaling

@Test func terminateSignalsOwnProcessOnlyWhenStartTimeMatches() async throws {
    // System binaries are on the never-stop list, so run a (re-signed) copy from a temp directory.
    let copy = try throwawayCopy(of: "/bin/sleep", named: "napper")
    defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
    let child = Process()
    child.executableURL = copy
    child.arguments = ["60"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }

    let real = try #require(ProcessTable.snapshot()[child.processIdentifier])
    // A recycled pid (same pid, different start time) must be left alone.
    let stale = ProcessSignaler.terminate([ProcessRef(pid: real.pid, startTime: real.startTime.addingTimeInterval(-100))])
    #expect(stale.gone == [real.pid]); #expect(child.isRunning)

    let outcome = ProcessSignaler.terminate([real.ref])
    #expect(outcome.signalled == [real.pid])
    child.waitUntilExit()
    #expect(!child.isRunning)
}
@Test func terminateRefusesRootAndSelf() {
    let table = ProcessTable.snapshot()
    let me = table[getpid()]!.ref
    #expect(ProcessSignaler.terminate([me]).refused == [getpid()])
    if let launchd = table[1] { #expect(ProcessSignaler.terminate([launchd.ref]).signalled.isEmpty) }
}

@Test func signalerRefusesSystemSoftwareAndCoreUI() throws {
    #expect(ProcessSignaler.isProtected(path: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", name: "Finder"))
    #expect(ProcessSignaler.isProtected(path: "/usr/libexec/something", name: "something"))
    #expect(ProcessSignaler.isProtected(path: "/bin/sleep", name: "sleep"))
    #expect(ProcessSignaler.isProtected(path: "/sbin/launchd", name: "launchd"))
    #expect(ProcessSignaler.isProtected(path: "/Library/Apple/System/Library/x", name: "x"))
    #expect(ProcessSignaler.isProtected(path: "/Applications/Whatever", name: "Dock"))
    #expect(ProcessSignaler.isProtected(path: "/odd/place/WindowServer", name: "WindowServer"))
    #expect(!ProcessSignaler.isProtected(path: "/usr/local/bin/node", name: "node"))
    #expect(!ProcessSignaler.isProtected(path: "/opt/homebrew/bin/node", name: "node"))
    #expect(!ProcessSignaler.isProtected(path: "/Users/me/app/server", name: "server"))

    // End to end: a live process running a protected binary is refused, not signalled.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    defer { if child.isRunning { child.terminate() } }
    let real = try #require(ProcessTable.snapshot()[child.processIdentifier])
    let outcome = ProcessSignaler.terminate([real.ref])
    #expect(outcome.refused == [real.pid]); #expect(child.isRunning)
}
