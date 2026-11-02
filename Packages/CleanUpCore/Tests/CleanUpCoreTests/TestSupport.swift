import Foundation
import Testing
@testable import CleanUpCore

// Shared helpers for category tests. Later tasks extend this file.

extension TimeInterval {
    static func days(_ n: Double) -> TimeInterval { n * 86_400 }
    static func hours(_ n: Double) -> TimeInterval { n * 3_600 }
    static func minutes(_ n: Double) -> TimeInterval { n * 60 }
}

/// The fixed "current time" every test uses. (`now` reads better in tests; `fixedNow` is for
/// extensions of types that have their own `now` member.)
let fixedNow = Date(timeIntervalSince1970: 1_793_000_000)
let now = fixedNow

extension ScanContext {
    static func testContext(
        now: Date = fixedNow,
        processes: [Int32: ProcessInfoRecord] = [:],
        cpu: [Int32: Double] = [:],
        sockets: [SocketInfo] = [],
        frontmost: String? = nil
    ) -> ScanContext {
        ScanContext(
            now: now, processes: processes, cpu: cpu, sockets: sockets,
            frontmostBundleID: frontmost, ownPID: getpid(), runExternal: true
        )
    }
}

extension ProcessInfoRecord {
    static func fixture(
        pid: Int32 = 100,
        ppid: Int32 = 1,
        uid: uid_t = getuid(),
        name: String? = nil,
        path: String = "",
        arguments: [String] = [],
        cwd: String? = nil,
        startedAgo: TimeInterval = .hours(1),
        start: Date? = nil,
        residentBytes: UInt64 = 0
    ) -> ProcessInfoRecord {
        let name = name ?? (path as NSString).lastPathComponent
        return ProcessInfoRecord(
            pid: pid, ppid: ppid, pgid: pid, uid: uid, name: name,
            path: path.isEmpty ? name : path,
            arguments: arguments.isEmpty ? [name] : arguments,
            cwd: cwd, startTime: start ?? now.addingTimeInterval(-startedAgo),
            cpuTimeNanos: 0, residentBytes: residentBytes
        )
    }
}

/// Table keyed by pid, as `ProcessTable.snapshot()` returns it.
func processTable(_ records: ProcessInfoRecord...) -> [Int32: ProcessInfoRecord] {
    Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
}

extension SimulatorFacts {
    static func fixture(
        bootedAgo: TimeInterval?,
        lastLaunchAgo: TimeInterval? = nil,
        app: String = "Orbit",
        referencedBy: [String] = [],
        frontmost: Bool = false,
        cores: Double = 0
    ) -> SimulatorFacts {
        SimulatorFacts(
            udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF",
            name: "iPhone Duo",
            bootedAt: bootedAgo.map { now.addingTimeInterval(-$0) },
            lastAppLaunch: lastLaunchAgo.map { now.addingTimeInterval(-$0) },
            lastAppName: lastLaunchAgo == nil ? nil : app,
            referencedBy: referencedBy,
            simulatorAppFrontmost: frontmost,
            cores: cores
        )
    }
}

extension ContainerFacts {
    static func fixture(
        name: String = "evone-postgres",
        cpu: Double = 0,
        clients: Int = 0,
        net: Int64? = 0,
        age: TimeInterval = .days(12),
        image: String = "postgres:16",
        ports: [Int] = [5432]
    ) -> ContainerFacts {
        ContainerFacts(
            name: name, image: image, startedAt: now.addingTimeInterval(-age), cpuPercent: cpu,
            publishedPorts: ports, clientConnections: clients, netBytesDelta: net
        )
    }
}

extension DevServerFacts {
    static func fixture(
        age: TimeInterval = .days(18),
        established: Int = 0,
        cpu: Double = 0,
        orphaned: Bool = false,
        lastSeenAgo: TimeInterval? = nil,
        observedFor: TimeInterval = .hours(1),
        command: String = "expo start",
        ports: [Int] = [8081]
    ) -> DevServerFacts {
        DevServerFacts(
            ref: ProcessRef(pid: 86_037, startTime: now.addingTimeInterval(-age)),
            command: command,
            projectName: "evone/apps/mobile",
            cwd: "/Users/u/Projects/evone/apps/mobile",
            ports: ports,
            establishedNow: established,
            lastConnectionSeen: lastSeenAgo.map { now.addingTimeInterval(-$0) },
            cpuPercent: cpu,
            orphaned: orphaned,
            observedFor: observedFor
        )
    }
}

extension Item {
    static func fixtureDevServer(ref: ProcessRef, verdict: Verdict = .idle, ports: [Int] = [8081]) -> Item {
        Item(
            id: .devServer(cwd: "/Users/u/Projects/evone/apps/mobile", command: "expo start :8081"),
            category: .devServers,
            name: "expo start :8081",
            symbol: "server.rack",
            judgement: Judgement(verdict: verdict, fact: "running 18 days", signals: []),
            cores: 0,
            memoryBytes: 0,
            processes: [ref],
            detail: ["command": "node expo start", "ports": ports.map(String.init).joined(separator: ",")]
        )
    }
}

func loadFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

var fixtureSimctlJSON: String {
    get throws { try loadFixture("incident") }
}
