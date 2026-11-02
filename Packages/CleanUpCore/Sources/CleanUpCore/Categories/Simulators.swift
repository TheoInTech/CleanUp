import Darwin
import Foundation
import os

// MARK: - Facts and judgement

public struct SimulatorFacts: Sendable {
    public let udid: String
    public let name: String
    /// Earliest start among the device's processes; nil when none could be attributed.
    public let bootedAt: Date?
    public let lastAppLaunch: Date?
    public let lastAppName: String?
    /// Names of non-simulator processes (e.g. `xcodebuild`) whose arguments mention the UDID.
    public let referencedBy: [String]
    public let simulatorAppFrontmost: Bool
    public let cores: Double

    public init(
        udid: String, name: String, bootedAt: Date?, lastAppLaunch: Date?, lastAppName: String?,
        referencedBy: [String], simulatorAppFrontmost: Bool, cores: Double
    ) {
        self.udid = udid
        self.name = name
        self.bootedAt = bootedAt
        self.lastAppLaunch = lastAppLaunch
        self.lastAppName = lastAppName
        self.referencedBy = referencedBy
        self.simulatorAppFrontmost = simulatorAppFrontmost
        self.cores = cores
    }
}

public enum SimulatorJudge {
    /// A booted simulator must have been quiet for this long before it counts as idle.
    public static let quietPeriod: TimeInterval = 60 * 60

    /// Idle only when every condition holds; anything unknown is in use.
    public static func judge(_ f: SimulatorFacts, now: Date) -> Judgement {
        var signals: [Signal] = []
        var reasons: [String] = []   // in-use reasons, strongest first

        if f.referencedBy.isEmpty {
            signals.append(Signal(kind: .idle, text: "Nothing is building for it"))
        } else {
            let names = f.referencedBy.joined(separator: ", ")
            signals.append(Signal(kind: .inUse, text: "Used by \(names)"))
            reasons.append("used by \(names)")
        }

        if f.simulatorAppFrontmost {
            signals.append(Signal(kind: .inUse, text: "The Simulator app is in front"))
            reasons.append("Simulator is in front")
        } else {
            signals.append(Signal(kind: .idle, text: "The Simulator app is in the background"))
        }

        if let launch = f.lastAppLaunch {
            let age = now.timeIntervalSince(launch)
            let app = f.lastAppName ?? "An app"
            if age < quietPeriod {
                signals.append(Signal(kind: .inUse, text: "\(app) opened \(RelativeAge.short(age)) ago"))
                reasons.append("\(app) opened \(RelativeAge.short(age)) ago")
            } else {
                signals.append(Signal(kind: .idle, text: "\(app) last opened \(RelativeAge.short(age)) ago"))
            }
        } else {
            signals.append(Signal(kind: .idle, text: "No app opened since it booted"))
        }

        if let booted = f.bootedAt {
            let age = now.timeIntervalSince(booted)
            if age < quietPeriod {
                signals.append(Signal(kind: .inUse, text: "Booted \(RelativeAge.short(age)) ago"))
                reasons.append("booted \(RelativeAge.short(age)) ago")
            } else {
                signals.append(Signal(kind: .idle, text: "Booted \(RelativeAge.short(age)) ago"))
            }
        } else {
            signals.append(Signal(kind: .inUse, text: "Can't tell when it booted"))
            reasons.append("boot time unknown")
        }

        if let reason = reasons.first {
            return Judgement(verdict: .inUse, fact: reason, signals: signals)
        }
        // No reason above means bootedAt is known; idle time runs from the latest activity.
        let since = max(f.bootedAt ?? .distantPast, f.lastAppLaunch ?? .distantPast)
        return Judgement(verdict: .idle, fact: "idle \(RelativeAge.short(now.timeIntervalSince(since)))", signals: signals)
    }
}

// MARK: - Module

public struct SimulatorsModule: CategoryModule {
    public var id: CategoryID { .simulators }

    static let engineIdentity = ItemIdentity.engine(name: "simulator-services")
    static let simulatorBundleID = "com.apple.iphonesimulator"
    static let engineBusyCores = 0.2
    private static let simctlTimeout: Duration = .seconds(10)

    typealias BootedDevice = (udid: String, name: String)

    /// Last good `simctl` answer, reused when a refresh runs with `runExternal == false`.
    private let cache = OSAllocatedUnfairLock<[BootedDevice]?>(uncheckedState: nil)

    /// Runs an external command with a timeout; injectable for tests.
    public typealias Run = @Sendable (String, [String], Duration) async -> CommandResult
    private let run: Run

    public init(run: Run? = nil) {
        self.run = run ?? { await CommandRunner.run($0, $1, timeout: $2) }
    }

    // MARK: scan

    public func scan(_ ctx: ScanContext) async -> [Item] {
        let devices: [BootedDevice]?
        if ctx.runExternal {
            devices = await Self.listBooted()
            cache.withLockUnchecked { $0 = devices }
        } else {
            devices = cache.withLockUnchecked { $0 }
        }
        // simctl failed or never ran: we don't know what is booted, so claim nothing.
        guard let devices else { return [] }
        return Self.buildItems(devices: devices, ctx: ctx)
    }

    private static func listBooted() async -> [BootedDevice]? {
        let result = await CommandRunner.run("xcrun", ["simctl", "list", "devices", "booted", "-j"], timeout: simctlTimeout)
        guard !result.timedOut, result.status == 0 else { return nil }
        return try? parseBooted(result.stdout)
    }

    /// Booted devices from `xcrun simctl list devices booted -j`, sorted by name.
    public static func parseBooted(_ json: String) throws -> [(udid: String, name: String)] {
        struct Listing: Decodable {
            struct Device: Decodable { let udid: String; let name: String; let state: String }
            let devices: [String: [Device]]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: Data(json.utf8))
        return listing.devices.values.flatMap { $0 }
            .filter { $0.state == "Booted" }
            .sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
            .map { (udid: $0.udid, name: $0.name) }
    }

    // MARK: items

    static func buildItems(devices: [BootedDevice], ctx: ScanContext) -> [Item] {
        var items = devices.map { item(udid: $0.udid, name: $0.name, ctx: ctx) }
        if devices.isEmpty, !simulatorLauncherExists(ctx.processes), let engine = engineItem(ctx: ctx) { items.append(engine) }
        return items
    }

    private static func item(udid: String, name: String, ctx: ScanContext) -> Item {
        let owned = deviceProcesses(udid: udid, in: ctx.processes)
        let facts = Self.facts(udid: udid, name: name, ctx: ctx)
        var detail = ["udid": udid]
        if let app = facts.lastAppName { detail["lastApp"] = app }
        if !facts.referencedBy.isEmpty { detail["usedBy"] = facts.referencedBy.joined(separator: ", ") }
        return Item(
            id: .simulator(udid: udid),
            category: .simulators,
            name: name,
            symbol: "iphone",
            judgement: SimulatorJudge.judge(facts, now: ctx.now),
            cores: facts.cores,
            memoryBytes: owned.reduce(0) { $0 + $1.residentBytes },
            processes: owned.sorted { $0.pid < $1.pid }.map(\.ref),
            detail: detail
        )
    }

    static func facts(udid: String, name: String, ctx: ScanContext) -> SimulatorFacts {
        let owned = deviceProcesses(udid: udid, in: ctx.processes)
        let ownedPIDs = Set(owned.map(\.pid))
        let launches = owned.filter { $0.path.contains("/data/Containers/Bundle/Application/") }
        let lastLaunch = launches.max { $0.startTime < $1.startTime }
        let cores = owned.reduce(0.0) { $0 + (ctx.cpu[$1.pid] ?? 0) } / 100

        let ownDescendants = descendants(of: [ctx.ownPID], in: ctx.processes)
        let referencing = ctx.processes.values.filter { process in
            !ownedPIDs.contains(process.pid)
                && process.pid != ctx.ownPID && !ownDescendants.contains(process.pid)
                && !isSimulatorInfrastructure(process)
                && mentions(process.arguments, udid)
        }
        let names = Set(referencing.map { $0.name.isEmpty ? ($0.path as NSString).lastPathComponent : $0.name })

        return SimulatorFacts(
            udid: udid,
            name: name,
            bootedAt: owned.map(\.startTime).min(),
            lastAppLaunch: lastLaunch?.startTime,
            lastAppName: lastLaunch.map(appName),
            referencedBy: names.sorted(),
            simulatorAppFrontmost: ctx.frontmostBundleID == simulatorBundleID,
            cores: cores
        )
    }

    // MARK: attribution

    /// Processes belonging to the device: path or arguments inside `/Devices/<UDID>/`, plus
    /// everything descending from that device's `launchd_sim`.
    private static func deviceProcesses(udid: String, in table: [Int32: ProcessInfoRecord]) -> [ProcessInfoRecord] {
        let marker = "/Devices/\(udid)/"
        let direct = table.values.filter { containsIgnoringCase($0.path, marker) || mentions($0.arguments, marker) }
        let launchers = direct.filter { $0.name == "launchd_sim" || ($0.path as NSString).lastPathComponent == "launchd_sim" }
        var pids = Set(direct.map(\.pid))
        pids.formUnion(descendants(of: Set(launchers.map(\.pid)), in: table))
        return pids.compactMap { table[$0] }
    }

    private static func descendants(of roots: Set<Int32>, in table: [Int32: ProcessInfoRecord]) -> Set<Int32> {
        guard !roots.isEmpty else { return [] }
        var children: [Int32: [Int32]] = [:]
        for process in table.values where process.pid != process.ppid { children[process.ppid, default: []].append(process.pid) }
        var found = Set<Int32>()
        var queue = Array(roots)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where found.insert(child).inserted { queue.append(child) }
        }
        return found
    }

    /// CoreSimulator's own services and the Simulator app never count as "something using" a device.
    /// Matched by exact executable name, never by path: the real `simctl` also lives inside
    /// CoreSimulator.framework and must stay a referencer.
    private static func isSimulatorInfrastructure(_ p: ProcessInfoRecord) -> Bool {
        let leaf = (p.path as NSString).lastPathComponent
        return [p.name, leaf].contains { name in
            name == "Simulator" || name == "launchd_sim" || name == "SimMetalHost" || name == "SimRenderServer"
                || name.hasPrefix("SimLaunchHost") || name.hasPrefix("SimulatorTrampoline")
                || name.hasSuffix("CoreSimulatorService")
        } || p.name.hasPrefix("com.apple.CoreSimulator.CoreSim")   // the kernel truncates long names
    }

    /// A `launchd_sim` exists, so some simulator is booting or booted, whatever the cached device list says.
    private static func simulatorLauncherExists(_ table: [Int32: ProcessInfoRecord]) -> Bool {
        table.values.contains { $0.name == "launchd_sim" || ($0.path as NSString).lastPathComponent == "launchd_sim" }
    }

    private static func mentions(_ arguments: [String], _ needle: String) -> Bool {
        arguments.contains { containsIgnoringCase($0, needle) }
    }

    private static func containsIgnoringCase(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    private static func appName(_ p: ProcessInfoRecord) -> String {
        if !p.name.isEmpty { return p.name }
        return (p.path as NSString).lastPathComponent
    }

    // MARK: engine item

    private static func isEngineProcess(_ p: ProcessInfoRecord) -> Bool {
        let leaf = (p.path as NSString).lastPathComponent
        return [p.name, leaf].contains { $0 == "SimMetalHost" || $0 == "SimRenderServer" || $0.hasSuffix("CoreSimulatorService") }
            || p.name.hasPrefix("com.apple.CoreSimulator.CoreSim")   // the kernel truncates long names
    }

    /// The CoreSimulator background services, emitted only when nothing is booted yet they burn CPU.
    private static func engineItem(ctx: ScanContext) -> Item? {
        let mine = ctx.processes.values.filter { $0.uid == getuid() && isEngineProcess($0) }
        let cores = mine.reduce(0.0) { $0 + (ctx.cpu[$1.pid] ?? 0) } / 100
        guard !mine.isEmpty, cores > engineBusyCores else { return nil }
        let usage = String(format: "%.1f", cores)
        return Item(
            id: engineIdentity,
            category: .simulators,
            name: "Simulator services",
            symbol: "gearshape.2",
            judgement: Judgement(
                verdict: .idle,
                fact: "no simulator booted, using \(usage) cores",
                signals: [
                    Signal(kind: .idle, text: "No simulator is booted"),
                    Signal(kind: .idle, text: "Background services using \(usage) cores"),
                    Signal(kind: .neutral, text: "They restart on demand"),
                ]
            ),
            cores: cores,
            memoryBytes: mine.reduce(0) { $0 + $1.residentBytes },
            processes: mine.sorted { $0.pid < $1.pid }.map(\.ref),
            detail: ["processes": mine.map(\.name).sorted().joined(separator: ", ")]
        )
    }

    // MARK: stop / undo

    public func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult {
        // The simulator services are an engine: never forced.
        let isEngine = item.id == Self.engineIdentity
        guard item.judgement.verdict == .idle || (force && !isEngine) else {
            return .skipped(reason: "\(item.name) is in use")
        }
        if isEngine {
            return Self.stopEngine(item, ctx: ctx)
        }
        guard let udid = item.detail["udid"], UUID(uuidString: udid) != nil else {
            return .failed(reason: "Missing or malformed simulator id")
        }
        let result = await run("xcrun", ["simctl", "shutdown", udid], Self.simctlTimeout)
        if result.timedOut { return .failed(reason: "simctl shutdown timed out") }
        // Already shut down by someone else: the goal is met.
        if result.status != 0, !result.stderr.contains("current state: Shutdown") {
            return .failed(reason: Self.firstLine(result.stderr, fallback: "simctl shutdown failed (\(result.status))"))
        }
        return .stopped(UndoToken(identity: item.id, action: "boot", arguments: [udid]))
    }

    private static func stopEngine(_ item: Item, ctx: ScanContext) -> StopResult {
        // The item may be from a cached scan; never kill the services under a simulator that is starting.
        if simulatorLauncherExists(ctx.processes) { return .skipped(reason: "a simulator is starting") }
        let outcome = ProcessSignaler.terminate(item.processes)
        if !outcome.refused.isEmpty {
            return .failed(reason: "Couldn't stop \(outcome.refused.count) simulator service process(es)")
        }
        return .stopped(nil)   // they relaunch on demand; nothing to undo
    }

    public func undo(_ token: UndoToken) async -> Bool {
        guard token.action == "boot", token.arguments.count == 1,
              let udid = token.arguments.first, UUID(uuidString: udid) != nil else { return false }
        let result = await run("xcrun", ["simctl", "boot", udid], Self.simctlTimeout)
        return !result.timedOut && (result.status == 0 || result.stderr.contains("current state: Booted"))
    }

    private static func firstLine(_ text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)
        return (line?.isEmpty == false ? line : nil) ?? fallback
    }
}
