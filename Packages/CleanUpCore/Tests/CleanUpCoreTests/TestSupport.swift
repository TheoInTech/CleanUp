import Foundation
import os
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
    static func fixtureDevServer(
        ref: ProcessRef = ProcessRef(pid: 86_037, startTime: now.addingTimeInterval(-.days(18))),
        verdict: Verdict = .idle,
        ports: [Int] = [8081],
        project: String = "evone/apps/mobile",
        command: String = "node expo start",
        name: String = "expo start :8081"
    ) -> Item {
        Item(
            id: .devServer(cwd: "/Users/u/Projects/evone/apps/mobile", command: "expo start :8081"),
            category: .devServers,
            name: name,
            symbol: "server.rack",
            judgement: Judgement(verdict: verdict, fact: "running 18 days", signals: []),
            cores: 0,
            memoryBytes: 0,
            processes: [ref],
            detail: ["command": command, "project": project, "ports": ports.map(String.init).joined(separator: ",")]
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

// MARK: - Engine test support

/// A `UserDefaults` on a unique suite whose on-disk domain is removed when the last reference goes away.
final class EphemeralUserDefaults: UserDefaults, @unchecked Sendable {
    private let suite: String

    init(suite: String) {
        self.suite = suite
        super.init(suiteName: suite)!
    }

    deinit { removePersistentDomain(forName: suite) }
}

extension UserDefaults {
    /// A unique, throwaway suite, removed after use.
    static func ephemeral() -> UserDefaults {
        EphemeralUserDefaults(suite: "io.cleanup.tests.\(UUID().uuidString)")
    }
}

/// A module with canned scan items and canned stop results (handed out in order; `.stopped(nil)` once
/// they run out). Records every stop and undo it receives;
/// undo fails for the identities in `undoFailing`.
struct StubModule: CategoryModule {
    struct Calls: Sendable {
        var scans = 0
        var stopped: [ItemIdentity] = []
        var forced: [ItemIdentity] = []
        var undone: [UndoToken] = []
        var contexts: [ScanContext] = []
    }

    let id: CategoryID
    let items: [Item]
    private let results: OSAllocatedUnfairLock<[StopResult]>
    private let undoFailing: Set<ItemIdentity>
    let calls: OSAllocatedUnfairLock<Calls>
    /// A copy of what was recorded so far.
    var log: Calls { calls.withLock { $0 } }
    /// Shared across modules to observe the global stop order.
    let order: OSAllocatedUnfairLock<[ItemIdentity]>

    init(
        id: CategoryID,
        items: [Item] = [],
        results: [StopResult] = [],
        undoFailing: Set<ItemIdentity> = [],
        order: OSAllocatedUnfairLock<[ItemIdentity]> = OSAllocatedUnfairLock(initialState: [])
    ) {
        self.id = id
        self.items = items
        self.results = OSAllocatedUnfairLock(initialState: results)
        self.undoFailing = undoFailing
        self.calls = OSAllocatedUnfairLock(initialState: Calls())
        self.order = order
    }

    func scan(_ ctx: ScanContext) async -> [Item] {
        calls.withLock { $0.scans += 1; $0.contexts.append(ctx) }
        return items
    }

    func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult {
        calls.withLock {
            $0.stopped.append(item.id)
            $0.contexts.append(ctx)
            if force { $0.forced.append(item.id) }
        }
        order.withLock { $0.append(item.id) }
        return results.withLock { $0.isEmpty ? .stopped(nil) : $0.removeFirst() }
    }

    func undo(_ token: UndoToken) async -> Bool {
        calls.withLock { $0.undone.append(token) }
        return !undoFailing.contains(token.identity)
    }
}

/// A module whose scan never comes back in time (and ignores cancellation). The first
/// `answeredScans` scans answer normally with `items`.
struct HangingModule: CategoryModule {
    let id: CategoryID
    let items: [Item]
    private let answered: OSAllocatedUnfairLock<Int>

    init(id: CategoryID, items: [Item] = [], answeredScans: Int = 0) {
        self.id = id
        self.items = items
        self.answered = OSAllocatedUnfairLock(initialState: answeredScans)
    }

    func scan(_ ctx: ScanContext) async -> [Item] {
        let answer = answered.withLock { left in
            defer { left = max(0, left - 1) }
            return left > 0
        }
        if answer { return items }
        // Not cancellable: the scanner must give up on it, not wait for it.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { continuation.resume(returning: []) }
        }
    }

    func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult { .failed(reason: "hanging") }
    func undo(_ token: UndoToken) async -> Bool { false }
}

extension Item {
    static func fixture(
        _ id: ItemIdentity,
        category: CategoryID,
        name: String? = nil,
        verdict: Verdict = .idle,
        cores: Double = 0,
        detail: [String: String] = [:]
    ) -> Item {
        Item(
            id: id, category: category, name: name ?? id.rawValue, symbol: "circle",
            judgement: Judgement(verdict: verdict, fact: verdict.rawValue, signals: []),
            cores: cores, memoryBytes: 0, processes: [], detail: detail
        )
    }

    static func fixtureContainer(
        name: String = "evone-postgres",
        verdict: Verdict = .idle,
        cores: Double = 0,
        engine: String? = "Docker Desktop"
    ) -> Item {
        var detail = ["image": "postgres:16"]
        if let engine { detail["engine"] = engine }
        return .fixture(.container(name: name), category: .containers, name: name, verdict: verdict, cores: cores, detail: detail)
    }

    static func fixtureEngine(_ name: String = "Docker Desktop", verdict: Verdict = .idle, cores: Double = 0) -> Item {
        .fixture(.engine(name: name), category: .containers, name: name, verdict: verdict, cores: cores)
    }

    static func fixtureSimulator(
        udid: String = "F92ECACE-D87E-40D2-93F3-32974DED72BF",
        name: String = "iPhone Duo",
        verdict: Verdict = .idle,
        cores: Double = 1
    ) -> Item {
        .fixture(.simulator(udid: udid), category: .simulators, name: name, verdict: verdict, cores: cores, detail: ["udid": udid])
    }
}

extension BatteryReading {
    /// The incident: 95 W drain, 35 minutes left.
    static func incident(onBattery: Bool = true) -> BatteryReading {
        BatteryReading(
            onBattery: onBattery, percent: 40, drainWatts: onBattery ? 95 : nil,
            minutesLeft: onBattery ? 35 : nil, healthPercent: 93, cycleCount: 221
        )
    }
}

extension Snapshot {
    /// The real incident: 6 booted simulators (4 idle, 2 in use), 8 containers (7 idle, `evone-postgres`
    /// in use) under Docker Desktop, Steam open, 95 W drain with 35 minutes left.
    static func incident(onBattery: Bool = true, mood: Mood? = nil) -> Snapshot {
        incident(onBattery: onBattery, mood: mood, postgresVerdict: .inUse)
    }

    /// The incident with `evone-postgres` idle too, so the Docker Desktop engine is idle.
    static func incidentAllContainersIdle() -> Snapshot {
        incident(onBattery: true, mood: nil, postgresVerdict: .idle)
    }

    private static func incident(onBattery: Bool, mood: Mood?, postgresVerdict: Verdict) -> Snapshot {
        let simulators: [Item] = [
            .fixtureSimulator(udid: "F92ECACE-D87E-40D2-93F3-32974DED72BF", name: "iPhone Duo", verdict: .idle, cores: 1.2),
            .fixtureSimulator(udid: "1AC8D351-981F-439F-9A2D-AB2DF85DE448", name: "Orbit Duo Layout QA", verdict: .idle, cores: 1.1),
            .fixtureSimulator(udid: "59D609E5-0299-44F7-98BF-A83CF9601F36", name: "Orbit iPhone Duo", verdict: .idle, cores: 1.0),
            .fixtureSimulator(udid: "13CCBF93-1281-497A-B7F3-1B8D2D531B4F", name: "EVOne SE check", verdict: .idle, cores: 0.9),
            .fixtureSimulator(udid: "10EBDE8C-B5D1-47E1-8B8A-5621F07127FA", name: "iPhone 18 Pro", verdict: .inUse, cores: 1.5),
            .fixtureSimulator(udid: "31049A9E-927D-49D6-9304-E80B2D6514C3", name: "iPhone 17", verdict: .inUse, cores: 1.3),
        ]
        let idleContainers = [
            "paorder-shop-postgres-1", "paorder-shop-s3-1", "pasab-ai-postgres-1",
            "savio-finance-app-mailpit-1", "evone-pg-account-deletion", "evone-pg-dm17-int", "evone-routing",
        ]
        let containers: [Item] = idleContainers.map { Item.fixtureContainer(name: $0, cores: 0.1) }
            + [.fixtureContainer(name: "evone-postgres", verdict: postgresVerdict, cores: 0.3)]
        let engineVerdict = ContainersModule.engineJudgement(containerVerdicts: containers.map(\.judgement.verdict)).verdict
        let engine = Item.fixtureEngine(verdict: engineVerdict, cores: 1.0)
        let steam = Item.fixture(.app(bundleID: "com.valvesoftware.steam"), category: .apps, name: "Steam", verdict: .manual, cores: 0.6)

        let categories = [
            CategorySummary(id: .simulators, items: simulators),
            CategorySummary(id: .containers, items: containers + [engine]),
            CategorySummary(id: .apps, items: [steam]),
        ]
        let battery = BatteryReading.incident(onBattery: onBattery)
        let coresBusy = 10.5
        return Snapshot(
            date: fixedNow, battery: battery, coresBusy: coresBusy,
            swapUsedBytes: 0, swapTotalBytes: 0, uptime: .days(3), categories: categories,
            mood: mood ?? StatusCalculator.mood(battery: battery, coresBusy: coresBusy, drainHistory: Array(repeating: 95, count: 5))
        )
    }

    /// The item with this identity; fails the test when it isn't there.
    func item(_ id: ItemIdentity) -> Item {
        guard let item = categories.lazy.flatMap(\.items).first(where: { $0.id == id }) else {
            Issue.record("no item \(id.rawValue) in snapshot")
            return .fixture(id, category: .simulators)
        }
        return item
    }
}

/// A module whose scans take the given times in turn (not cancellable), then answer at once.
struct SlowModule: CategoryModule {
    let id: CategoryID
    let items: [Item]
    private let delays: OSAllocatedUnfairLock<[TimeInterval]>

    init(id: CategoryID, items: [Item], delays: [TimeInterval]) {
        self.id = id
        self.items = items
        self.delays = OSAllocatedUnfairLock(initialState: delays)
    }

    func scan(_ ctx: ScanContext) async -> [Item] {
        let delay = delays.withLock { $0.isEmpty ? 0 : $0.removeFirst() }
        guard delay > 0 else { return items }
        let items = self.items
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { continuation.resume(returning: items) }
        }
    }

    func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult { .failed(reason: "slow") }
    func undo(_ token: UndoToken) async -> Bool { false }
}
