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

    @Test func noPublishedPortsDoesNotClaimNothingIsConnected() {
        let j = ContainerJudge.judge(.fixture(ports: []), now: now)
        #expect(j.signals.contains(Signal(kind: .neutral, text: "No ports published")))
        #expect(!j.signals.contains { $0.text.contains("connected") })
        let withPorts = ContainerJudge.judge(.fixture(ports: [5432]), now: now)
        #expect(withPorts.signals.contains { $0.kind == .idle && $0.text.contains("connected") })
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

    @Test func parsesExactNetworkBytesFromEngineAPI() {
        let json = #"{"id":"x","networks":{"eth0":{"rx_bytes":15748332,"rx_packets":1,"tx_bytes":5905274,"tx_packets":2},"eth1":{"rx_bytes":10,"tx_bytes":5}}}"#
        #expect(ContainersModule.parseAPINetworkBytes(json) == Int64(15_748_332 + 5_905_274 + 15))
        #expect(ContainersModule.parseAPINetworkBytes(#"{"id":"x"}"#) == nil)          // host networking: unknown, not zero
        #expect(ContainersModule.parseAPINetworkBytes(#"{"networks":{}}"#) == nil)
        #expect(ContainersModule.parseAPINetworkBytes(#"{"message":"No such container"}"#) == nil)
        #expect(ContainersModule.parseAPINetworkBytes("not json") == nil)
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
            SocketInfo(pid: 100, state: .established, localPort: 51_002, remotePort: 5432),   // the engine's own outbound socket
            SocketInfo(pid: 100, state: .listen, localPort: 5432, remotePort: nil),
            SocketInfo(pid: 100, state: .established, localPort: 5432, remotePort: 51_000),   // proxy side of psql: same connection
            SocketInfo(pid: 902, state: .established, localPort: 51_003, remotePort: 6379),   // other port
            SocketInfo(pid: 903, state: .listen, localPort: 7000, remotePort: nil),
        ]
        #expect(ContainersModule.clientConnections(ports: [5432], sockets: sockets, excluding: [100, 101]) == 2)
        #expect(ContainersModule.clientConnections(ports: [], sockets: sockets, excluding: []) == 0)
        #expect(ContainersModule.clientConnections(ports: [5432, 6379], sockets: sockets, excluding: [100]) == 3)
    }

    @Test func clientsReachingTheProxyFromOutsideAreCounted() {
        // A LAN/VPN client, or a container calling host.docker.internal:5432, shows up only as a
        // socket accepted by the engine proxy with local port == published port.
        let sockets = [
            SocketInfo(pid: 100, state: .established, localPort: 5432, remotePort: 60_000),
            SocketInfo(pid: 100, state: .established, localPort: 5432, remotePort: 60_001),
            SocketInfo(pid: 100, state: .listen, localPort: 5432, remotePort: nil),
        ]
        #expect(ContainersModule.clientConnections(ports: [5432], sockets: sockets, excluding: [100]) == 2)
        #expect(ContainersModule.clientConnections(ports: [5433], sockets: sockets, excluding: [100]) == 0)
    }
}

// MARK: - Module scan / stop / undo

private final class FakeDocker: Sendable {
    struct State {
        var ps = ""
        var stats = ""
        var inspect = ""
        var psStatus: Int32 = 0
        /// Exact byte counters served by the (fake) Engine API; a missing name → API error.
        var api: [String: Int64] = [:]
        var socketOK = true
        var orbList = CommandResult(status: 0, stdout: "", stderr: "", timedOut: false)
        var calls: [[String]] = []
    }
    let state = Mutex(State())

    var run: ContainersModule.Run {
        { [self] cmd, args in
            state.withLock { $0.calls.append([cmd] + args) }
            let s = state.withLock { $0 }
            func ok(_ out: String) -> CommandResult { CommandResult(status: 0, stdout: out, stderr: "", timedOut: false) }
            switch (cmd, args.first) {
            case ("docker", "ps"):
                return s.psStatus == 0
                    ? ok(s.ps)
                    : CommandResult(status: 1, stdout: "", stderr: "Cannot connect to the Docker daemon", timedOut: false)
            case ("docker", "stats"): return ok(s.stats)
            case ("docker", "inspect"): return ok(s.inspect)
            case ("docker", "context"):
                return s.socketOK ? ok("unix:///tmp/fake-docker.sock\n") : CommandResult(status: 1, stdout: "", stderr: "no context", timedOut: false)
            case ("orb", "list"): return s.orbList
            case ("/usr/bin/curl", _):
                let url = args.last ?? ""
                let name = url.components(separatedBy: "/containers/").last?.components(separatedBy: "/stats").first ?? ""
                guard let bytes = s.api[name] else { return CommandResult(status: 7, stdout: "", stderr: "", timedOut: false) }
                return ok(#"{"networks":{"eth0":{"rx_bytes":\#(bytes / 2),"tx_bytes":\#(bytes - bytes / 2)}}}"#)
            default: return ok("")
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

private struct Row {
    var name: String
    var cpu = "0.00%"
    /// The rounded figure `docker stats` prints. Deliberately never used for the idle decision.
    var net = "251MB / 156MB"
    /// Exact counter from the Engine API; nil → the API can't answer for this container.
    var api: Int64? = 407_000_000
    var port: Int? = 5432
    var age: TimeInterval = .days(12)
}

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
    s.api = [:]
    for r in rows { if let api = r.api { s.api[r.name] = api } }
}

private func module(_ d: FakeDocker, quit: @escaping ContainersModule.AppAction = { _ in true }, launch: @escaping ContainersModule.AppAction = { _ in true }) -> ContainersModule {
    ContainersModule(run: d.run, quitApp: quit, launchApp: launch)
}

/// A scan context `minutes` after the first scan.
private func ctx(_ minutes: Double = 0, processes: [Int32: ProcessInfoRecord] = [:], cpu: [Int32: Double] = [:], sockets: [SocketInfo] = []) -> ScanContext {
    .testContext(now: fixedNow.addingTimeInterval(.minutes(minutes)), processes: processes, cpu: cpu, sockets: sockets)
}

private let client5432 = SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5432)

/// Docker Desktop's processes using 3.5% of a core in all: a quiet engine.
private let quietEngineCPU: [Int32: Double] = [100: 1, 101: 1.5, 102: 1, 103: 0]

/// Scans once a minute from `from` to `to` (inclusive), as the refresh loop does; returns the last scan.
private func scanEveryMinute(
    _ m: ContainersModule, from: Double = 0, to: Double,
    processes: [Int32: ProcessInfoRecord] = [:], cpu: [Int32: Double] = [:], sockets: [SocketInfo] = []
) async -> [Item] {
    var last: [Item] = []
    var minute = from
    while minute <= to {
        last = await m.scan(ctx(minute, processes: processes, cpu: cpu, sockets: sockets))
        minute += 1
    }
    return last
}

private func engine(_ items: [Item], _ name: String = "Docker Desktop") -> Item? {
    items.first { $0.id == .engine(name: name) }
}

private func withProcess(_ table: [Int32: ProcessInfoRecord], _ p: ProcessInfoRecord) -> [Int32: ProcessInfoRecord] {
    var table = table
    table[p.pid] = p
    return table
}

private func orbStackTable() -> [Int32: ProcessInfoRecord] {
    processTable(
        .fixture(pid: 10, name: "OrbStack Helper", path: "/Applications/OrbStack.app/Contents/Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper"),
        .fixture(pid: 11, name: "OrbStack", path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack")
    )
}

private let quietOrbCPU: [Int32: Double] = [10: 1, 11: 1]

// MARK: - Engine activity

@Suite struct EngineActivityTests {
    @Test func engineIsIdleOnlyAfterTenQuietMinutes() async throws {
        let m = module(fakeDocker([]))
        let first = try #require(engine(await m.scan(ctx(0, processes: dockerTable(), cpu: quietEngineCPU))))
        #expect(first.judgement.verdict == .inUse)
        #expect(first.judgement.fact == "measuring activity")
        let nine = engine(await scanEveryMinute(m, from: 1, to: 9, processes: dockerTable(), cpu: quietEngineCPU))
        #expect(nine?.judgement.verdict == .inUse)
        let ten = try #require(engine(await m.scan(ctx(10, processes: dockerTable(), cpu: quietEngineCPU))))
        #expect(ten.judgement.verdict == .idle)
        #expect(ten.judgement.fact == "idle engine")
    }

    @Test(arguments: ["docker", "com.docker.cli", "docker-buildx", "docker-compose", "kubectl", "orb", "limactl"])
    func aDockerClientKeepsTheEngineInUse(client: String) async throws {
        let m = module(fakeDocker([]))
        let procs = withProcess(dockerTable(), .fixture(pid: 600, ppid: 50, name: client, path: "/usr/local/bin/\(client)", arguments: [client, "build", "."]))
        let item = try #require(engine(await scanEveryMinute(m, to: 15, processes: procs, cpu: quietEngineCPU)))
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "used by \(client)")
    }

    @Test func theQuietClockStartsOverWhenTheClientEnds() async throws {
        let m = module(fakeDocker([]))
        let pulling = withProcess(dockerTable(), .fixture(pid: 600, ppid: 50, name: "docker", path: "/usr/local/bin/docker", arguments: ["docker", "pull", "postgres"]))
        _ = await scanEveryMinute(m, to: 20, processes: pulling, cpu: quietEngineCPU)
        // The pull ended at minute 20: still in use at 29, idle from 31.
        #expect(engine(await scanEveryMinute(m, from: 21, to: 29, processes: dockerTable(), cpu: quietEngineCPU))?.judgement.verdict == .inUse)
        #expect(engine(await m.scan(ctx(31, processes: dockerTable(), cpu: quietEngineCPU)))?.judgement.verdict == .idle)
    }

    @Test func cleanUpsOwnDockerCallsAreNotClients() async {
        let m = module(fakeDocker([]))
        let procs = withProcess(dockerTable(), .fixture(pid: 600, ppid: getpid(), name: "docker", path: "/usr/local/bin/docker", arguments: ["docker", "ps"]))
        #expect(engine(await scanEveryMinute(m, to: 10, processes: procs, cpu: quietEngineCPU))?.judgement.verdict == .idle)
    }

    @Test func colimasOwnHostAgentIsNotAClient() async {
        let procs = processTable(
            .fixture(pid: 20, name: "limactl", path: "/opt/homebrew/bin/limactl",
                     arguments: ["limactl", "hostagent", "--pidfile", "/Users/me/.colima/_lima/colima/ha.pid", "colima"], startedAgo: .hours(2)),
            .fixture(pid: 21, name: "com.apple.Virtualization.VirtualMachine", path: vmPath, startedAgo: .hours(2) - 1)
        )
        let m = module(fakeDocker([]))
        let item = engine(await scanEveryMinute(m, to: 10, processes: procs, cpu: [20: 0.5, 21: 2]), "Colima")
        #expect(item?.judgement.verdict == .idle)
    }

    @Test func aBusyVMKeepsTheEngineInUse() async {
        // A build or pull runs inside the VM; no container shows it.
        let m = module(fakeDocker([]))
        let busy: [Int32: Double] = [100: 1, 101: 1, 102: 30, 103: 0]
        let item = engine(await scanEveryMinute(m, to: 15, processes: dockerTable(), cpu: busy))
        #expect(item?.judgement.verdict == .inUse)
        #expect(item?.judgement.fact == "busy")
        #expect(EngineJudge.idleOverheadPercent == 5)
    }

    @Test func unmeasuredEngineCPUIsInUse() async {
        let m = module(fakeDocker([]))
        let item = engine(await scanEveryMinute(m, to: 15, processes: dockerTable(), cpu: [:]))
        #expect(item?.judgement.verdict == .inUse)
        #expect(item?.judgement.fact == "measuring activity")
    }

    @Test func containerCPUIsNotCountedTwice() async throws {
        // Eight idle containers at 0.9% each run inside the VM: 7.2 of the VM's 9% are theirs.
        let rows = (1...8).map { Row(name: "c\($0)", cpu: "0.90%", port: 6_000 + $0) }
        let m = module(fakeDocker(rows))
        let cpu: [Int32: Double] = [100: 0.5, 101: 0.5, 102: 9, 103: 0]
        let items = await scanEveryMinute(m, to: 21, processes: dockerTable(), cpu: cpu)
        let docker = try #require(engine(items))
        #expect(docker.judgement.verdict == .idle)
        #expect(abs(docker.cores - 0.028) < 0.0001)   // 10% of the engine minus 7.2% of its containers
        let containerCores = items.filter { $0.id != docker.id }.reduce(0) { $0 + $1.cores }
        #expect(abs(containerCores - 0.072) < 0.0001)
    }

    @Test func aRunningOrbStackMachineKeepsItInUse() async {
        let d = fakeDocker([])
        d.set { $0.orbList = CommandResult(status: 0, stdout: "NAME    STATE    DISTRO  VERSION  ARCH\nubuntu  running  ubuntu  noble    arm64\n", stderr: "", timedOut: false) }
        let item = engine(await scanEveryMinute(module(d), to: 15, processes: orbStackTable(), cpu: quietOrbCPU), "OrbStack")
        #expect(item?.judgement.verdict == .inUse)
        #expect(item?.judgement.fact == "a Linux machine is running")
    }

    @Test func orbStackMachinesThatCantBeListedCountAsRunning() async {
        let d = fakeDocker([])
        d.set { $0.orbList = CommandResult(status: 1, stdout: "", stderr: "boom", timedOut: false) }
        let item = engine(await scanEveryMinute(module(d), to: 15, processes: orbStackTable(), cpu: quietOrbCPU), "OrbStack")
        #expect(item?.judgement.verdict == .inUse)
        #expect(item?.judgement.fact == "couldn't check its Linux machines")
    }

    @Test func orbStackWithOnlyStoppedMachinesCanBeIdle() async {
        let d = fakeDocker([])
        d.set { $0.orbList = CommandResult(status: 0, stdout: "NAME    STATE    DISTRO  VERSION  ARCH\nubuntu  stopped  ubuntu  noble    arm64\n", stderr: "", timedOut: false) }
        let item = engine(await scanEveryMinute(module(d), to: 10, processes: orbStackTable(), cpu: quietOrbCPU), "OrbStack")
        #expect(item?.judgement.verdict == .idle)
        #expect(d.calls.contains(["orb", "list"]))
    }

    @Test func orbListIsOnlyRunForOrbStack() async {
        let d = fakeDocker([])
        _ = await scanEveryMinute(module(d), to: 2, processes: dockerTable(), cpu: quietEngineCPU)
        #expect(!d.calls.contains { $0.first == "orb" })
    }

    @Test func parsesOrbList() {
        #expect(ContainersModule.parseOrbMachines("NAME STATE DISTRO\n") == EngineFacts.Machines.none)
        #expect(ContainersModule.parseOrbMachines("") == EngineFacts.Machines.none)
        #expect(ContainersModule.parseOrbMachines("No machines found\n") == EngineFacts.Machines.none)
        #expect(ContainersModule.parseOrbMachines("NAME STATE\nubuntu running\n") == .running)
        #expect(ContainersModule.parseOrbMachines("NAME STATE\na stopped\nb stopped\n") == EngineFacts.Machines.none)
        // A state we don't know counts as running.
        #expect(ContainersModule.parseOrbMachines("NAME STATE\na starting\n") == .running)
    }

    @Test func engineStopChecksForDockerClientsAgain() async {
        let quits = Mutex(0)
        let m = module(FakeDocker(), quit: { _ in quits.withLock { $0 += 1 }; return true })
        let item = Item(
            id: .engine(name: "Docker Desktop"), category: .containers, name: "Docker Desktop", symbol: "gearshape.2",
            judgement: Judgement(verdict: .idle, fact: "idle engine", signals: []), cores: 0, memoryBytes: 0,
            processes: [], detail: ["appPath": "/Applications/Docker.app"]
        )
        let building = processTable(.fixture(pid: 600, ppid: 50, name: "docker", path: "/usr/local/bin/docker", arguments: ["docker", "build", "."]))
        let result = await m.stop(item, ctx: .testContext(processes: building))
        #expect(result == .skipped(reason: "Docker Desktop is used by docker"))
        #expect(quits.withLock { $0 } == 0)
    }
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
        #expect(await module(d).scan(ctx(processes: dockerTable())).isEmpty)
    }

    @Test func idleOnlyAfterTheTenMinuteWindow() async throws {
        let d = fakeDocker([Row(name: "orbit-trust-pg")])
        let m = module(d)
        let first = await m.scan(ctx(0))
        #expect(first.count == 1)
        #expect(first[0].judgement.verdict == .inUse)

        // Five minutes in: still no baseline that is 10 minutes old.
        #expect(try #require(await m.scan(ctx(5)).first).judgement.verdict == .inUse)

        let later = try #require(await m.scan(ctx(11)).first)
        #expect(later.id == .container(name: "orbit-trust-pg"))
        #expect(later.category == .containers)
        #expect(later.judgement.verdict == .idle)
        #expect(later.judgement.fact == "idle 12 days")
        #expect(later.detail["image"] == "postgres:16")
        #expect(later.detail["ports"] == "5432")
    }

    @Test func baselineYoungerThanTenMinutesIsInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        let item = try #require(await m.scan(ctx(9.5)).first)
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "measuring traffic")
    }

    @Test func roundedDockerStatsCannotHideRealTraffic() async throws {
        // `docker stats` prints "251MB / 156MB" both times, but the exact counter moved by 2 MB.
        let d = fakeDocker([Row(name: "a", net: "251MB / 156MB", api: 407_000_000)])
        let m = module(d)
        _ = await m.scan(ctx(0))
        d.set { apply([Row(name: "a", net: "251MB / 156MB", api: 409_000_000)], to: &$0) }
        let item = try #require(await m.scan(ctx(11)).first)
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "busy")
    }

    @Test func tinyExactDeltaStaysIdle() async throws {
        let d = fakeDocker([Row(name: "a", api: 407_000_000)])
        let m = module(d)
        _ = await m.scan(ctx(0))
        d.set { apply([Row(name: "a", api: 407_001_000)], to: &$0) }
        #expect(try #require(await m.scan(ctx(11)).first).judgement.verdict == .idle)
    }

    @Test func deltaIsMeasuredAgainstTheBaselineNotTheLastScan() async throws {
        // Small steps every 30 s that add up to more than the threshold over 10+ minutes.
        let d = fakeDocker([Row(name: "a", api: 1_000_000)])
        let m = module(d)
        var minutes = 0.0
        var last: Item?
        while minutes <= 11 {
            d.set { apply([Row(name: "a", api: 1_000_000 + Int64(minutes * 60) * 500)], to: &$0) }   // 500 B/s
            last = await m.scan(ctx(minutes)).first
            minutes += 0.5
        }
        #expect(last?.judgement.verdict == .inUse)
        #expect(last?.judgement.fact == "busy")
    }

    @Test func lowCPUForLessThanTenMinutesIsInUse() async throws {
        let d = fakeDocker([Row(name: "a", cpu: "50.00%")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        // Busy at first, quiet only since minute 8; by minute 12 the traffic baseline is old enough but the CPU history is not.
        d.set { apply([Row(name: "a", cpu: "0.00%")], to: &$0) }
        _ = await m.scan(ctx(8))
        let item = try #require(await m.scan(ctx(12)).first)
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "measuring activity")
        // Ten minutes after it went quiet it is idle.
        #expect(try #require(await m.scan(ctx(18.5)).first).judgement.verdict == .idle)
    }

    @Test func aCPUBlipRestartsTheCPUWindow() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        d.set { apply([Row(name: "a", cpu: "35.00%")], to: &$0) }
        _ = await m.scan(ctx(6))
        d.set { apply([Row(name: "a", cpu: "0.00%")], to: &$0) }
        #expect(try #require(await m.scan(ctx(11)).first).judgement.verdict == .inUse)
    }

    @Test func unavailableEngineAPIIsInUse() async throws {
        let d = fakeDocker([Row(name: "a", api: nil)])
        let m = module(d)
        _ = await m.scan(ctx(0))
        let item = try #require(await m.scan(ctx(11)).first)
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "measuring traffic")
    }

    @Test func unavailableSocketIsInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        d.set { $0.socketOK = false }
        let m = module(d)
        _ = await m.scan(ctx(0))
        #expect(try #require(await m.scan(ctx(11)).first).judgement.verdict == .inUse)
        #expect(d.calls.allSatisfy { $0.first != "/usr/bin/curl" })
    }

    @Test func apiOutageResetsTheBaseline() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        d.set { apply([Row(name: "a", api: nil)], to: &$0) }
        _ = await m.scan(ctx(6))
        d.set { apply([Row(name: "a")], to: &$0) }
        #expect(try #require(await m.scan(ctx(11)).first).judgement.verdict == .inUse)   // history was dropped at minute 6
    }

    @Test func usesTheExactEngineAPICallAndSocketOnce() async {
        let d = fakeDocker([Row(name: "a"), Row(name: "b")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        _ = await m.scan(ctx(1))
        #expect(d.count("context") == 1)
        let curl = d.calls.filter { $0.first == "/usr/bin/curl" }
        #expect(curl.count == 4)
        #expect(Set(curl.map { $0.last ?? "" }) == [
            "http://localhost/containers/a/stats?stream=false&one-shot=true",
            "http://localhost/containers/b/stats?stream=false&one-shot=true",
        ])
        #expect(curl[0].starts(with: ["/usr/bin/curl", "--silent", "--max-time", "10", "--unix-socket", "/tmp/fake-docker.sock"]))
    }

    @Test func counterResetIsTreatedAsUnknown() async throws {
        let d = fakeDocker([Row(name: "a", api: 9_000_000)])
        let m = module(d)
        _ = await m.scan(ctx(0))
        d.set { apply([Row(name: "a", api: 1_000)], to: &$0) }
        #expect(try #require(await m.scan(ctx(11)).first).judgement.verdict == .inUse)
    }

    @Test func connectedClientMakesItInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        let item = try #require(await m.scan(ctx(11, sockets: [client5432])).first)
        #expect(item.judgement.verdict == .inUse)
        #expect(item.judgement.fact == "1 connection")
    }

    @Test func engineProxyOutboundSocketsAreNotClients() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        let procs = dockerTable()
        _ = await m.scan(ctx(0, processes: procs))
        let sockets = [SocketInfo(pid: 100, state: .established, localPort: 51_000, remotePort: 5432)]
        let items = await m.scan(ctx(11, processes: procs, sockets: sockets))
        #expect(items.first { $0.id == .container(name: "a") }?.judgement.verdict == .idle)
    }

    @Test func lanClientSeenOnlyThroughTheProxyMakesItInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        let procs = dockerTable()
        _ = await m.scan(ctx(0, processes: procs))
        let sockets = [SocketInfo(pid: 100, state: .established, localPort: 5432, remotePort: 60_000)]
        let items = await m.scan(ctx(11, processes: procs, sockets: sockets))
        #expect(items.first { $0.id == .container(name: "a") }?.judgement.verdict == .inUse)
        #expect(items.first { $0.id == .container(name: "a") }?.judgement.fact == "1 connection")
    }

    @Test func emitsEngineItemWhenEngineRunsAndEverythingIdle() async throws {
        let d = fakeDocker([Row(name: "a"), Row(name: "b", port: 5433)])
        let m = module(d)
        let procs = dockerTable()
        let cpu: [Int32: Double] = [100: 1, 101: 2, 102: 1.5, 103: 0]
        // The containers are idle from minute 10; the engine ten quiet minutes after that.
        let items = await scanEveryMinute(m, to: 20, processes: procs, cpu: cpu)
        #expect(items.count == 3)
        let engine = try #require(items.first { $0.id == .engine(name: "Docker Desktop") })
        #expect(engine.name == "Docker Desktop")
        #expect(engine.judgement.verdict == .idle)
        #expect(engine.judgement.fact == "idle engine")
        #expect(abs(engine.cores - 0.045) < 0.0001)   // 1 + 2 + 1.5 % of a core, VM CPU attributed
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
        _ = await m.scan(ctx(0, processes: procs))
        let sockets = [SocketInfo(pid: 900, state: .established, localPort: 51_000, remotePort: 5433)]
        let items = await m.scan(ctx(11, processes: procs, sockets: sockets))
        let engine = try #require(items.first { $0.id == .engine(name: "Docker Desktop") })
        #expect(engine.judgement.verdict == .inUse)
    }

    @Test func engineWithZeroContainersIsNotIdleOnSight() async throws {
        // No container running proves nothing: a build, a pull or a Linux machine may be using the engine.
        let d = fakeDocker([])
        let items = await module(d).scan(ctx(processes: dockerTable(), cpu: quietEngineCPU))
        #expect(items.count == 1)
        #expect(items[0].id == .engine(name: "Docker Desktop"))
        #expect(items[0].judgement.verdict == .inUse)
        #expect(items[0].judgement.fact == "measuring activity")
    }

    @Test func noEngineItemWhenNoEngineProcesses() async {
        let d = fakeDocker([Row(name: "a")])
        let items = await module(d).scan(ctx())
        #expect(items.allSatisfy { $0.id != .engine(name: "Docker Desktop") })
        #expect(items.first?.detail["engine"] == nil)
    }

    @Test func twoEnginesMakeTheEngineVerdictUncertain() async {
        let d = fakeDocker([])
        var procs = dockerTable()
        procs[10] = .fixture(pid: 10, name: "OrbStack", path: "/Applications/OrbStack.app/Contents/MacOS/OrbStack")
        let items = await module(d).scan(ctx(processes: procs))
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0.judgement.verdict == .inUse })
    }

    @Test func containerWhoseStatsCannotBeReadIsInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        d.set { $0.stats = "" }
        let m = module(d)
        _ = await m.scan(ctx(0))
        #expect(try #require(await m.scan(ctx(11)).first).judgement.verdict == .inUse)
    }

    @Test func containerWithoutInspectDataIsInUse() async throws {
        let d = fakeDocker([Row(name: "a")])
        d.set { $0.inspect = "" }
        let m = module(d)
        _ = await m.scan(ctx(0))
        #expect(try #require(await m.scan(ctx(11)).first).judgement.verdict == .inUse)
    }

    @Test func cachedScanDoesNotRunDockerAgain() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        _ = await m.scan(ctx(11))
        let before = d.calls.count
        func cached(_ minutes: Double, sockets: [SocketInfo] = []) -> ScanContext {
            ScanContext(now: fixedNow.addingTimeInterval(.minutes(minutes)), processes: [:], cpu: [:], sockets: sockets,
                        frontmostBundleID: nil, ownPID: getpid(), runExternal: false)
        }
        #expect(try #require(await m.scan(cached(11.2)).first).judgement.verdict == .idle)
        #expect(d.calls.count == before)
        // …but client connections are always live.
        #expect(try #require(await m.scan(cached(11.2, sockets: [client5432])).first).judgement.verdict == .inUse)
    }

    @Test func cachedScanBeforeAnyRealScanIsEmpty() async {
        let m = module(fakeDocker([Row(name: "a")]))
        let c = ScanContext(now: now, processes: [:], cpu: [:], sockets: [], frontmostBundleID: nil, ownPID: 1, runExternal: false)
        #expect(await m.scan(c).isEmpty)
    }

    @Test func inspectIsBatchedInOneCall() async {
        let d = fakeDocker([Row(name: "a"), Row(name: "b"), Row(name: "c")])
        _ = await module(d).scan(ctx())
        #expect(d.count("inspect") == 1)
        let inspect = d.calls.first { $0.dropFirst().first == "inspect" } ?? []
        #expect(Array(inspect.suffix(3)) == ["a", "b", "c"])
    }

    // MARK: stop / undo

    private func idleContainerItem(_ m: ContainersModule) async throws -> Item {
        _ = await m.scan(ctx(0))
        return try #require(await m.scan(ctx(11)).first)
    }

    @Test func stopsIdleContainerAndOffersUndo() async throws {
        let d = fakeDocker([Row(name: "evone-postgres")])
        let m = module(d)
        let item = try await idleContainerItem(m)
        let result = await m.stop(item, ctx: ctx(11))
        #expect(result == .stopped(UndoToken(identity: .container(name: "evone-postgres"), action: "start", arguments: ["evone-postgres"])))
        #expect(d.calls.last == ["docker", "stop", "evone-postgres"])
    }

    @Test func refusesToStopInUseContainer() async throws {
        let d = fakeDocker([Row(name: "a", cpu: "50.00%")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        let item = try #require(await m.scan(ctx(11)).first)
        #expect(item.judgement.verdict == .inUse)
        let result = await m.stop(item, ctx: ctx(11))
        guard case .skipped = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(d.count("stop") == 0)
    }

    @Test func forcedStopOfInUseContainerRunsDockerStop() async throws {
        let d = fakeDocker([Row(name: "a", cpu: "50.00%")])
        let m = module(d)
        _ = await m.scan(ctx(0))
        let item = try #require(await m.scan(ctx(11)).first)
        #expect(item.judgement.verdict == .inUse)
        d.set { $0.api["a"] = 999_000_000 }   // traffic, and a client, are ignored when forced
        let result = await m.stop(item, ctx: ctx(11, sockets: [client5432]), force: true)
        #expect(result == .stopped(UndoToken(identity: .container(name: "a"), action: "start", arguments: ["a"])))
        #expect(d.calls.last == ["docker", "stop", "a"])
    }

    @Test func forcedStopStillRefusesUnsafeContainerNames() async {
        let item = Item(
            id: .container(name: "--all"), category: .containers, name: "--all", symbol: "shippingbox",
            judgement: Judgement(verdict: .inUse, fact: "busy", signals: []), cores: 0, memoryBytes: 0, processes: [], detail: [:]
        )
        let d = FakeDocker()
        guard case .failed = await module(d).stop(item, ctx: .testContext(), force: true) else { Issue.record("expected failure"); return }
        #expect(d.count("stop") == 0)
    }

    @Test func rechecksClientsRightBeforeStopping() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        let item = try await idleContainerItem(m)
        let result = await m.stop(item, ctx: ctx(11, sockets: [client5432]))
        guard case .skipped = result else { Issue.record("expected skipped, got \(result)"); return }
        #expect(d.count("stop") == 0)
    }

    @Test func rechecksExactTrafficRightBeforeStopping() async throws {
        let d = fakeDocker([Row(name: "a", api: 407_000_000)])
        let m = module(d)
        let item = try await idleContainerItem(m)
        d.set { $0.api["a"] = 407_500_000 }   // 500 kB since the scan
        guard case .skipped = await m.stop(item, ctx: ctx(11)) else { Issue.record("expected skipped"); return }
        #expect(d.count("stop") == 0)
    }

    @Test func doesNotStopWhenTrafficCannotBeRechecked() async throws {
        let d = fakeDocker([Row(name: "a")])
        let m = module(d)
        let item = try await idleContainerItem(m)
        d.set { $0.api = [:] }
        guard case .skipped = await m.stop(item, ctx: ctx(11)) else { Issue.record("expected skipped"); return }
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

    @Test func engineIsNeverForced() async {
        let m = module(FakeDocker(), quit: { _ in Issue.record("must not quit"); return true })
        let item = engineItem(.dockerDesktop, verdict: .inUse, appPath: "/Applications/Docker.app")
        guard case .skipped = await m.stop(item, ctx: .testContext(), force: true) else {
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
