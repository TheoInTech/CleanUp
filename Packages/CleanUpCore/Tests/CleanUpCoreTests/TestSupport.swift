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

/// A copy of a system binary in a temp directory. macOS kills a copied platform binary as soon as it
/// runs, so the copy is re-signed ad hoc first. Unprotected path, so the signaler treats it as user software.
/// The caller removes `copy.deletingLastPathComponent()` when done.
func throwawayCopy(of source: String, named name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let copy = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: copy)
    let sign = Process()
    sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    sign.arguments = ["-f", "-s", "-", copy.path]
    sign.standardError = FileHandle.nullDevice
    try sign.run()
    sign.waitUntilExit()
    try #require(sign.terminationStatus == 0)
    return copy
}

func loadFixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

var fixtureSimctlJSON: String {
    get throws { try loadFixture("incident") }
}

extension RunningAppInfo {
    /// A regular app that was last in front `lastUsedAgo` before `now` (nil = no activation recorded).
    static func fixture(
        _ bundleID: String,
        lastUsedAgo: TimeInterval? = nil,
        name: String? = nil,
        path: String? = nil,
        pid: Int32 = 4242
    ) -> RunningAppInfo {
        let name = name ?? String(bundleID.split(separator: ".").last ?? "App")
        return RunningAppInfo(
            bundleID: bundleID, name: name, bundlePath: path ?? "/Applications/\(name).app", pid: pid,
            lastActivated: lastUsedAgo.map { now.addingTimeInterval(-$0) }
        )
    }
}

extension Item {
    static func fixtureTab(pid: Int32 = 555, browser: String = "Brave", cpu: Double = 140) -> Item {
        Item(
            id: .browserTab(pid: pid),
            category: .browserTabs,
            name: "\(browser) tab",
            symbol: "globe",
            judgement: Judgement(verdict: .check, fact: "using 1.4 cores", signals: []),
            cores: cpu / 100,
            memoryBytes: 0,
            processes: [ProcessRef(pid: pid, startTime: now.addingTimeInterval(-.hours(2)))],
            detail: ["browser": browser]
        )
    }
}
