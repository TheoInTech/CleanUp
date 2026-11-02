import Foundation
import Synchronization
import Testing
@testable import CleanUpCore

// MARK: - Judge

@Suite struct ContainerJudgeTests {
    @Test func idleOldContainerIsIdle() {
        let j = ContainerJudge.judge(.fixture(name: "paorder-shop-postgres-1", cpu: 0, clients: 0, net: 0, age: .days(12)), now: now)
        #expect(j.verdict == .idle)
        #expect(j.fact == "idle 12 days")
    }

    @Test func containerWithClientIsInUse() {
        let j = ContainerJudge.judge(.fixture(cpu: 0, clients: 2, net: 0, age: .days(14)), now: now)
        #expect(j.verdict == .inUse)
        #expect(j.fact == "2 connections")
    }

    @Test func singleClientIsSingular() {
        #expect(ContainerJudge.judge(.fixture(clients: 1), now: now).fact == "1 connection")
    }

    @Test func firstScanWithoutNetDeltaIsInUse() {
        #expect(ContainerJudge.judge(.fixture(cpu: 0, clients: 0, net: nil, age: .days(3)), now: now).verdict == .inUse)
    }

    @Test func busyCPUIsInUse() {
        let j = ContainerJudge.judge(.fixture(cpu: 1.0, net: 0), now: now)
        #expect(j.verdict == .inUse)
        #expect(j.fact == "busy")
        #expect(ContainerJudge.judge(.fixture(cpu: 0.99, net: 0), now: now).verdict == .idle)
    }

    @Test func networkTrafficIsInUse() {
        let j = ContainerJudge.judge(.fixture(net: 4096), now: now)
        #expect(j.verdict == .inUse)
        #expect(j.fact == "busy")
        #expect(ContainerJudge.judge(.fixture(net: 4095), now: now).verdict == .idle)
    }

    @Test func recentlyStartedIsInUse() {
        let j = ContainerJudge.judge(.fixture(age: .hours(5.9)), now: now)
        #expect(j.verdict == .inUse)
        #expect(j.fact == "just started")
        #expect(ContainerJudge.judge(.fixture(age: .hours(6)), now: now).verdict == .idle)
    }

    @Test func conditionsCombineWithAnd() {
        // Each single failing condition is enough to be in use.
        #expect(ContainerJudge.judge(.fixture(cpu: 5), now: now).verdict == .inUse)
        #expect(ContainerJudge.judge(.fixture(clients: 1), now: now).verdict == .inUse)
        #expect(ContainerJudge.judge(.fixture(net: nil), now: now).verdict == .inUse)
        #expect(ContainerJudge.judge(.fixture(age: .minutes(10)), now: now).verdict == .inUse)
    }
}

// MARK: - Parsing

@Suite struct ContainerParsingTests {
    @Test func parsesPSLines() {
        let out = """
        {"ID":"75beec90ce2f","Image":"postgres:16","Names":"evone-postgres","Ports":"0.0.0.0:5432->5432/tcp","Status":"Up 2 weeks (healthy)"}
        {"ID":"59883c8ca072","Image":"imresamu/postgis:17-3.5","Names":"evone-pg-api09","Ports":"127.0.0.1:5495->5432/tcp","Status":"Up 23 hours"}

        not json
        """
        let rows = ContainersModule.parsePS(out)
        #expect(rows.map(\.name) == ["evone-postgres", "evone-pg-api09"])
        #expect(rows.map(\.image) == ["postgres:16", "imresamu/postgis:17-3.5"])
    }

    @Test func psSkipsUnsafeNames() {
        #expect(ContainersModule.parsePS(#"{"Image":"x","Names":"--all"}"#).isEmpty)
    }

    @Test func parsesStatsLines() {
        let s = ContainersModule.parseStats(#"{"Name":"evone-postgres","CPUPerc":"2.75%","NetIO":"1.2MB / 3.4MB"}"#)
        #expect(s["evone-postgres"]?.cpu == 2.75)
        #expect(s["evone-postgres"]?.netIOBytes == 4_600_000)
    }

    @Test func parsesEveryNetIOUnit() {
        #expect(ContainersModule.parseNetIO("0B / 0B") == 0)
        #expect(ContainersModule.parseNetIO("1.5kB / 500B") == 2_000)
        #expect(ContainersModule.parseNetIO("251MB / 156MB") == 407_000_000)
        #expect(ContainersModule.parseNetIO("1.2GB / 0B") == 1_200_000_000)
        #expect(ContainersModule.parseNetIO("1KiB / 1MiB") == Int64(1_024 + 1_048_576))
        #expect(ContainersModule.parseNetIO("garbage") == nil)
        #expect(ContainersModule.parseNetIO("1.2MB") == nil)
        #expect(ContainersModule.parseNetIO("1.2XB / 1B") == nil)
    }

    @Test func statsIgnoreRowsItCannotRead() {
        let out = """
        {"Name":"a","CPUPerc":"--","NetIO":"0B / 0B"}
        {"Name":"b","CPUPerc":"0.00%","NetIO":"--"}
        {"Name":"c","CPUPerc":"0.00%","NetIO":"0B / 0B"}
        """
        #expect(Set(ContainersModule.parseStats(out).keys) == ["c"])
    }

    @Test func parsesInspectWithFractionalSecondsAndPorts() {
        let out = """
        {"Name":"/evone-pg-api09","State":{"StartedAt":"2026-11-01T17:35:37.244515297Z"},"NetworkSettings":{"Ports":{"5432/tcp":[{"HostIp":"127.0.0.1","HostPort":"5495"}],"80/tcp":null}}}
        {"Name":"/no-ports","State":{"StartedAt":"2026-11-01T17:35:37Z"},"NetworkSettings":{"Ports":null}}
        {"Name":"/two","State":{"StartedAt":"2026-11-01T17:35:37Z"},"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"},{"HostIp":"::","HostPort":"8080"}],"81/tcp":[{"HostIp":"0.0.0.0","HostPort":"8081"}]}}}
        """
        let info = ContainersModule.parseInspect(out)
        #expect(info["evone-pg-api09"]?.ports == [5495])
        #expect(info["no-ports"]?.ports == [])
        #expect(info["two"]?.ports == [8080, 8081])
        let started = info["evone-pg-api09"]?.startedAt
        #expect(started != nil)
        let whole = ISO8601DateFormatter().date(from: "2026-11-01T17:35:37Z")
        #expect(abs((started?.timeIntervalSince1970 ?? 0) - (whole?.timeIntervalSince1970 ?? -1) - 0.2445) < 0.001)
    }

    @Test func inspectRejectsUnparseableStartDate() {
        let out = #"{"Name":"/x","State":{"StartedAt":"0001-01-01T00:00:00Z"},"NetworkSettings":{"Ports":{}}}"#
        // Docker's zero date means "never started": not a usable start time.
        #expect(ContainersModule.parseInspect(out)["x"] == nil)
    }
}

// MARK: - Engine judgement

@Suite struct EngineJudgementTests {
    @Test func engineIdleOnlyWhenAllContainersIdle() {
        #expect(ContainersModule.engineJudgement(containerVerdicts: [.idle, .idle]).verdict == .idle)
        #expect(ContainersModule.engineJudgement(containerVerdicts: [.idle, .inUse]).verdict == .inUse)
        #expect(ContainersModule.engineJudgement(containerVerdicts: []).verdict == .idle)
    }

    @Test func engineFacts() {
        #expect(ContainersModule.engineJudgement(containerVerdicts: []).fact == "idle engine")
        #expect(ContainersModule.engineJudgement(containerVerdicts: [.idle]).fact == "idle engine")
        #expect(ContainersModule.engineJudgement(containerVerdicts: [.inUse, .idle, .inUse]).fact == "2 containers in use")
        #expect(ContainersModule.engineJudgement(containerVerdicts: [.inUse]).fact == "1 container in use")
    }

    @Test func anythingButIdleCountsAsInUse() {
        #expect(ContainersModule.engineJudgement(containerVerdicts: [.idle, .check]).verdict == .inUse)
    }
}

// MARK: - Engine detection and client counting

private let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

private func dockerTable(vmStartedAgo: TimeInterval = .days(1) - 3) -> [Int32: ProcessInfoRecord] {
    processTable(
        .fixture(pid: 100, name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend", startedAgo: .days(1) + 5),
        .fixture(pid: 101, ppid: 100, name: "com.docker.virtualization", path: "/Applications/Docker.app/Contents/MacOS/com.docker.virtualization", startedAgo: .days(1), residentBytes: 7_000),
        .fixture(pid: 102, name: "com.apple.Virtualization.VirtualMachine", path: vmPath, startedAgo: vmStartedAgo, residentBytes: 1_000_000),
        .fixture(pid: 103, name: "Docker Desktop", path: "/Applications/Docker.app/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop", startedAgo: .days(1)),
        .fixture(pid: 500, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari")
    )
}

@Suite struct EngineDetectionTests {
    @Test func detectsDockerDesktopWithItsVM() throws {
        let found = ContainersModule.detectEngines(dockerTable())
        #expect(found.count == 1)
        let docker = try #require(found.first)
        #expect(docker.engine == .dockerDesktop)
        #expect(docker.appPath == "/Applications/Docker.app")
        #expect(Set(docker.processes.map(\.pid)) == [100, 101, 103])
        #expect(docker.vm.map(\.pid) == [102])
    }

    @Test func vmStartedLongBeforeTheEngineIsNotItsOwn() throws {
        let found = ContainersModule.detectEngines(dockerTable(vmStartedAgo: .days(20)))
        #expect(try #require(found.first).vm.isEmpty)
    }

    @Test func detectsOrbStack() throws {
        let table = processTable(
            .fixture(pid: 10, name: "OrbStack Helper", path: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper"),
            .fixture(pid: 11, name: "OrbStack", path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack")
        )
        let orb = try #require(ContainersModule.detectEngines(table).first)
        #expect(orb.engine == .orbStack)
        #expect(orb.appPath == "/Applications/OrbStack.app")
        #expect(orb.processes.count == 2)
    }

    @Test func detectsColimaFromLimaHostAgent() throws {
        let table = processTable(
            .fixture(pid: 20, name: "limactl", path: "/opt/homebrew/bin/limactl",
                     arguments: ["limactl", "hostagent", "--pidfile", "/Users/me/.colima/_lima/colima/ha.pid", "colima"], startedAgo: .hours(2)),
            .fixture(pid: 21, name: "com.apple.Virtualization.VirtualMachine", path: vmPath, startedAgo: .hours(2) - 1)
        )
        let colima = try #require(ContainersModule.detectEngines(table).first)
        #expect(colima.engine == .colima)
        #expect(colima.appPath == nil)
        #expect(colima.processes.map(\.pid) == [20])
        #expect(colima.vm.map(\.pid) == [21])
    }

    @Test func noEngineWhenNothingMatches() {
        #expect(ContainersModule.detectEngines(processTable(.fixture(pid: 5, name: "Safari"))).isEmpty)
        // A lone VM (UTM, Tart, …) is not Docker.
        #expect(ContainersModule.detectEngines(processTable(.fixture(pid: 6, name: "com.apple.Virtualization.VirtualMachine", path: vmPath))).isEmpty)
    }

    @Test func otherUsersProcessesAreIgnored() {
        let table = processTable(.fixture(pid: 7, uid: 0, name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend"))
        #expect(ContainersModule.detectEngines(table).isEmpty)
    }

    @Test func clientCountIgnoresProxyListenersAndOtherPorts() {
        let sockets = [
            SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5432),   // psql client
            SocketInfo(pid: 901, state: .established, localPort: 51_001, remotePort: 5432),   // another client
            SocketInfo(pid: 100, state: .established, localPort: 51_002, remotePort: 5432),   // the engine's own proxy
            SocketInfo(pid: 100, state: .listen, localPort: 5432, remotePort: nil),
            SocketInfo(pid: 100, state: .established, localPort: 5432, remotePort: 51_000),
            SocketInfo(pid: 902, state: .established, localPort: 51_003, remotePort: 6379),   // other port
            SocketInfo(pid: 903, state: .listen, localPort: 7000, remotePort: nil),
        ]
        #expect(ContainersModule.clientConnections(ports: [5432], sockets: sockets, excluding: [100, 101]) == 2)
        #expect(ContainersModule.clientConnections(ports: [], sockets: sockets, excluding: []) == 0)
        #expect(ContainersModule.clientConnections(ports: [5432, 6379], sockets: sockets, excluding: [100]) == 3)
    }
}

// MARK: - Module scan / stop / undo

private final class FakeDocker: Sendable {
    struct State {
        var ps = ""
        var stats = ""
        var inspect = ""
        var psStatus: Int32 = 0
        var calls: [[String]] = []
    }
    let state = Mutex(State())

    var run: ContainersModule.Run {
        { [self] cmd, args in
            state.withLock { $0.calls.append([cmd] + args) }
            let s = state.withLock { $0 }
            switch (cmd, args.first) {
            case ("docker", "ps"):
                return s.psStatus == 0
                    ? CommandResult(status: 0, stdout: s.ps, stderr: "", timedOut: false)
                    : CommandResult(status: 1, stdout: "", stderr: "Cannot connect to the Docker daemon", timedOut: false)
            case ("docker", "stats"): return CommandResult(status: 0, stdout: s.stats, stderr: "", timedOut: false)
            case ("docker", "inspect"): return CommandResult(status: 0, stdout: s.inspect, stderr: "", timedOut: false)
            default: return CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)
            }
        }
    }

    var calls: [[String]] { state.withLock { $0.calls } }
    func count(_ sub: String) -> Int { calls.filter { $0.dropFirst().first == sub }.count }
    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
}

private func isoDate(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private struct Row { var name: String; var cpu = "0.00%"; var net = "1.2MB / 3.4MB"; var port: Int? = 5432; var age: TimeInterval = .days(12) }

private func fakeDocker(_ rows: [Row]) -> FakeDocker {
    let d = FakeDocker()
    d.set { s in apply(rows, to: &s) }
    return d
}

private func apply(_ rows: [Row], to s: inout FakeDocker.State) {
    s.ps = rows.map { #"{"Image":"postgres:16","Names":"\#($0.name)","Status":"Up"}"# }.joined(separator: "\n")
    s.stats = rows.map { #"{"Name":"\#($0.name)","CPUPerc":"\#($0.cpu)","NetIO":"\#($0.net)"}"# }.joined(separator: "\n")
    s.inspect = rows.map { r in
        let ports = r.port.map { #"{"5432/tcp":[{"HostIp":"0.0.0.0","HostPort":"\#($0)"}]}"# } ?? "{}"
        return #"{"Name":"/\#(r.name)","State":{"StartedAt":"\#(isoDate(now.addingTimeInterval(-r.age)))"},"NetworkSettings":{"Ports":\#(ports)}}"#
    }.joined(separator: "\n")
}

private func module(_ d: FakeDocker, quit: @escaping ContainersModule.AppAction = { _ in true }, launch: @escaping ContainersModule.AppAction = { _ in true }) -> ContainersModule {
    ContainersModule(run: d.run, quitApp: quit, launchApp: launch)
}

@Suite struct ContainersModuleTests {
    @Test func dockerDaemonDownYieldsNoItems() async {
        let m = ContainersModule(run: { _, _ in CommandResult(status: 1, stdout: "", stderr: "Cannot connect to the Docker daemon", timedOut: false) })
        #expect(await m.scan(.testContext()).isEmpty)
    }

    @Test func dockerTimeoutYieldsNoItems() async {
        let m = ContainersModule(run: { _, _ in CommandResult(status: 137, stdout: "{}", stderr: "", timedOut: true) })
        #expect(await m.scan(.testContext()).isEmpty)
    }

    @Test func daemonDownEvenWithEngineRunningYieldsNoItems() async {
        let d = FakeDocker()
        d.set { $0.psStatus = 1 }
        #expect(await module(d).scan(.testContext(processes: dockerTable())).isEmpty)
    }

    @Test func firstScanIsInUseSecondScanIdle() async throws {
        let d = fakeDocker([Row(name: "orbit-trust-pg")])
        let m = module(d)
        let first = await m.scan(.testContext())
        #expect(first.count == 1)
        #expect(first[0].judgement.verdict == .inUse)

        let second = try #require(await m.scan(.testContext()).first)
        #expect(second.id == .container(name: "orbit-trust-pg"))
        #expect(second.category == .containers)
        #expect(second.judgement.verdict == .idle)
        #expect(second.judgement.fact == "idle 12 days")
        #expect(second.detail["image"] == "postgres:16")
        #expect(second.detail["ports"] == "5432")
    }

    @Test func trafficBetweenScansMakesItBusy() async throws {
        let d = fakeDocker([Row(name: "a", net: "1.2MB / 3.4MB")])
        let m = module(d)
        _ = await m.scan(.testContext())
        d.set { apply([Row(name: "a", net: "1.3MB / 3.5MB")], to: &$0) }
        let item = try #require(await m.scan(.testContext()).first)
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "busy")
    }

    @Test func counterResetIsTreatedAsUnknown() async throws {
        let d = fakeDocker([Row(name: "a", net: "9MB / 9MB")])
        let m = module(d)
        _ = await m.scan(.testContext())
        d.set { apply([Row(name: "a", net: "1kB / 1kB")], to: &$0) }
        #expect(try #require(await m.scan(.testContext()).first).judgement.verdict == .inUse)
    }

    @Test func connectedClientMakesItInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        _ = await m.scan(.testContext())
        let sockets = [SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5432)]
        let item = try #require(await m.scan(.testContext(sockets: sockets)).first)
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "1 connection")
    }

    @Test func engineProxySocketsAreNotClients() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        let ctxProcs = dockerTable()
        _ = await m.scan(.testContext(processes: ctxProcs))
        let sockets = [SocketInfo(pid: 100, state: .established, localPort: 51_000, remotePort: 5432)]
        let items = await m.scan(.testContext(processes: ctxProcs, sockets: sockets))
        #expect(items.first { $0.id == .container(name: "a") }?.judgement.verdict == .idle)
    }

    @Test func emitsEngineItemWhenEngineRunsAndEverythingIdle() async throws {
        let d = fakeDocker([Row(name: "a"), Row(name: "b", port: 5433)])
        let m = module(d)
        let procs = dockerTable()
        let ctx = ScanContext.testContext(processes: procs, cpu: [100: 50, 101: 100, 102: 25])
        _ = await m.scan(ctx)
        let items = await m.scan(ctx)
        #expect(items.count == 3)
        let engine = try #require(items.first { $0.id == .engine(name: "Docker Desktop") })
        #expect(engine.name == "Docker Desktop")
        #expect(engine.judgement.verdict == .idle)
        #expect(engine.judgement.fact == "idle engine")
        #expect(abs(engine.cores - 1.75) < 0.0001)   // 0.5 + 1.0 + 0.25, VM CPU attributed
        #expect(engine.memoryBytes == 1_007_000)
        #expect(Set(engine.processes.map(\.pid)) == [100, 101, 103])   // the VM is never signalled
        #expect(engine.detail["appPath"] == "/Applications/Docker.app")
        for c in items where c.category == .containers && c.id != engine.id {
            #expect(c.detail["engine"] == "Docker Desktop")
        }
    }

    @Test func engineIsInUseWhenAnyContainerIs() async throws {
        let d = fakeDocker([Row(name: "a"), Row(name: "b", port: 5433)])
        let m = module(d)
        let procs = dockerTable()
        _ = await m.scan(.testContext(processes: procs))
        let sockets = [SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5433)]
        let items = await m.scan(.testContext(processes: procs, sockets: sockets))
        let engine = try #require(items.first { $0.id == .engine(name: "Docker Desktop") })
        #expect(engine.judgement.verdict == .inUse)
    }

    @Test func engineWithZeroContainersIsIdle() async throws {
        let d = fakeDocker([])
        let items = await module(d).scan(.testContext(processes: dockerTable()))
        #expect(items.count == 1)
        #expect(items[0].id == .engine(name: "Docker Desktop"))
        #expect(items[0].judgement.verdict == .idle)
    }

    @Test func noEngineItemWhenNoEngineProcesses() async {
        let d = fakeDocker([Row(name: "a")])
        let items = await module(d).scan(.testContext())
        #expect(items.allSatisfy { $0.id != .engine(name: "Docker Desktop") })
        #expect(items.first?.detail["engine"] == nil)
    }

    @Test func twoEnginesMakeTheEngineVerdictUncertain() async {
        let d = fakeDocker([])
        var procs = dockerTable()
        procs[10] = .fixture(pid: 10, name: "OrbStack", path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack")
        let items = await module(d).scan(.testContext(processes: procs))
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.judgement.verdict == .inUse })
    }

    @Test func containerWhoseStatsCannotBeReadIsInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        d.set { $0.stats = "" }
        let m = module(d)
        _ = await m.scan(.testContext())
        let item = try #require(await m.scan(.testContext()).first)
        #expect(item.judgement.verdict == .inUse)
    }

    @Test func containerWithoutInspectDataIsInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        d.set { $0.inspect = "" }
        let m = module(d)
        _ = await m.scan(.testContext())
        #expect(try #require(await m.scan(.testContext()).first).judgement.verdict == .inUse)
    }

    @Test func cachedScanDoesNotRunDockerAgain() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        _ = await m.scan(.testContext())
        _ = await m.scan(.testContext())
        let before = d.calls.count
        var cached = ScanContext.testContext()
        cached = ScanContext(now: cached.now, processes: [:], cpu: [:], sockets: [], frontmostBundleID: nil, ownPID: cached.ownPID, runExternal: false)
        let item = try #require(await m.scan(cached).first)
        #expect(d.calls.count == before)
        #expect(item.judgement.verdict == .idle)
        // …but client connections are always live.
        let live = ScanContext(now: cached.now, processes: [:], cpu: [:], sockets: [SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5432)],
                               frontmostBundleID: nil, ownPID: cached.ownPID, runExternal: false)
        #expect(try #require(await m.scan(live).first).judgement.verdict == .inUse)
    }

    @Test func cachedScanBeforeAnyRealScanIsEmpty() async {
        let m = module(fakeDocker([Row(name: "a")]))
        let ctx = ScanContext(now: now, processes: [:], cpu: [:], sockets: [], frontmostBundleID: nil, ownPID: 1, runExternal: false)
        #expect(await m.scan(ctx).isEmpty)
    }

    @Test func inspectIsBatchedInOneCall() async {
        let d = fakeDocker([Row(name: "a"), Row(name: "b"), Row(name: "c")])
        _ = await module(d).scan(.testContext())
        #expect(d.count("inspect") == 1)
        let inspect = d.calls.first { $0.dropFirst().first == "inspect" } ?? []
        #expect(Array(inspect.suffix(3)) == ["a", "b", "c"])
    }

    // MARK: stop / undo

    private func idleContainerItem(_ m: ContainersModule) async throws -> Item {
        _ = await m.scan(.testContext())
        return try #require(await m.scan(.testContext()).first)
    }

    @Test func stopsIdleContainerAndOffersUndo() async throws {
        let d = fakeDocker([Row(name: "evone-postgres")])
        let m = module(d)
        let item = try await idleContainerItem(m)
        let result = await m.stop(item, ctx: .testContext())
        #expect(result == .stopped(UndoToken(identity: .container(name: "evone-postgres"), action: "start", arguments: ["evone-postgres"])))
        #expect(d.calls.last == ["docker", "stop", "evone-postgres"])
    }

    @Test func refusesToStopInUseContainer() async throws {
        let d = fakeDocker([Row(name: "a", cpu: "50.00%")])
        let m = module(d)
        _ = await m.scan(.testContext())
        let item = try #require(await m.scan(.testContext()).first)
        #expect(item.judgement.verdict == .inUse)
        let result = await m.stop(item, ctx: .testContext())
        guard case .skipped = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(d.count("stop") == 0)
    }

    @Test func rechecksClientsRightBeforeStopping() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        let item = try await idleContainerItem(m)
        let sockets = [SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5432)]
        let result = await m.stop(item, ctx: .testContext(sockets: sockets))
        guard case .skipped = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(d.count("stop") == 0)
    }

    @Test func stopFailureIsReported() async throws {
        let item = Item(
            id: .container(name: "a"), category: .containers, name: "a", symbol: "shippingbox",
            judgement: Judgement(verdict: .idle, fact: "idle 3 days", signals: []), cores: 0, memoryBytes: 0,
            processes: [], detail: ["ports": "5432"]
        )
        let m = ContainersModule(run: { _, _ in CommandResult(status: 1, stdout: "", stderr: "Error response from daemon: boom\nmore", timedOut: false) })
        #expect(await m.stop(item, ctx: .testContext()) == .failed(reason: "Error response from daemon: boom"))
    }

    @Test func refusesUnsafeContainerNames() async {
        let item = Item(
            id: .container(name: "--all"), category: .containers, name: "--all", symbol: "shippingbox",
            judgement: Judgement(verdict: .idle, fact: "idle", signals: []), cores: 0, memoryBytes: 0, processes: [], detail: [:]
        )
        let d = FakeDocker()
        guard case .failed = await module(d).stop(item, ctx: .testContext()) else { Issue.record("expected failure"); return }
        #expect(d.calls.isEmpty)
        #expect(await module(d).undo(UndoToken(identity: item.id, action: "start", arguments: ["--all"])) == false)
    }

    @Test func undoStartsTheContainer() async {
        let d = FakeDocker()
        let ok = await module(d).undo(UndoToken(identity: .container(name: "a"), action: "start", arguments: ["a"]))
        #expect(ok)
        #expect(d.calls == [["docker", "start", "a"]])
    }

    private func engineItem(_ engine: ContainerEngine, verdict: Verdict = .idle, appPath: String?) -> Item {
        var detail = ["ports": "5432"]
        if let appPath { detail["appPath"] = appPath }
        return Item(
            id: .engine(name: engine.rawValue), category: .containers, name: engine.rawValue, symbol: "gearshape.2",
            judgement: Judgement(verdict: verdict, fact: "idle engine", signals: []), cores: 0, memoryBytes: 0,
            processes: [], detail: detail
        )
    }

    @Test func stopsDockerDesktopByQuittingTheApp() async {
        let quits = Mutex<[String]>([])
        let d = FakeDocker()
        let m = module(d, quit: { path in quits.withLock { $0.append(path) }; return true })
        let item = engineItem(.dockerDesktop, appPath: "/Applications/Docker.app")
        let result = await m.stop(item, ctx: .testContext())
        #expect(result == .stopped(UndoToken(identity: item.id, action: "launch", arguments: ["/Applications/Docker.app"])))
        #expect(quits.withLock { $0 } == ["/Applications/Docker.app"])
        #expect(d.calls.isEmpty)
    }

    @Test func stopsColimaWithItsOwnCommand() async {
        let d = FakeDocker()
        let m = module(d, quit: { _ in Issue.record("must not quit an app"); return false })
        let item = engineItem(.colima, appPath: nil)
        let result = await m.stop(item, ctx: .testContext())
        #expect(result == .stopped(UndoToken(identity: item.id, action: "colima-start", arguments: [])))
        #expect(d.calls == [["colima", "stop"]])
    }

    @Test func engineStopFailsWhenAppCannotBeQuit() async {
        let m = module(FakeDocker(), quit: { _ in false })
        guard case .failed = await m.stop(engineItem(.orbStack, appPath: "/Applications/OrbStack.app"), ctx: .testContext()) else {
            Issue.record("expected failure"); return
        }
    }

    @Test func engineIsNotStoppedWhenInUse() async {
        let d = FakeDocker()
        let m = module(d, quit: { _ in Issue.record("must not quit"); return true })
        guard case .skipped = await m.stop(engineItem(.dockerDesktop, verdict: .inUse, appPath: "/Applications/Docker.app"), ctx: .testContext()) else {
            Issue.record("expected skipped"); return
        }
    }

    @Test func engineIsNotStoppedWhenAClientAppearedSinceTheScan() async {
        let m = module(FakeDocker(), quit: { _ in Issue.record("must not quit"); return true })
        let sockets = [SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5432)]
        guard case .skipped = await m.stop(engineItem(.dockerDesktop, appPath: "/Applications/Docker.app"), ctx: .testContext(sockets: sockets)) else {
            Issue.record("expected skipped"); return
        }
    }

    @Test func undoRelaunchesEngines() async {
        let launches = Mutex<[String]>([])
        let d = FakeDocker()
        let m = module(d, launch: { path in launches.withLock { $0.append(path) }; return true })
        #expect(await m.undo(UndoToken(identity: .engine(name: "Docker Desktop"), action: "launch", arguments: ["/Applications/Docker.app"])))
        #expect(launches.withLock { $0 } == ["/Applications/Docker.app"])
        #expect(await m.undo(UndoToken(identity: .engine(name: "Colima"), action: "colima-start", arguments: [])))
        #expect(d.calls == [["colima", "start"]])
        #expect(await m.undo(UndoToken(identity: .engine(name: "x"), action: "bogus", arguments: [])) == false)
    }
}
