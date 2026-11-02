import AppKit
import Darwin
import Foundation
import os

// MARK: - Facts and judgement

public struct ContainerFacts: Sendable {
    public let name: String
    public let image: String
    public let startedAt: Date
    /// Docker's figure: 100 = one full core.
    public let cpuPercent: Double
    public let publishedPorts: [Int]
    /// Established TCP connections on this Mac to one of the published ports, engine proxies excluded.
    public let clientConnections: Int
    /// Exact bytes in + out over the observation window (at least 10 minutes); nil until a baseline that old exists, after a counter reset, or when the counter can't be read.
    public let netBytesDelta: Int64?
    /// Processes on this Mac whose arguments name the container: `docker exec -it`, `docker attach`,
    /// `docker compose exec`, a VS Code / Cursor dev container. They talk over the Docker socket, so
    /// no port, CPU or traffic counter shows them.
    public let attachedBy: [String]

    public init(
        name: String, image: String, startedAt: Date, cpuPercent: Double,
        publishedPorts: [Int], clientConnections: Int, netBytesDelta: Int64?, attachedBy: [String] = []
    ) {
        self.name = name
        self.image = image
        self.startedAt = startedAt
        self.cpuPercent = cpuPercent
        self.publishedPorts = publishedPorts
        self.clientConnections = clientConnections
        self.netBytesDelta = netBytesDelta
        self.attachedBy = attachedBy
    }
}

public enum ContainerJudge {
    /// A container must have been up this long before it counts as idle.
    public static let minimumAge: TimeInterval = 6 * 3_600
    public static let idleCPUPercent = 1.0
    /// Keep-alives and health checks stay below this between two scans.
    public static let idleNetBytes: Int64 = 4_096

    /// Idle only when every condition holds; anything unknown is in use.
    public static func judge(_ f: ContainerFacts, now: Date) -> Judgement {
        var signals: [Signal] = []
        var reasons: [String] = []   // in-use reasons, strongest first

        if let user = f.attachedBy.first {
            signals.append(Signal(kind: .inUse, text: "\(f.attachedBy.joined(separator: ", ")) has a session open in it"))
            reasons.append("used by \(user)")
        }

        if f.clientConnections == 0 {
            if f.publishedPorts.isEmpty {
                // Nothing on this Mac can connect, and traffic from other containers is seen only through the byte counters.
                signals.append(Signal(kind: .neutral, text: "No ports published"))
            } else {
                signals.append(Signal(kind: .idle, text: "Nothing is connected to its ports"))
            }
        } else {
            let text = f.clientConnections == 1 ? "1 connection" : "\(f.clientConnections) connections"
            signals.append(Signal(kind: .inUse, text: "\(text) open to its ports"))
            reasons.append(text)
        }

        let cpu = String(format: "%.1f", f.cpuPercent)
        if f.cpuPercent < idleCPUPercent {
            signals.append(Signal(kind: .idle, text: "Using \(cpu)% of a core"))
        } else {
            signals.append(Signal(kind: .inUse, text: "Using \(cpu)% of a core"))
            reasons.append("busy")
        }

        switch f.netBytesDelta {
        case .none:
            signals.append(Signal(kind: .inUse, text: "Network traffic not measured over a long enough window yet"))
            reasons.append("measuring traffic")
        case let delta? where delta < idleNetBytes:
            signals.append(Signal(kind: .idle, text: "Almost no network traffic recently"))
        case let delta?:
            signals.append(Signal(kind: .inUse, text: "\(delta / 1_024) kB of network traffic recently"))
            reasons.append("busy")
        }

        let age = now.timeIntervalSince(f.startedAt)
        if age >= minimumAge {
            signals.append(Signal(kind: .idle, text: "Running for \(RelativeAge.short(age))"))
        } else {
            signals.append(Signal(kind: .inUse, text: "Started \(RelativeAge.short(age)) ago"))
            reasons.append("just started")
        }

        if let reason = reasons.first {
            return Judgement(verdict: .inUse, fact: reason, signals: signals)
        }
        return Judgement(verdict: .idle, fact: "idle \(RelativeAge.short(age))", signals: signals)
    }
}

// MARK: - Engines

public enum ContainerEngine: String, Codable, Sendable, CaseIterable {
    case dockerDesktop = "Docker Desktop"
    case orbStack = "OrbStack"
    case colima = "Colima"
}

/// What CleanUp knows about one running container engine at one moment.
public struct EngineFacts: Sendable {
    /// OrbStack's Linux machines (`orb list`); `.notApplicable` for the other engines.
    public enum Machines: Sendable, Equatable {
        case notApplicable, none, running, unknown
    }

    public let engine: ContainerEngine
    public let containerVerdicts: [Verdict]
    /// Names of docker-client processes running right now (`docker build`, `kubectl`, `orb shell`, …).
    public let clients: [String]
    /// The engine's own CPU (its processes and VM, minus its containers), 100 = one core; nil when not measured.
    public let overheadPercent: Double?
    public let machines: Machines
    /// Another container engine is running too, so we can't tell whose containers these are.
    public let otherEngineRunning: Bool
    /// Since when every condition has held without a break; nil when they don't hold now.
    public let quietSince: Date?

    public init(
        engine: ContainerEngine, containerVerdicts: [Verdict], clients: [String], overheadPercent: Double?,
        machines: Machines, otherEngineRunning: Bool, quietSince: Date?
    ) {
        self.engine = engine
        self.containerVerdicts = containerVerdicts
        self.clients = clients
        self.overheadPercent = overheadPercent
        self.machines = machines
        self.otherEngineRunning = otherEngineRunning
        self.quietSince = quietSince
    }
}

/// An engine is idle only when nothing at all is using it, continuously for the observation window:
/// no container in use, no docker client running, no Linux machine up, and almost no CPU of its own.
public enum EngineJudge {
    /// The engine's own CPU (VM and helpers, its containers left out) must stay below this.
    public static let idleOverheadPercent = 5.0
    public static let observationWindow: TimeInterval = 10 * 60

    /// Every condition holds right now; the module starts (or keeps) its quiet clock while this is true.
    public static func isQuietNow(_ f: EngineFacts) -> Bool {
        reasonsAndSignals(f).reasons.isEmpty
    }

    public static func judge(_ f: EngineFacts, now: Date) -> Judgement {
        var (reasons, signals) = reasonsAndSignals(f)
        if let reason = reasons.first {
            return Judgement(verdict: .inUse, fact: reason, signals: signals)
        }
        let quiet = f.quietSince.map { now.timeIntervalSince($0) } ?? 0
        guard quiet >= observationWindow else {
            signals.append(Signal(kind: .inUse, text: "Quiet for only \(RelativeAge.short(quiet)) so far"))
            reasons.append("measuring activity")
            return Judgement(verdict: .inUse, fact: "measuring activity", signals: signals)
        }
        signals.append(Signal(kind: .idle, text: "Nothing has used it for \(RelativeAge.short(quiet))"))
        signals.append(Signal(kind: .neutral, text: "Stopping it also stops its containers"))
        return Judgement(verdict: .idle, fact: "idle engine", signals: signals)
    }

    private static func reasonsAndSignals(_ f: EngineFacts) -> (reasons: [String], signals: [Signal]) {
        var reasons: [String] = []
        var signals: [Signal] = []

        if f.otherEngineRunning {
            signals.append(Signal(kind: .inUse, text: "More than one container engine is running, so we can't tell which one hosts the containers"))
            reasons.append("another engine is running")
        }

        let containers = ContainersModule.engineJudgement(containerVerdicts: f.containerVerdicts)
        if containers.verdict == .idle {
            signals.append(containers.signals[0])
        } else {
            signals += containers.signals
            reasons.append(containers.fact)
        }

        if let client = f.clients.first {
            let names = f.clients.joined(separator: ", ")
            signals.append(Signal(kind: .inUse, text: "\(names) is talking to it (a build, a pull or a shell)"))
            reasons.append("used by \(client)")
        } else {
            signals.append(Signal(kind: .idle, text: "No docker command is running"))
        }

        switch f.machines {
        case .notApplicable: break
        case .none: signals.append(Signal(kind: .idle, text: "No Linux machine is running"))
        case .running:
            signals.append(Signal(kind: .inUse, text: "A Linux machine is running in it"))
            reasons.append("a Linux machine is running")
        case .unknown:
            signals.append(Signal(kind: .inUse, text: "Couldn't check its Linux machines"))
            reasons.append("couldn't check its Linux machines")
        }

        if let overhead = f.overheadPercent {
            let cpu = String(format: "%.1f", overhead)
            if overhead < idleOverheadPercent {
                signals.append(Signal(kind: .idle, text: "The engine itself uses \(cpu)% of a core"))
            } else {
                signals.append(Signal(kind: .inUse, text: "The engine itself uses \(cpu)% of a core"))
                reasons.append("busy")
            }
        } else {
            signals.append(Signal(kind: .inUse, text: "CPU use not measured yet"))
            reasons.append("measuring activity")
        }
        return (reasons, signals)
    }
}

/// A running container engine and the processes that belong to it.
struct DetectedEngine: Sendable {
    let engine: ContainerEngine
    /// The engine's own processes (signal-able ones; never includes `vm`).
    let processes: [ProcessInfoRecord]
    /// The Virtualization.framework VM process that hosts the engine's Linux VM. It lives under
    /// /System, so it counts toward the engine's CPU and memory but is never signalled.
    let vm: [ProcessInfoRecord]
    /// The `.app` bundle to quit; nil for Colima.
    let appPath: String?

    var allPIDs: Set<Int32> { Set((processes + vm).map(\.pid)) }
}

// MARK: - Module

public struct ContainersModule: CategoryModule {
    public var id: CategoryID { .containers }

    public typealias Run = @Sendable (String, [String]) async -> CommandResult
    /// Quits / relaunches the app bundle at the given path; true when the request was made.
    public typealias AppAction = @Sendable (String) async -> Bool

    static let engineIdentityPrefix = "engine:"

    private let run: Run
    private let quitApp: AppAction
    private let launchApp: AppAction

    private struct Collected: Sendable {
        let name: String
        /// Short (12-hex) container ID from `docker ps`.
        let id: String
        let image: String
        /// Compose service name, when the container belongs to a compose project.
        let service: String?
        let startedAt: Date?
        let ports: [Int]?
        let cpuPercent: Double?
        let netBytesDelta: Int64?
        /// Since when CPU has been continuously below the idle threshold; nil when it isn't.
        let lowCPUSince: Date?
    }

    private struct NetSample: Sendable {
        let at: Date
        let bytes: Int64
    }

    private struct Memory: Sendable {
        /// nil → docker hasn't answered successfully (or has never been asked).
        var collected: [Collected]?
        /// Exact network byte counters per container, oldest first: the newest sample at least
        /// `observationWindow` old (the baseline) and everything after it.
        var samples: [String: [NetSample]] = [:]
        var lowCPUSince: [String: Date] = [:]
        /// Docker Engine API socket, discovered once.
        var socketPath: String?
        /// OrbStack's Linux machines at the last external scan.
        var orbMachines: EngineFacts.Machines = .unknown
        /// Since when each engine has been quiet without a break.
        var engineQuietSince: [ContainerEngine: Date] = [:]
    }

    /// Idleness has to hold for this long: low CPU the whole time, and traffic measured against a
    /// baseline at least this old. One quiet sample proves nothing about a database queried every few minutes.
    static let observationWindow: TimeInterval = 10 * 60

    private let memory = OSAllocatedUnfairLock(initialState: Memory())

    public init(run: Run? = nil, quitApp: AppAction? = nil, launchApp: AppAction? = nil) {
        self.run = run ?? { await Self.defaultRun($0, $1) }
        self.quitApp = quitApp ?? { await Self.defaultQuit($0) }
        self.launchApp = launchApp ?? { await Self.defaultLaunch($0) }
    }

    // MARK: scan

    public func scan(_ ctx: ScanContext) async -> [Item] {
        let collected: [Collected]?
        if ctx.runExternal {
            collected = await collect(ctx: ctx)
        } else {
            collected = memory.withLock { $0.collected }
        }
        // Docker missing, daemon down, or never asked: claim nothing.
        guard let collected else { return [] }
        return buildItems(collected, ctx: ctx)
    }

    /// Runs docker and remembers the answer. nil when the daemon doesn't answer.
    private func collect(ctx: ScanContext) async -> [Collected]? {
        let now = ctx.now
        let engines = Self.detectEngines(ctx.processes)
        async let orbList: CommandResult? = engines.contains { $0.engine == .orbStack } ? run("orb", ["list"]) : nil
        let ps = await run("docker", ["ps", "--format", "{{json .}}"])
        let machines = await orbList.map(Self.orbMachines) ?? .unknown
        guard ps.status == 0, !ps.timedOut else {
            memory.withLock { $0 = Memory() }
            return nil
        }
        memory.withLock { $0.orbMachines = machines }
        let running = Self.parsePS(ps.stdout)
        guard !running.isEmpty else {
            memory.withLock { state in
                state.collected = []
                state.samples = [:]
                state.lowCPUSince = [:]
            }
            return []
        }

        async let statsResult = run("docker", ["stats", "--no-stream", "--format", "{{json .}}"])
        async let inspectResult = run("docker", ["inspect", "--format", Self.inspectTemplate] + running.map(\.name))
        let socket = await engineSocket()
        let counters = await networkBytes(of: running.map(\.name), socket: socket)
        let stats = await statsResult
        let inspect = await inspectResult
        // `docker stats` supplies CPU only: its NetIO is rounded to 3 significant figures.
        let statsByName = (stats.status == 0 && !stats.timedOut) ? Self.parseStats(stats.stdout) : [:]
        let inspected = (inspect.status == 0 && !inspect.timedOut) ? Self.parseInspect(inspect.stdout) : [:]

        return memory.withLock { state -> [Collected] in
            var samples: [String: [NetSample]] = [:]
            var lowCPU: [String: Date] = [:]
            let rows = running.map { row -> Collected in
                let cpu = statsByName[row.name]?.cpu
                if let cpu, cpu < ContainerJudge.idleCPUPercent { lowCPU[row.name] = state.lowCPUSince[row.name] ?? now }

                var history = state.samples[row.name] ?? []
                var delta: Int64?
                if let bytes = counters[row.name] {
                    let baseline = history.last { now.timeIntervalSince($0.at) >= Self.observationWindow }
                    if let baseline {
                        if bytes >= baseline.bytes { delta = bytes - baseline.bytes } else { history = [] }   // counter reset
                    }
                    history.append(NetSample(at: now, bytes: bytes))
                    if let baseline, let index = history.firstIndex(where: { $0.at == baseline.at }) { history.removeFirst(index) }
                } else {
                    history = []   // can't read the counter: start over rather than guess
                }
                samples[row.name] = history

                return Collected(
                    name: row.name, id: row.id, image: row.image, service: inspected[row.name]?.service,
                    startedAt: inspected[row.name]?.startedAt, ports: inspected[row.name]?.ports,
                    cpuPercent: cpu, netBytesDelta: delta, lowCPUSince: lowCPU[row.name]
                )
            }
            state.samples = samples
            state.lowCPUSince = lowCPU
            state.collected = rows
            return rows
        }
    }

    // MARK: Docker Engine API

    /// The engine's unix socket from the current docker context, e.g. `~/.docker/run/docker.sock`.
    private func engineSocket() async -> String? {
        if let known = memory.withLock({ $0.socketPath }) { return known }
        let result = await run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
        guard result.status == 0, !result.timedOut else { return nil }
        let host = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.hasPrefix("unix://") else { return nil }
        let path = String(host.dropFirst("unix://".count))
        guard path.hasPrefix("/") else { return nil }
        memory.withLock { $0.socketPath = path }
        return path
    }

    /// Exact rx + tx bytes per container from the Engine API, fetched concurrently (each call has a
    /// 10 s cap). Containers whose counter can't be read are absent.
    private func networkBytes(of names: [String], socket: String?) async -> [String: Int64] {
        guard let socket else { return [:] }
        return await withTaskGroup(of: (String, Int64?).self) { group in
            for name in names {
                group.addTask { (name, await self.apiNetworkBytes(name: name, socket: socket)) }
            }
            var found: [String: Int64] = [:]
            for await (name, bytes) in group { if let bytes { found[name] = bytes } }
            return found
        }
    }

    private func apiNetworkBytes(name: String, socket: String) async -> Int64? {
        guard Self.isSafeName(name) else { return nil }
        let result = await run("/usr/bin/curl", [
            "--silent", "--max-time", "10", "--unix-socket", socket,
            "http://localhost/containers/\(name)/stats?stream=false&one-shot=true",
        ])
        guard result.status == 0, !result.timedOut else { return nil }
        return Self.parseAPINetworkBytes(result.stdout)
    }

    /// Sum of `networks.*.rx_bytes + tx_bytes` from a `/containers/<id>/stats` response.
    /// nil when there are no network counters (host/none networking): unknown, not zero.
    static func parseAPINetworkBytes(_ json: String) -> Int64? {
        struct Stats: Decodable {
            struct Net: Decodable { let rx_bytes: Int64; let tx_bytes: Int64 }
            let networks: [String: Net]?
        }
        guard let stats = try? JSONDecoder().decode(Stats.self, from: Data(json.utf8)),
              let networks = stats.networks, !networks.isEmpty else { return nil }
        return networks.values.reduce(0) { $0 + $1.rx_bytes + $1.tx_bytes }
    }

    // MARK: items

    private func buildItems(_ collected: [Collected], ctx: ScanContext) -> [Item] {
        let engines = Self.detectEngines(ctx.processes)
        let proxyPIDs = engines.reduce(into: Set<Int32>()) { $0.formUnion($1.allPIDs) }
        let sessions = collected.isEmpty ? nil : SessionIndex(ctx.processes, ownPID: ctx.ownPID)

        var containerItems: [Item] = []
        var verdicts: [Verdict] = []
        var allPorts = Set<Int>()
        var containersCPU = 0.0
        for c in collected.sorted(by: { $0.name < $1.name }) {
            let users = sessions?.users(name: c.name, id: c.id, service: c.service) ?? []
            let item = Self.containerItem(c, engine: engines.first?.engine, proxyPIDs: proxyPIDs, attachedBy: users, ctx: ctx)
            containerItems.append(item)
            verdicts.append(item.judgement.verdict)
            allPorts.formUnion(c.ports ?? [])
            containersCPU += c.cpuPercent ?? 0
        }

        let clients = Self.dockerClients(in: ctx.processes, ownPID: ctx.ownPID)
        let machines = memory.withLock { $0.orbMachines }
        let engineItems = engines.map { e -> Item in
            let (overhead, cores) = Self.overhead(of: e, containersCPU: containersCPU, cpu: ctx.cpu)
            // Two engines can run at once but the docker CLI talks to only one of them, so we can't say
            // whose containers these are, or whether the other engine hosts any: never offer to quit.
            let draft = EngineFacts(
                engine: e.engine, containerVerdicts: verdicts, clients: clients, overheadPercent: overhead,
                machines: e.engine == .orbStack ? machines : .notApplicable,
                otherEngineRunning: engines.count > 1, quietSince: nil
            )
            let since = rememberQuiet(e.engine, quiet: EngineJudge.isQuietNow(draft), now: ctx.now)
            let facts = EngineFacts(
                engine: draft.engine, containerVerdicts: verdicts, clients: clients, overheadPercent: overhead,
                machines: draft.machines, otherEngineRunning: draft.otherEngineRunning, quietSince: since
            )
            return Self.engineItem(e, facts: facts, cores: cores, ports: allPorts, ctx: ctx)
        }
        let running = Set(engines.map(\.engine))
        memory.withLock { state in state.engineQuietSince = state.engineQuietSince.filter { running.contains($0.key) } }
        return containerItems + engineItems
    }

    /// Starts, keeps or clears the engine's quiet clock; returns since when it has been quiet.
    private func rememberQuiet(_ engine: ContainerEngine, quiet: Bool, now: Date) -> Date? {
        memory.withLock { state in
            guard quiet else {
                state.engineQuietSince[engine] = nil
                return nil
            }
            let since = state.engineQuietSince[engine] ?? now
            state.engineQuietSince[engine] = since
            return since
        }
    }

    /// The engine's own CPU: its processes and VM, minus what its containers use (the VM's CPU
    /// already contains theirs). `overhead` is nil while any of its processes is unmeasured; `cores`
    /// is the same figure from what was measured, for display.
    private static func overhead(of e: DetectedEngine, containersCPU: Double, cpu: [Int32: Double]) -> (overhead: Double?, cores: Double) {
        let values = (e.processes + e.vm).map { cpu[$0.pid] }
        let measured = values.reduce(0.0) { $0 + ($1 ?? 0) }
        let own = max(0, measured - containersCPU)
        return (values.contains { $0 == nil } ? nil : own, own / 100)
    }

    /// Command-line clients that talk to an engine. While one runs (a build, a pull, `kubectl`,
    /// `orb shell`…), the engine is in use whatever its containers do.
    static let clientNames: Set<String> = ["docker", "com.docker.cli", "docker-buildx", "docker-compose", "kubectl", "orb", "limactl"]

    /// Our user's docker clients, sorted by name, without CleanUp's own calls and without Colima's
    /// own `limactl hostagent` / `usernet` daemons (they are the engine).
    static func dockerClients(in table: [Int32: ProcessInfoRecord], ownPID: Int32) -> [String] {
        let own = ProcessTree.ownTree(ownPID, in: table)
        let uid = getuid()
        var names = Set<String>()
        for p in table.values where p.uid == uid && !own.contains(p.pid) {
            let name = ProcessTree.leaf(p)
            guard clientNames.contains(name) || clientNames.contains(p.name) else { continue }
            if name == "limactl", p.arguments.contains(where: { $0 == "hostagent" || $0 == "usernet" }) { continue }
            names.insert(clientNames.contains(name) ? name : p.name)
        }
        return names.sorted()
    }

    /// `orb list`: running when any machine isn't plainly stopped; unknown when it can't be read.
    static func orbMachines(_ result: CommandResult) -> EngineFacts.Machines {
        guard result.status == 0, !result.timedOut else { return .unknown }
        return parseOrbMachines(result.stdout)
    }

    static func parseOrbMachines(_ out: String) -> EngineFacts.Machines {
        for line in out.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard let first = words.first, first != "name", !line.lowercased().contains("no machines") else { continue }
            if words.contains("stopped"), !words.contains("running") { continue }
            return .running
        }
        return .none
    }

    private static func containerItem(
        _ c: Collected, engine: ContainerEngine?, proxyPIDs: Set<Int32>, attachedBy: [String], ctx: ScanContext
    ) -> Item {
        var detail = ["image": c.image, "id": c.id]
        if let service = c.service { detail["service"] = service }
        if !attachedBy.isEmpty { detail["usedBy"] = attachedBy.joined(separator: ", ") }
        if let ports = c.ports, !ports.isEmpty { detail["ports"] = ports.map(String.init).joined(separator: ",") }
        if let engine { detail["engine"] = engine.rawValue }

        let judgement: Judgement
        var cores = 0.0
        if let startedAt = c.startedAt, let ports = c.ports, let cpu = c.cpuPercent {
            cores = cpu / 100
            let facts = ContainerFacts(
                name: c.name, image: c.image, startedAt: startedAt, cpuPercent: cpu, publishedPorts: ports,
                clientConnections: clientConnections(ports: ports, sockets: ctx.sockets, excluding: proxyPIDs),
                netBytesDelta: c.netBytesDelta, attachedBy: attachedBy
            )
            judgement = requireSustainedLowCPU(ContainerJudge.judge(facts, now: ctx.now), since: c.lowCPUSince, now: ctx.now)
        } else {
            judgement = Judgement(
                verdict: .inUse, fact: "can't read its state",
                signals: [Signal(kind: .inUse, text: "Docker didn't report its start time, ports or usage")]
            )
        }
        return Item(
            id: .container(name: c.name), category: .containers, name: c.name, symbol: "shippingbox",
            judgement: judgement, cores: cores, memoryBytes: 0, processes: [], detail: detail
        )
    }

    /// A single low CPU sample is not idleness: CPU has to have stayed low for the whole observation window.
    private static func requireSustainedLowCPU(_ judgement: Judgement, since: Date?, now: Date) -> Judgement {
        guard judgement.verdict == .idle else { return judgement }
        if let since, now.timeIntervalSince(since) >= observationWindow { return judgement }
        let text = since.map { "CPU has been low for only \(RelativeAge.short(now.timeIntervalSince($0)))" } ?? "CPU use not observed yet"
        return Judgement(verdict: .inUse, fact: "measuring activity", signals: judgement.signals + [Signal(kind: .inUse, text: text)])
    }

    private static func engineItem(_ e: DetectedEngine, facts: EngineFacts, cores: Double, ports: Set<Int>, ctx: ScanContext) -> Item {
        let all = e.processes + e.vm
        var detail = ["containers": String(facts.containerVerdicts.count)]
        if let appPath = e.appPath { detail["appPath"] = appPath }
        if !ports.isEmpty { detail["ports"] = ports.sorted().map(String.init).joined(separator: ",") }
        return Item(
            id: .engine(name: e.engine.rawValue), category: .containers, name: e.engine.rawValue, symbol: "gearshape.2",
            judgement: EngineJudge.judge(facts, now: ctx.now),
            cores: cores,
            memoryBytes: all.reduce(0) { $0 + $1.residentBytes },
            processes: e.processes.map(\.ref),
            detail: detail
        )
    }

    /// The containers' part of an engine's verdict: idle iff no container is running or every
    /// running container is idle. `EngineJudge` adds the engine's own activity on top.
    public static func engineJudgement(containerVerdicts: [Verdict]) -> Judgement {
        let busy = containerVerdicts.filter { $0 != .idle }.count
        if busy > 0 {
            let text = busy == 1 ? "1 container in use" : "\(busy) containers in use"
            return Judgement(verdict: .inUse, fact: text, signals: [Signal(kind: .inUse, text: "\(busy) of \(containerVerdicts.count) running containers are in use")])
        }
        let state = containerVerdicts.isEmpty
            ? Signal(kind: .idle, text: "No containers are running")
            : Signal(kind: .idle, text: "Every running container is idle")
        return Judgement(
            verdict: .idle, fact: "idle engine",
            signals: [state, Signal(kind: .neutral, text: "Stopping it also stops its containers")]
        )
    }

    /// Distinct established connections involving any of `ports`:
    /// - client side: a socket on this Mac whose remote port is a published port (the engine's own
    ///   outbound sockets excluded);
    /// - server side: any socket, the engine proxy included, whose local port is a published port.
    ///   That is how LAN/VPN clients and containers calling `host.docker.internal:<port>` show up.
    /// A local client appears on both sides, so connections are counted once per port pair.
    static func clientConnections(ports: [Int], sockets: [SocketInfo], excluding engine: Set<Int32>) -> Int {
        let published = Set(ports)
        guard !published.isEmpty else { return 0 }
        var connections = Set<[Int]>()
        for socket in sockets where socket.state == .established {
            guard let remote = socket.remotePort else { continue }
            let clientSide = published.contains(remote) && !engine.contains(socket.pid)
            let serverSide = published.contains(socket.localPort)
            if clientSide || serverSide { connections.insert([min(socket.localPort, remote), max(socket.localPort, remote)]) }
        }
        return connections.count
    }

    // MARK: engine detection

    private static let vmLeaf = "com.apple.Virtualization.VirtualMachine"
    /// Longest gap between an engine starting its VM launcher and the VM process appearing.
    private static let vmAttributionWindow: TimeInterval = 120

    static func detectEngines(_ table: [Int32: ProcessInfoRecord]) -> [DetectedEngine] {
        let uid = getuid()
        var members: [ContainerEngine: [ProcessInfoRecord]] = [:]
        var vms: [ProcessInfoRecord] = []
        for p in table.values where p.uid == uid {
            if p.path.contains(vmLeaf) || p.name.hasPrefix("com.apple.Virtualization.Virtual") {
                vms.append(p)
            } else if let engine = engine(of: p) {
                members[engine, default: []].append(p)
            }
        }

        // The VM process is spawned via XPC (its parent is launchd), so pair it with the engine whose
        // VM launcher started closest before it.
        var anchors: [(engine: ContainerEngine, start: Date)] = []
        for (engine, processes) in members {
            for p in processes where isVMLauncher(p, engine) { anchors.append((engine, p.startTime)) }
        }
        var vmByEngine: [ContainerEngine: [ProcessInfoRecord]] = [:]
        for vm in vms {
            let best = anchors
                .map { (engine: $0.engine, gap: vm.startTime.timeIntervalSince($0.start)) }
                .filter { $0.gap >= -2 && $0.gap <= vmAttributionWindow }
                .min { $0.gap < $1.gap }
            if let best { vmByEngine[best.engine, default: []].append(vm) }
        }

        return ContainerEngine.allCases.compactMap { engine in
            guard let processes = members[engine], !processes.isEmpty else { return nil }
            return DetectedEngine(
                engine: engine,
                processes: processes.sorted { $0.pid < $1.pid },
                vm: (vmByEngine[engine] ?? []).sorted { $0.pid < $1.pid },
                appPath: appBundle(of: processes, engine: engine)
            )
        }
    }

    private static func leaf(_ p: ProcessInfoRecord) -> String { (p.path as NSString).lastPathComponent }

    private static func engine(of p: ProcessInfoRecord) -> ContainerEngine? {
        if p.path.contains("/Docker.app/Contents/MacOS/") { return .dockerDesktop }
        if p.path.contains("/OrbStack.app/") { return .orbStack }
        let name = leaf(p)
        guard name == "limactl" || name == "colima" || name.hasPrefix("qemu-system") else { return nil }
        let args = p.arguments.joined(separator: " ")
        if args.contains("/.colima/") || args.contains("_lima/colima") { return .colima }
        if name == "colima", p.arguments.contains("daemon") { return .colima }
        return nil
    }

    private static func isVMLauncher(_ p: ProcessInfoRecord, _ engine: ContainerEngine) -> Bool {
        switch engine {
        case .dockerDesktop: leaf(p) == "com.docker.virtualization"
        case .colima: leaf(p) == "limactl" && p.arguments.contains("hostagent")
        case .orbStack: false
        }
    }

    private static func appBundle(of processes: [ProcessInfoRecord], engine: ContainerEngine) -> String? {
        let bundle: String
        switch engine {
        case .dockerDesktop: bundle = "Docker.app"
        case .orbStack: bundle = "OrbStack.app"
        case .colima: return nil
        }
        for p in processes {
            var components = (p.path as NSString).pathComponents
            if let index = components.firstIndex(of: bundle) {
                components = Array(components.prefix(index + 1))
                return NSString.path(withComponents: components)
            }
        }
        return nil
    }

    // MARK: parsing

    /// Prints only what we read, so container environment variables (passwords) never leave docker.
    static let inspectTemplate =
        #"{"Name":{{json .Name}},"State":{"StartedAt":{{json .State.StartedAt}}},"NetworkSettings":{"Ports":{{json .NetworkSettings.Ports}}},"Service":{{json (index .Config.Labels "com.docker.compose.service")}}}"#

    private static func jsonLines<T: Decodable>(_ output: String, as: T.Type) -> [T] {
        let decoder = JSONDecoder()
        return output.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(T.self, from: Data($0.utf8)) }
    }

    /// Container names Docker accepts; anything else is never passed to a command line.
    static func isSafeName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 255,
              CharacterSet.alphanumerics.contains(first), first.isASCII else { return false }
        return name.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "_.-".unicodeScalars.contains($0)) }
    }

    /// Running containers from `docker ps --format '{{json .}}'`.
    public static func parsePS(_ out: String) -> [(name: String, image: String, id: String)] {
        struct Row: Decodable { let Names: String; let Image: String; let ID: String? }
        return jsonLines(out, as: Row.self).compactMap { row in
            let name = row.Names.split(separator: ",").first.map(String.init) ?? ""
            let id = String((row.ID ?? "").lowercased().prefix(12))
            return isSafeName(name) ? (name: name, image: row.Image, id: id) : nil
        }
    }

    /// CPU % and total network bytes per container from `docker stats --no-stream --format '{{json .}}'`.
    /// Rows docker couldn't measure (`--`) are left out.
    public static func parseStats(_ out: String) -> [String: (cpu: Double, netIOBytes: Int64)] {
        struct Row: Decodable { let Name: String; let CPUPerc: String; let NetIO: String }
        var result: [String: (cpu: Double, netIOBytes: Int64)] = [:]
        for row in jsonLines(out, as: Row.self) {
            guard row.CPUPerc.hasSuffix("%"), let cpu = Double(row.CPUPerc.dropLast()), cpu.isFinite,
                  let net = parseNetIO(row.NetIO) else { continue }
            result[row.Name] = (cpu: cpu, netIOBytes: net)
        }
        return result
    }

    /// "1.2MB / 3.4MB" → bytes in + out. Docker prints decimal units (kB, MB, GB).
    static func parseNetIO(_ text: String) -> Int64? {
        let sides = text.split(separator: "/", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard sides.count == 2 else { return nil }
        var total: Int64 = 0
        for side in sides {
            guard let bytes = parseSize(side) else { return nil }
            total += bytes
        }
        return total
    }

    private static let sizeUnits: [String: Double] = [
        "B": 1, "kB": 1e3, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12,
        "KiB": 1_024, "MiB": 1_048_576, "GiB": 1_073_741_824, "TiB": 1_099_511_627_776,
    ]

    private static func parseSize(_ text: String) -> Int64? {
        let number = text.prefix { $0.isNumber || $0 == "." }
        let unit = text.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), let scale = sizeUnits[unit] else { return nil }
        return Int64((value * scale).rounded())
    }

    /// Start time, published host ports and compose service per container, from `docker inspect`.
    static func parseInspect(_ out: String) -> [String: (startedAt: Date, ports: [Int], service: String?)] {
        struct Binding: Decodable { let HostPort: String? }
        struct Row: Decodable {
            struct State: Decodable { let StartedAt: String }
            struct Network: Decodable { let Ports: [String: [Binding]?]? }
            let Name: String
            let State: State
            let NetworkSettings: Network
            let Service: String?
        }
        var result: [String: (startedAt: Date, ports: [Int], service: String?)] = [:]
        for row in jsonLines(out, as: Row.self) {
            // Docker's zero date means "never started"; treat it as unknown.
            guard let started = parseDate(row.State.StartedAt), started.timeIntervalSince1970 > 946_684_800 else { continue }
            let ports = (row.NetworkSettings.Ports ?? [:]).values
                .flatMap { $0 ?? [] }
                .compactMap { $0.HostPort.flatMap { Int($0) } }
            let service = row.Service.flatMap { $0.isEmpty ? nil : $0 }
            result[row.Name.hasPrefix("/") ? String(row.Name.dropFirst()) : row.Name] = (started, Array(Set(ports)).sorted(), service)
        }
        return result
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    // MARK: stop / undo

    public func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult {
        // Quitting an engine stops every container in it: an engine is never forced.
        let isEngine = item.id.rawValue.hasPrefix(Self.engineIdentityPrefix)
        let checkActivity = !force || isEngine
        if checkActivity {
            guard item.judgement.verdict == .idle else {
                return .skipped(reason: "\(item.name) is in use")
            }
            // The item may come from a cached scan: look at the sockets again before stopping anything.
            let ports = (item.detail["ports"] ?? "").split(separator: ",").compactMap { Int($0) }
            let proxyPIDs = Self.detectEngines(ctx.processes).reduce(into: Set<Int32>()) { $0.formUnion($1.allPIDs) }
            let clients = Self.clientConnections(ports: ports, sockets: ctx.sockets, excluding: proxyPIDs)
            guard clients == 0 else {
                return .skipped(reason: "\(item.name) now has \(clients) connection\(clients == 1 ? "" : "s")")
            }
            // A shell, `docker attach` or dev container may have opened since the scan.
            if !isEngine, let user = SessionIndex(ctx.processes, ownPID: ctx.ownPID)
                .users(name: item.name, id: item.detail["id"], service: item.detail["service"]).first {
                return .skipped(reason: "\(item.name) is used by \(user)")
            }
        }
        if isEngine {
            // A build, pull or shell may have started since the engine was judged.
            if let client = Self.dockerClients(in: ctx.processes, ownPID: ctx.ownPID).first {
                return .skipped(reason: "\(item.name) is used by \(client)")
            }
            return await stopEngine(item)
        }
        guard Self.isSafeName(item.name) else { return .failed(reason: "Unexpected container name") }
        // Traffic since the last scan (moments ago) must still be negligible, measured exactly.
        let (last, socket) = memory.withLock { ($0.samples[item.name]?.last, $0.socketPath) }
        if checkActivity, let last {
            guard let socket, let bytes = await apiNetworkBytes(name: item.name, socket: socket),
                  bytes >= last.bytes, bytes - last.bytes < ContainerJudge.idleNetBytes else {
                return .skipped(reason: "\(item.name) has network traffic, or it couldn't be checked")
            }
        }
        let result = await run("docker", ["stop", item.name])
        if result.timedOut { return .failed(reason: "docker stop timed out") }
        guard result.status == 0 else {
            return .failed(reason: Self.firstLine(result.stderr, fallback: "docker stop failed (\(result.status))"))
        }
        return .stopped(UndoToken(identity: item.id, action: "start", arguments: [item.name]))
    }

    private func stopEngine(_ item: Item) async -> StopResult {
        let rawName = String(item.id.rawValue.dropFirst(Self.engineIdentityPrefix.count))
        guard let engine = ContainerEngine(rawValue: rawName) else { return .failed(reason: "Unknown container engine") }
        switch engine {
        case .colima:
            let result = await run("colima", ["stop"])
            if result.timedOut { return .failed(reason: "colima stop timed out") }
            guard result.status == 0 else {
                return .failed(reason: Self.firstLine(result.stderr, fallback: "colima stop failed (\(result.status))"))
            }
            return .stopped(UndoToken(identity: item.id, action: "colima-start", arguments: []))
        case .dockerDesktop, .orbStack:
            guard let path = item.detail["appPath"], Self.isEngineApp(path) else {
                return .failed(reason: "Can't find the \(engine.rawValue) app")
            }
            guard await quitApp(path) else { return .failed(reason: "Couldn't quit \(engine.rawValue)") }
            return .stopped(UndoToken(identity: item.id, action: "launch", arguments: [path]))
        }
    }

    public func undo(_ token: UndoToken) async -> Bool {
        switch (token.action, token.arguments.count) {
        case ("start", 1):
            guard let name = token.arguments.first, Self.isSafeName(name) else { return false }
            let result = await run("docker", ["start", name])
            return !result.timedOut && result.status == 0
        case ("launch", 1):
            guard let path = token.arguments.first, Self.isEngineApp(path) else { return false }
            return await launchApp(path)
        case ("colima-start", 0):
            let result = await run("colima", ["start"])
            return !result.timedOut && result.status == 0
        default:
            return false
        }
    }

    /// Only the engine apps we know are ever quit or launched.
    private static func isEngineApp(_ path: String) -> Bool {
        ["Docker.app", "OrbStack.app"].contains((path as NSString).lastPathComponent)
    }

    private static func firstLine(_ text: String, fallback: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)
        return (line?.isEmpty == false ? line : nil) ?? fallback
    }

    // MARK: defaults

    private static func defaultRun(_ command: String, _ args: [String]) async -> CommandResult {
        let slow = ["stop", "start"].contains(args.first ?? "")
        return await CommandRunner.run(command, args, timeout: slow ? .seconds(60) : .seconds(15))
    }

    /// Asks every running app inside the bundle (Docker ships a nested app too) to quit.
    private static func defaultQuit(_ appPath: String) async -> Bool {
        let running = NSWorkspace.shared.runningApplications.filter {
            guard let path = $0.bundleURL?.path else { return false }
            return path == appPath || path.hasPrefix(appPath + "/")
        }
        guard !running.isEmpty else { return false }
        return running.map { $0.terminate() }.contains(true)
    }

    private static func defaultLaunch(_ appPath: String) async -> Bool {
        let url = URL(fileURLWithPath: appPath)
        return (try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())) != nil
    }
}

// MARK: - Sessions into containers

/// Who mentions a container on their command line. `docker exec -it`, `docker attach`, `docker
/// compose exec` and VS Code / Cursor dev containers all go through the Docker socket, invisible to
/// ports, CPU and traffic, but they name the container (or its ID) in their arguments.
struct SessionIndex {
    private struct Entry {
        let name: String
        let tokens: Set<String>
        /// 12-character prefixes of the long hex tokens (container IDs) in the arguments.
        let idPrefixes: Set<String>
        /// A docker client: a short ID prefix typed by hand (`docker exec -it 75be sh`) counts.
        let isDockerClient: Bool
        let isCompose: Bool
    }

    private let entries: [Entry]

    /// Every process outside CleanUp's own tree.
    init(_ table: [Int32: ProcessInfoRecord], ownPID: Int32) {
        let own = ProcessTree.ownTree(ownPID, in: table)
        entries = table.values.filter { !own.contains($0.pid) }.sorted { $0.pid < $1.pid }.compactMap { p in
            var tokens = Set<String>()
            for argument in p.arguments.dropFirst() {
                tokens.formUnion(Self.tokens(argument))
                for decoded in Self.remoteAuthorities(argument) { tokens.formUnion(Self.tokens(decoded)) }
            }
            guard !tokens.isEmpty else { return nil }
            let leaf = ProcessTree.leaf(p)
            let prefixes = Set(tokens.filter { $0.count >= 12 && Self.isHex($0) }.map { String($0.prefix(12)) })
            return Entry(
                name: p.name.isEmpty ? leaf : p.name, tokens: tokens, idPrefixes: prefixes,
                isDockerClient: ContainersModule.clientNames.contains(leaf),
                isCompose: leaf == "docker-compose" || tokens.contains("compose")
            )
        }
    }

    /// Names of the processes naming this container, sorted, without duplicates.
    func users(name: String, id: String?, service: String?) -> [String] {
        let id = id.map { $0.lowercased() }.flatMap { $0.count >= 12 && Self.isHex($0) ? String($0.prefix(12)) : nil }
        var found = Set<String>()
        for entry in entries {
            var hit = entry.tokens.contains(name)
            if !hit, let id {
                hit = entry.idPrefixes.contains(id)
                    || (entry.isDockerClient && entry.tokens.contains { $0.count >= 4 && $0.count < 12 && id.hasPrefix($0) })
            }
            if !hit, let service, entry.isCompose { hit = entry.tokens.contains(service) }
            if hit { found.insert(entry.name) }
        }
        return found.sorted()
    }

    /// Runs of characters a container name or ID can contain.
    private static func tokens(_ text: String) -> [String] {
        text.split { !($0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-")) }
            .map(String.init)
    }

    /// `vscode-remote://attached-container+<hex JSON>/…` and `dev-container+<hex>`: the JSON inside
    /// names the container.
    private static func remoteAuthorities(_ argument: String) -> [String] {
        guard argument.contains("container+") else { return [] }
        var decoded: [String] = []
        for part in argument.components(separatedBy: "container+").dropFirst() {
            let hex = part.prefix { $0.isHexDigit }
            guard hex.count >= 2, hex.count % 2 == 0 else { continue }
            var bytes: [UInt8] = []
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { break }
                bytes.append(byte)
                index = next
            }
            decoded.append(String(decoding: bytes, as: UTF8.self))
        }
        return decoded
    }

    private static func isHex(_ text: String) -> Bool {
        text.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }
}
