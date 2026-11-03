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
    /// When the Simulator app was last in front (CleanUp's activation log); nil when never seen.
    public let simulatorLastInFront: Date?
    /// Since when CleanUp has been recording which app is in front without a gap (this launch).
    public let frontTrackedSince: Date
    /// CPU of the device's own apps (under its Containers/Bundle/Application), 100 = one core;
    /// nil when one of them hasn't been measured yet.
    public let appCPUPercent: Double?
    /// Debuggers attached to one of the device's processes (`debugserver`, `lldb`, …).
    public let debuggedBy: [String]

    public init(
        udid: String, name: String, bootedAt: Date?, lastAppLaunch: Date?, lastAppName: String?,
        referencedBy: [String], simulatorAppFrontmost: Bool, cores: Double,
        simulatorLastInFront: Date?, frontTrackedSince: Date, appCPUPercent: Double?, debuggedBy: [String]
    ) {
        self.udid = udid
        self.name = name
        self.bootedAt = bootedAt
        self.lastAppLaunch = lastAppLaunch
        self.lastAppName = lastAppName
        self.referencedBy = referencedBy
        self.simulatorAppFrontmost = simulatorAppFrontmost
        self.cores = cores
        self.simulatorLastInFront = simulatorLastInFront
        self.frontTrackedSince = frontTrackedSince
        self.appCPUPercent = appCPUPercent
        self.debuggedBy = debuggedBy
    }
}

public enum SimulatorJudge {
    /// A booted simulator must have been quiet for this long before it counts as idle.
    public static let quietPeriod: TimeInterval = 60 * 60
    /// The Simulator app must not have been in front for this long. Opening CleanUp puts CleanUp in
    /// front, so "not frontmost right now" alone means nothing.
    public static let frontPeriod: TimeInterval = 30 * 60
    /// The device's apps together must stay below this (100 = one core).
    public static let idleAppCPUPercent = 5.0

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

        if let debugger = f.debuggedBy.first {
            signals.append(Signal(kind: .inUse, text: "\(f.debuggedBy.joined(separator: ", ")) is attached to it"))
            reasons.append("debugged by \(debugger)")
        }

        if f.simulatorAppFrontmost {
            signals.append(Signal(kind: .inUse, text: "The Simulator app is in front"))
            reasons.append("Simulator is in front")
        } else if let front = f.simulatorLastInFront, now.timeIntervalSince(front) < frontPeriod {
            let ago = RelativeAge.short(now.timeIntervalSince(front))
            signals.append(Signal(kind: .inUse, text: "The Simulator app was in front \(ago) ago"))
            reasons.append("Simulator was in front \(ago) ago")
        } else if now.timeIntervalSince(f.frontTrackedSince) < frontPeriod {
            let window = RelativeAge.short(frontPeriod)
            signals.append(Signal(kind: .inUse, text: "CleanUp just started: can't tell yet when the Simulator app was last used"))
            reasons.append("watching for \(window)")
        } else {
            let text = f.simulatorLastInFront.map { "The Simulator app was last in front \(RelativeAge.short(now.timeIntervalSince($0))) ago" }
                ?? "The Simulator app is in the background"
            signals.append(Signal(kind: .idle, text: text))
        }

        if let cpu = f.appCPUPercent {
            let text = String(format: "Its apps use %.1f%% of a core", cpu)
            if cpu < idleAppCPUPercent {
                signals.append(Signal(kind: .idle, text: text))
            } else {
                signals.append(Signal(kind: .inUse, text: text))
                reasons.append("busy")
            }
        } else {
            signals.append(Signal(kind: .inUse, text: "CPU use not measured yet"))
            reasons.append("measuring CPU")
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

    private struct Memory {
        /// Last good `simctl` answer, reused when a refresh runs with `runExternal == false`.
        var devices: [BootedDevice]?
        /// Since when the services have been running with nothing booted, watched without a break.
        var servicesQuietSince: Date?
        var lastScan: Date?
    }

    private let memory = OSAllocatedUnfairLock<Memory>(uncheckedState: Memory())

    /// The services must have been watched with nothing booted for this long before they count as idle.
    public static let servicesObservationWindow: TimeInterval = 10 * 60

    /// Runs an external command with a timeout; injectable for tests.
    public typealias Run = @Sendable (String, [String], Duration) async -> CommandResult
    private let run: Run
    private let lastInFront: @Sendable (String) async -> Date?
    private let trackingSince: @Sendable () async -> Date

    /// When the Simulator app was last in front, and since when that has been recorded.
    public struct FrontHistory: Sendable {
        public let lastInFront: Date?
        public let trackingSince: Date

        public init(lastInFront: Date?, trackingSince: Date) {
            self.lastInFront = lastInFront
            self.trackingSince = trackingSince
        }

        /// Recorded forever, never seen in front.
        public static let never = FrontHistory(lastInFront: nil, trackingSince: .distantPast)
    }

    /// - Parameters:
    ///   - lastInFront: when an app (by bundle ID) was last in front; defaults to CleanUp's activation log.
    ///   - trackingSince: since when that log has been recording without a gap (this launch).
    public init(
        run: Run? = nil,
        lastInFront: (@Sendable (String) async -> Date?)? = nil,
        trackingSince: (@Sendable () async -> Date)? = nil
    ) {
        self.run = run ?? { await CommandRunner.run($0, $1, timeout: $2) }
        self.lastInFront = lastInFront ?? { await ActivationLog.shared.lastActivated($0) }
        self.trackingSince = trackingSince ?? { ActivationLog.shared.launchedAt }
    }

    private func frontHistory() async -> FrontHistory {
        FrontHistory(lastInFront: await lastInFront(Self.simulatorBundleID), trackingSince: await trackingSince())
    }

    // MARK: scan

    public func scan(_ ctx: ScanContext) async -> [Item] {
        let devices: [BootedDevice]?
        if ctx.runExternal {
            // Every booted (or booting) device runs its own launchd_sim. Without one nothing is booted,
            // and asking simctl anyway would wake CoreSimulatorService, the very thing we report.
            devices = Self.simulatorLauncherExists(ctx.processes) ? await listBooted() : []
            memory.withLockUnchecked { $0.devices = devices }
        } else {
            devices = memory.withLockUnchecked { $0.devices }
        }
        // simctl failed or never ran: we don't know what is booted, so claim nothing.
        guard let devices else { return [] }
        let since = rememberServices(watching: devices.isEmpty && Self.servicesWatchable(ctx), now: ctx.now)
        return Self.buildItems(devices: devices, ctx: ctx, front: await frontHistory(), servicesQuietSince: since)
    }

    public func restartObservation() {
        memory.withLockUnchecked { $0.servicesQuietSince = nil }
    }

    /// Starts, keeps or clears the services' watch; an unwatched gap starts it over.
    private func rememberServices(watching: Bool, now: Date) -> Date? {
        memory.withLockUnchecked { state in
            if ObservationWindow.isGap(since: state.lastScan, now: now) { state.servicesQuietSince = nil }
            state.lastScan = max(state.lastScan ?? now, now)
            guard watching else {
                state.servicesQuietSince = nil
                return nil
            }
            let since = state.servicesQuietSince ?? now
            state.servicesQuietSince = since
            return since
        }
    }

    private func listBooted() async -> [BootedDevice]? {
        let result = await run("xcrun", ["simctl", "list", "devices", "booted", "-j"], Self.simctlTimeout)
        guard !result.timedOut, result.status == 0 else { return nil }
        return try? Self.parseBooted(result.stdout)
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

    /// `servicesQuietSince`: since when the services have been watched with nothing booted (nil: not yet).
    static func buildItems(
        devices: [BootedDevice], ctx: ScanContext, front: FrontHistory = .never, servicesQuietSince: Date? = nil
    ) -> [Item] {
        var items = devices.map { item(udid: $0.udid, name: $0.name, ctx: ctx, front: front) }
        if devices.isEmpty, !simulatorLauncherExists(ctx.processes),
           let engine = engineItem(ctx: ctx, quietSince: servicesQuietSince) { items.append(engine) }
        return items
    }

    private static func item(udid: String, name: String, ctx: ScanContext, front: FrontHistory) -> Item {
        let owned = deviceProcesses(udid: udid, in: ctx.processes)
        let facts = Self.facts(udid: udid, name: name, ctx: ctx, front: front)
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

    static func facts(udid: String, name: String, ctx: ScanContext, front: FrontHistory = .never) -> SimulatorFacts {
        let owned = deviceProcesses(udid: udid, in: ctx.processes)
        let ownedPIDs = Set(owned.map(\.pid))
        let launches = owned.filter { $0.path.contains("/data/Containers/Bundle/Application/") }
        let lastLaunch = launches.max { $0.startTime < $1.startTime }
        let cores = owned.reduce(0.0) { $0 + (ctx.cpu[$1.pid] ?? 0) } / 100
        let appCPU = launches.map { ctx.cpu[$0.pid] }
        let appCPUPercent: Double? = appCPU.contains { $0 == nil } ? nil : appCPU.reduce(0.0) { $0 + ($1 ?? 0) }

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
            cores: cores,
            simulatorLastInFront: front.lastInFront,
            frontTrackedSince: front.trackingSince,
            appCPUPercent: appCPUPercent,
            debuggedBy: debuggers(of: owned, in: ctx.processes)
        )
    }

    private static let debuggerNames: Set<String> = ["debugserver", "lldb", "lldb-rpc-server", "lldb-server"]

    /// A debugger is attached to one of the device's processes: the process is traced, its parent is
    /// a debugger (launched under debugserver), or a debugger names its pid (`lldb -p 1234`).
    private static func debuggers(of owned: [ProcessInfoRecord], in table: [Int32: ProcessInfoRecord]) -> [String] {
        let pids = Set(owned.map(\.pid))
        let pidStrings = Set(pids.map(String.init))
        var found = Set<String>()
        if owned.contains(where: \.isTraced) { found.insert("a debugger") }
        for p in table.values {
            let name = ProcessTree.leaf(p)
            guard debuggerNames.contains(name) || debuggerNames.contains(p.name) else { continue }
            let parentOfDevice = owned.contains { $0.ppid == p.pid }
            let namesAPID = p.arguments.dropFirst().contains { argument in
                argument.split { !$0.isNumber }.contains { pidStrings.contains(String($0)) }
            }
            if parentOfDevice || namesAPID { found.insert(name) }
        }
        return found.sorted()
    }

    // MARK: attribution

    /// Processes belonging to the device: executable inside `/Devices/<UDID>/`, the device's own
    /// `launchd_sim` (it names the folder in its arguments), and everything descending from it. Any
    /// other process that only names the folder in its arguments (`tail -f …/Devices/<UDID>/…`) is
    /// using the device, not part of it.
    private static func deviceProcesses(udid: String, in table: [Int32: ProcessInfoRecord]) -> [ProcessInfoRecord] {
        let marker = "/Devices/\(udid)/"
        let direct = table.values.filter { containsIgnoringCase($0.path, marker) }
        let launchers = table.values.filter { isLauncher($0) && mentions($0.arguments, marker) }
        var pids = Set((direct + launchers).map(\.pid))
        pids.formUnion(descendants(of: Set(launchers.map(\.pid)), in: table))
        return pids.compactMap { table[$0] }
    }

    private static func isLauncher(_ p: ProcessInfoRecord) -> Bool {
        p.name == "launchd_sim" || (p.path as NSString).lastPathComponent == "launchd_sim"
    }

    private static func descendants(of roots: Set<Int32>, in table: [Int32: ProcessInfoRecord]) -> Set<Int32> {
        ProcessTree.descendants(of: roots, in: table)
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
        table.values.contains(where: isLauncher)
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

    /// The services can be watched: they are running and nothing is booting.
    private static func servicesWatchable(_ ctx: ScanContext) -> Bool {
        !simulatorLauncherExists(ctx.processes) && ctx.processes.values.contains { $0.uid == getuid() && isEngineProcess($0) }
    }

    /// Tools that work the services without booting a device: a build or test run, `simctl` (runtime
    /// installs, `simctl runtime add`), `xcrun`, and the disk image service mounting a runtime (when
    /// it is visible and busy; it usually runs as root, where its CPU can't be read).
    private static let toolNames: Set<String> = ["xcodebuild", "simctl", "xcrun"]
    static let busyToolPercent = 5.0

    private static func servicesUsers(_ ctx: ScanContext) -> [String] {
        let own = ProcessTree.ownTree(ctx.ownPID, in: ctx.processes)
        var names = Set<String>()
        for p in ctx.processes.values where !own.contains(p.pid) {
            let name = ProcessTree.leaf(p)
            if toolNames.contains(name) { names.insert(name) }
            if name == "simdiskimaged" || p.name == "simdiskimaged" {
                if (ctx.cpu[p.pid] ?? .infinity) > busyToolPercent { names.insert("simdiskimaged") }
            }
        }
        return names.sorted()
    }

    /// The CoreSimulator background services, emitted only when nothing is booted yet they burn CPU.
    /// Idle only after ten watched minutes with nothing booted and no tool using them: a runtime
    /// install or a disk image mount looks just like this for a while.
    private static func engineItem(ctx: ScanContext, quietSince: Date?) -> Item? {
        let mine = ctx.processes.values.filter { $0.uid == getuid() && isEngineProcess($0) }
        let cores = mine.reduce(0.0) { $0 + (ctx.cpu[$1.pid] ?? 0) } / 100
        guard !mine.isEmpty, cores > engineBusyCores else { return nil }
        let usage = String(format: "%.1f", cores)
        var signals = [
            Signal(kind: .idle, text: "No simulator is booted"),
            Signal(kind: .idle, text: "Background services using \(usage) cores"),
        ]
        let users = servicesUsers(ctx)
        let watched = quietSince.map { ctx.now.timeIntervalSince($0) } ?? 0
        let judgement: Judgement
        if let user = users.first {
            signals.append(Signal(kind: .inUse, text: "\(users.joined(separator: ", ")) is working with them"))
            judgement = Judgement(verdict: .inUse, fact: "used by \(user)", signals: signals)
        } else if watched < servicesObservationWindow {
            signals.append(Signal(kind: .inUse, text: "Watched for only \(RelativeAge.short(watched)) so far"))
            judgement = Judgement(verdict: .inUse, fact: "measuring activity", signals: signals)
        } else {
            signals.append(Signal(kind: .neutral, text: "They restart on demand"))
            judgement = Judgement(verdict: .idle, fact: "no simulator booted, using \(usage) cores", signals: signals)
        }
        return Item(
            id: engineIdentity,
            category: .simulators,
            name: "Simulator services",
            symbol: "gearshape.2",
            judgement: judgement,
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
        // The item may come from an old scan: judge the device again from the fresh context.
        if !force {
            let facts = Self.facts(udid: udid, name: item.name, ctx: ctx, front: await frontHistory())
            guard SimulatorJudge.judge(facts, now: ctx.now).verdict == .idle else {
                return .skipped(reason: "\(item.name) is in use now")
            }
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
        if let user = servicesUsers(ctx).first { return .skipped(reason: "used by \(user)") }
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
