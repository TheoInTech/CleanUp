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
    /// Interactive shells open in it through the Engine API (Docker Desktop's Exec tab, lazydocker),
    /// which no process's arguments show; nil when they couldn't be checked.
    public let openShells: Int?
    /// Other commands running in it through the Engine API (`docker exec -d`), healthchecks left out.
    public let runningCommands: Int

    public init(
        name: String, image: String, startedAt: Date, cpuPercent: Double,
        publishedPorts: [Int], clientConnections: Int, netBytesDelta: Int64?, attachedBy: [String] = [],
        openShells: Int? = 0, runningCommands: Int = 0
    ) {
        self.name = name
        self.image = image
        self.startedAt = startedAt
        self.cpuPercent = cpuPercent
        self.publishedPorts = publishedPorts
        self.clientConnections = clientConnections
        self.netBytesDelta = netBytesDelta
        self.attachedBy = attachedBy
        self.openShells = openShells
        self.runningCommands = runningCommands
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

        switch f.openShells {
        case nil:
            signals.append(Signal(kind: .inUse, text: "Couldn't check for open shells"))
            reasons.append("checking for shells")
        case let shells? where shells > 0:
            signals.append(Signal(kind: .inUse, text: shells == 1 ? "A shell is open in it" : "\(shells) shells are open in it"))
            reasons.append("shell open")
        default:
            break
        }
        if f.runningCommands > 0 {
            signals.append(Signal(kind: .inUse, text: "A command started with docker exec is still running in it"))
            reasons.append("command running")
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
    /// Whether the docker CLI's current context talks to this engine. Only then are the containers
    /// `docker ps` lists this engine's.
    public let endpoint: Endpoint
    /// Since when every condition has held without a break; nil when they don't hold now.
    public let quietSince: Date?
    /// Docker Desktop's built-in Kubernetes cluster is running (inside the engine). Always false for
    /// the other engines.
    public let kubernetesOn: Bool

    public enum Endpoint: Sendable, Equatable {
        case matches, elsewhere, unknown
    }

    public init(
        engine: ContainerEngine, containerVerdicts: [Verdict], clients: [String], overheadPercent: Double?,
        machines: Machines, otherEngineRunning: Bool, endpoint: Endpoint = .matches, quietSince: Date?,
        kubernetesOn: Bool = false
    ) {
        self.engine = engine
        self.containerVerdicts = containerVerdicts
        self.clients = clients
        self.overheadPercent = overheadPercent
        self.machines = machines
        self.otherEngineRunning = otherEngineRunning
        self.endpoint = endpoint
        self.quietSince = quietSince
        self.kubernetesOn = kubernetesOn
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
            return Judgement(
                verdict: .inUse, fact: "measuring activity", signals: signals,
                watchingUntil: (f.quietSince ?? now).addingTimeInterval(observationWindow)
            )
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

        switch f.endpoint {
        case .matches: break
        case .elsewhere:
            signals.append(Signal(kind: .inUse, text: "docker talks to another engine or host, so its containers can't be seen"))
            reasons.append("docker is pointed elsewhere")
        case .unknown:
            signals.append(Signal(kind: .inUse, text: "Couldn't read which engine docker talks to"))
            reasons.append("couldn't read the docker context")
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

        if f.kubernetesOn {
            signals.append(Signal(kind: .inUse, text: "Its Kubernetes cluster is running"))
            reasons.append("Kubernetes is on")
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
    /// Colima only: the profiles whose VM is running (`default`, `work`, …).
    var colimaProfiles: Set<String> = []

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
    private let home: String
    private let resolveLink: @Sendable (String) -> String

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
        /// What runs in it through `docker exec`; nil when it couldn't be checked.
        let execs: ExecActivity?
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
        /// Where the docker CLI's current context points, read on every external scan; nil when it
        /// couldn't be read.
        var context: ContextTarget?
        /// Docker Engine API socket of that context, when it is a local engine's.
        var socketPath: String?
        /// When docker was last asked, and when engines were last judged: for spotting unwatched gaps.
        var lastCollect: Date?
        var lastEngineScan: Date?
        /// OrbStack's Linux machines at the last external scan.
        var orbMachines: EngineFacts.Machines = .unknown
        /// Since when each engine has been quiet without a break.
        var engineQuietSince: [ContainerEngine: Date] = [:]
        /// Parsed process arguments, reused by the next scan's session check.
        var sessionCache = SessionIndex.Cache()
    }

    /// Idleness has to hold for this long: low CPU the whole time, and traffic measured against a
    /// baseline at least this old. One quiet sample proves nothing about a database queried every few minutes.
    static let observationWindow: TimeInterval = 10 * 60

    private let memory = OSAllocatedUnfairLock(initialState: Memory())
    private let readKubeconfig: @Sendable () -> String?

    /// - Parameters:
    ///   - home: the user's home, where engines keep their sockets (`~/.docker/run`, `~/.orbstack`, `~/.colima`).
    ///   - resolveLink: resolves symbolic links in a socket path (`/var/run/docker.sock` is usually one).
    public init(
        run: Run? = nil, quitApp: AppAction? = nil, launchApp: AppAction? = nil,
        home: String = NSHomeDirectory(),
        resolveLink: (@Sendable (String) -> String)? = nil,
        readKubeconfig: (@Sendable () -> String?)? = nil
    ) {
        self.readKubeconfig = readKubeconfig ?? { [home] in
            let path = ProcessInfo.processInfo.environment["KUBECONFIG"]?.split(separator: ":").first.map(String.init)
                ?? home + "/.kube/config"
            return try? String(contentsOfFile: path, encoding: .utf8)
        }
        self.run = run ?? { await Self.defaultRun($0, $1) }
        self.quitApp = quitApp ?? { await Self.defaultQuit($0) }
        self.launchApp = launchApp ?? { await Self.defaultLaunch($0) }
        self.home = home
        self.resolveLink = resolveLink ?? { ($0 as NSString).resolvingSymlinksInPath }
    }

    public func restartObservation() {
        memory.withLock { state in
            state.samples = [:]
            state.lowCPUSince = [:]
            state.engineQuietSince = [:]
        }
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
        // No engine running: asking docker could start one (or a helper). Claim nothing.
        guard !engines.isEmpty else {
            memory.withLock { $0 = Memory() }
            return nil
        }
        memory.withLock { state in
            if ObservationWindow.isGap(since: state.lastCollect, now: now) {
                state.samples = [:]
                state.lowCPUSince = [:]
            }
            state.lastCollect = max(state.lastCollect ?? now, now)
        }
        async let orbList: CommandResult? = engines.contains { $0.engine == .orbStack } ? run("orb", ["list"]) : nil
        async let contextResult = run("docker", ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"])
        let ps = await run("docker", ["ps", "--format", "{{json .}}"])
        let machines = await orbList.map(Self.orbMachines) ?? .unknown
        let context = await contextResult
        guard ps.status == 0, !ps.timedOut else {
            memory.withLock { $0 = Memory() }
            return nil
        }
        let host = context.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = (context.status == 0 && !context.timedOut)
            ? Self.contextTarget(host: host, home: home, resolveLink: resolveLink) : nil
        memory.withLock { state in
            state.orbMachines = machines
            state.context = target
            if case .engine = target, host.hasPrefix("unix:///") {
                state.socketPath = String(host.dropFirst("unix://".count))
            } else {
                state.socketPath = nil
            }
        }
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
        let socket = memory.withLock { $0.socketPath }
        let counters = await networkBytes(of: running.map(\.name), socket: socket)
        let stats = await statsResult
        let inspect = await inspectResult
        // `docker stats` supplies CPU only: its NetIO is rounded to 3 significant figures.
        let statsByName = (stats.status == 0 && !stats.timedOut) ? Self.parseStats(stats.stdout) : [:]
        let inspected = (inspect.status == 0 && !inspect.timedOut) ? Self.parseInspect(inspect.stdout) : [:]
        var checked: [String: ExecActivity] = [:]
        let clock = ContinuousClock(), deadline = clock.now + Self.execCheckBudget
        for (name, row) in inspected.sorted(by: { $0.key < $1.key }) {
            // Past the budget (a hanging Engine API), the rest stay unchecked: in use.
            if !row.execIDs.isEmpty, clock.now > deadline { continue }
            if let activity = await execActivity(execIDs: row.execIDs, healthcheck: row.healthcheck, socket: socket) {
                checked[name] = activity
            }
        }
        let execs = checked

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
                    cpuPercent: cpu, netBytesDelta: delta, lowCPUSince: lowCPU[row.name], execs: execs[row.name]
                )
            }
            state.samples = samples
            state.lowCPUSince = lowCPU
            state.collected = rows
            return rows
        }
    }

    // MARK: Docker Engine API

    /// Where a docker context endpoint leads: one of the engines on this Mac (by its socket), or
    /// somewhere else (a remote host, another user's socket, a path we don't know).
    public enum ContextTarget: Sendable, Equatable {
        case engine(ContainerEngine, profile: String?)
        case elsewhere
    }

    /// Maps `docker context inspect`'s Host to an engine: `~/.docker/run/…` or `/var/run/docker.sock`
    /// → Docker Desktop, `~/.orbstack/…` → OrbStack, `~/.colima/<profile>/…` → that Colima profile.
    /// Links are resolved first (`/var/run/docker.sock` often points at OrbStack's or Colima's socket).
    static func contextTarget(host: String, home: String, resolveLink: (String) -> String) -> ContextTarget {
        guard host.hasPrefix("unix:///") else { return .elsewhere }
        let raw = String(host.dropFirst("unix://".count))
        let path = resolveLink(raw)
        let homeDir = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == "/var/run/docker.sock" || path == "/private/var/run/docker.sock" || path.hasPrefix(homeDir + "/.docker/run/") {
            return .engine(.dockerDesktop, profile: nil)
        }
        if path.hasPrefix(homeDir + "/.orbstack/") { return .engine(.orbStack, profile: nil) }
        let colima = homeDir + "/.colima/"
        if path.hasPrefix(colima) {
            let parts = path.dropFirst(colima.count).split(separator: "/").map(String.init)
            guard let first = parts.first else { return .elsewhere }
            if first == "docker.sock" { return .engine(.colima, profile: "default") }
            guard first != "_lima", isSafeName(first) else { return .elsewhere }
            return .engine(.colima, profile: first)
        }
        return .elsewhere
    }

    /// At most this many Engine API calls run at once.
    static let maxConcurrentAPICalls = 4

    /// Exact rx + tx bytes per container from the Engine API, a few at a time (each call has a
    /// 10 s cap). Containers whose counter can't be read are absent.
    private func networkBytes(of names: [String], socket: String?) async -> [String: Int64] {
        guard let socket else { return [:] }
        return await withTaskGroup(of: (String, Int64?).self) { group in
            var pending = names[...]
            func startNext() {
                guard let name = pending.popFirst() else { return }
                group.addTask { (name, await self.apiNetworkBytes(name: name, socket: socket)) }
            }
            for _ in 0..<Self.maxConcurrentAPICalls { startNext() }
            var found: [String: Int64] = [:]
            for await (name, bytes) in group {
                if let bytes { found[name] = bytes }
                startNext()
            }
            return found
        }
    }

    /// Exec instances checked per container; more than this can't all be checked, so they count as in use.
    static let maxExecsChecked = 8
    /// All exec checks of one scan together get this long; containers not reached by then are unchecked (in use).
    static let execCheckBudget: Duration = .seconds(10)

    /// What is running in a container through `docker exec`.
    struct ExecActivity: Sendable, Equatable {
        /// Interactive sessions (stdin or a tty): Docker Desktop's Exec tab, lazydocker, `docker exec -it`.
        var shells = 0
        /// Anything else still running that isn't the container's own healthcheck (`docker exec -d`, a job
        /// an extension started).
        var commands = 0
    }

    /// The running execs of a container, its healthcheck probes left out. A probe is an exec running
    /// exactly the healthcheck's command; anything else that runs counts. Nil when one couldn't be checked.
    private func execActivity(execIDs: [String], healthcheck: [String]?, socket: String?) async -> ExecActivity? {
        guard !execIDs.isEmpty else { return ExecActivity() }
        guard let socket, execIDs.count <= Self.maxExecsChecked else { return nil }
        let probe = Self.probeCommand(healthcheck)
        var activity = ExecActivity()
        for id in execIDs {
            // Exec IDs are 64 hex characters; anything else never reaches a URL.
            guard (12...128).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
            let result = await run("/usr/bin/curl", [
                "--silent", "--max-time", "5", "--unix-socket", socket, "http://localhost/exec/\(id)/json",
            ])
            guard result.status == 0, !result.timedOut, let exec = Self.parseExec(result.stdout) else { return nil }
            switch exec {
            case .finished: break
            case .interactive: activity.shells += 1
            case .background(let command): if command != probe { activity.commands += 1 }
            }
        }
        return activity
    }

    /// The command Docker runs for a healthcheck test: `CMD-SHELL x` → `/bin/sh -c x`, `CMD a b` → `a b`.
    static func probeCommand(_ test: [String]?) -> [String]? {
        guard let test, let kind = test.first else { return nil }
        switch kind {
        case "CMD-SHELL": return test.count == 2 ? ["/bin/sh", "-c", test[1]] : nil
        case "CMD": return test.count > 1 ? Array(test.dropFirst()) : nil
        default: return nil   // NONE, or inherited from the image and unknown here
        }
    }

    enum ExecState: Equatable {
        case finished
        case interactive
        /// Running with no stdin and no tty: a healthcheck probe or a detached command.
        case background(command: [String])
    }

    /// `/exec/<id>/json`. An exec that finished before we asked ("No such exec instance") is finished.
    static func parseExec(_ json: String) -> ExecState? {
        struct Exec: Decodable {
            struct Config: Decodable {
                let tty: Bool?
                let entrypoint: String?
                let arguments: [String]?
            }
            let Running: Bool
            let OpenStdin: Bool?
            let ProcessConfig: Config?
        }
        struct Message: Decodable { let message: String }
        let data = Data(json.utf8)
        if let exec = try? JSONDecoder().decode(Exec.self, from: data) {
            guard exec.Running else { return .finished }
            if exec.OpenStdin == true || exec.ProcessConfig?.tty == true { return .interactive }
            let config = exec.ProcessConfig
            return .background(command: [config?.entrypoint ?? ""] + (config?.arguments ?? []))
        }
        if let message = try? JSONDecoder().decode(Message.self, from: data), message.message.hasPrefix("No such exec instance") {
            return .finished
        }
        return nil
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
        // The engine quit since docker was last asked: what was listed is gone with it.
        guard !engines.isEmpty else { return [] }
        let proxyPIDs = engines.reduce(into: Set<Int32>()) { $0.formUnion($1.allPIDs) }
        // Parsed outside the lock (a cold parse takes a while); the cache goes back in afterwards.
        var sessions: SessionIndex?
        if !collected.isEmpty {
            var cache = memory.withLock { $0.sessionCache }
            sessions = SessionIndex(ctx.processes, ownPID: ctx.ownPID, cache: &cache)
            memory.withLock { [cache] in $0.sessionCache = cache }
        }
        let context = memory.withLock { $0.context }
        let endpoints = Dictionary(uniqueKeysWithValues: engines.map { ($0.engine, Self.endpoint(context, of: $0)) })
        // The containers docker lists belong to the engine its context points at, if that one runs here.
        let host = engines.first { endpoints[$0.engine] == .matches }
        let elsewhere: String? = host != nil ? nil : (context == nil ? "couldn't read the docker context" : "on another Docker host")

        var containerItems: [Item] = []
        var verdicts: [Verdict] = []
        var allPorts = Set<Int>()
        var containersCPU = 0.0
        for c in collected.sorted(by: { $0.name < $1.name }) {
            let users = sessions?.users(name: c.name, id: c.id, service: c.service) ?? []
            let item = Self.containerItem(
                c, engine: host?.engine, elsewhere: elsewhere, proxyPIDs: proxyPIDs, attachedBy: users, ctx: ctx
            )
            containerItems.append(item)
            verdicts.append(item.judgement.verdict)
            allPorts.formUnion(c.ports ?? [])
            containersCPU += c.cpuPercent ?? 0
        }

        let clients = Self.dockerClients(in: ctx.processes, ownPID: ctx.ownPID)
        let machines = memory.withLock { state -> EngineFacts.Machines in
            if ObservationWindow.isGap(since: state.lastEngineScan, now: ctx.now) { state.engineQuietSince = [:] }
            state.lastEngineScan = max(state.lastEngineScan ?? ctx.now, ctx.now)
            return state.orbMachines
        }
        // Docker Desktop's own cluster on 6443, plus any cluster ~/.kube/config says runs on this Mac.
        let clusterPorts = engines.contains { $0.engine == .dockerDesktop }
            ? Self.localClusterPorts(readKubeconfig() ?? "").union([Self.kubernetesAPIPort]) : []
        let engineItems = engines.map { e -> Item in
            let (overhead, cores) = Self.overhead(of: e, containersCPU: containersCPU, cpu: ctx.cpu)
            // Its kube-apiserver is forwarded to this Mac: no file to read (another app's container would ask
            // for permission), just a socket of its own.
            let kubernetes = e.engine == .dockerDesktop && ctx.sockets.contains {
                $0.state == .listen && clusterPorts.contains($0.localPort) && e.allPIDs.contains($0.pid)
            }
            // Two engines can run at once but the docker CLI talks to only one of them, so we can't say
            // whose containers these are, or whether the other engine hosts any: never offer to quit.
            let draft = EngineFacts(
                engine: e.engine, containerVerdicts: verdicts, clients: clients, overheadPercent: overhead,
                machines: e.engine == .orbStack ? machines : .notApplicable,
                otherEngineRunning: engines.count > 1, endpoint: endpoints[e.engine] ?? .unknown, quietSince: nil,
                kubernetesOn: kubernetes
            )
            let since = rememberQuiet(e.engine, quiet: EngineJudge.isQuietNow(draft), now: ctx.now)
            let facts = EngineFacts(
                engine: draft.engine, containerVerdicts: verdicts, clients: clients, overheadPercent: overhead,
                machines: draft.machines, otherEngineRunning: draft.otherEngineRunning, endpoint: draft.endpoint,
                quietSince: since, kubernetesOn: kubernetes
            )
            var item = Self.engineItem(e, facts: facts, cores: cores, ports: allPorts, ctx: ctx)
            if e.engine == .colima, draft.endpoint == .matches, case .engine(_, let profile?) = context {
                item = item.with(detail: "profile", profile)
            }
            return item
        }
        let running = Set(engines.map(\.engine))
        memory.withLock { state in state.engineQuietSince = state.engineQuietSince.filter { running.contains($0.key) } }
        return containerItems + engineItems
    }

    /// Docker Desktop's Kubernetes API server port, which its backend listens on (on this Mac)
    /// while the cluster runs.
    static let kubernetesAPIPort = 6443

    /// Ports of the kubeconfig clusters whose API server is on this Mac (`server: https://127.0.0.1:52817`).
    static func localClusterPorts(_ kubeconfig: String) -> Set<Int> {
        let local = /server:\s*["']?https?:\/\/(?:127\.0\.0\.1|localhost|kubernetes\.docker\.internal|\[::1\]):(\d{1,5})/
        return Set(kubeconfig.matches(of: local).compactMap { Int($0.output.1) })
    }

    /// Whether the docker context talks to this engine. A Colima context matches only while that
    /// profile, and no other, is the one running.
    private static func endpoint(_ context: ContextTarget?, of e: DetectedEngine) -> EngineFacts.Endpoint {
        guard let context else { return .unknown }
        guard case .engine(let engine, let profile) = context, engine == e.engine else { return .elsewhere }
        if engine == .colima { return e.colimaProfiles == [profile ?? "default"] ? .matches : .elsewhere }
        return .matches
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
        _ c: Collected, engine: ContainerEngine?, elsewhere: String?, proxyPIDs: Set<Int32>, attachedBy: [String], ctx: ScanContext
    ) -> Item {
        var detail = ["image": c.image, "id": c.id]
        if let service = c.service { detail["service"] = service }
        if !attachedBy.isEmpty { detail["usedBy"] = attachedBy.joined(separator: ", ") }
        if let ports = c.ports, !ports.isEmpty { detail["ports"] = ports.map(String.init).joined(separator: ",") }
        if let engine { detail["engine"] = engine.rawValue }

        let judgement: Judgement
        var cores = 0.0
        if let elsewhere {
            // Not this Mac's engine (or we can't tell): its connections and sessions can't be seen from here.
            cores = 0
            judgement = Judgement(
                verdict: .inUse, fact: elsewhere,
                signals: [Signal(kind: .inUse, text: "docker talks to another engine or host, so CleanUp can't tell who uses it")]
            )
        } else if let startedAt = c.startedAt, let ports = c.ports, let cpu = c.cpuPercent {
            cores = cpu / 100
            let facts = ContainerFacts(
                name: c.name, image: c.image, startedAt: startedAt, cpuPercent: cpu, publishedPorts: ports,
                clientConnections: clientConnections(ports: ports, sockets: ctx.sockets, excluding: proxyPIDs),
                netBytesDelta: c.netBytesDelta, attachedBy: attachedBy,
                openShells: c.execs?.shells, runningCommands: c.execs?.commands ?? 0
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
        return Judgement(
            verdict: .inUse, fact: "measuring activity", signals: judgement.signals + [Signal(kind: .inUse, text: text)],
            watchingUntil: (since ?? now).addingTimeInterval(observationWindow)
        )
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
                appPath: appBundle(of: processes, engine: engine),
                colimaProfiles: engine == .colima ? colimaProfiles(processes) : []
            )
        }
    }

    private static func leaf(_ p: ProcessInfoRecord) -> String { (p.path as NSString).lastPathComponent }

    /// Lima instances `colima` (profile `default`) and `colima-<profile>`, from `…/.colima/_lima/<instance>/…`.
    private static func colimaProfiles(_ processes: [ProcessInfoRecord]) -> Set<String> {
        var profiles = Set<String>()
        for p in processes {
            for argument in p.arguments {
                for part in argument.components(separatedBy: "_lima/").dropFirst() {
                    let instance = String(part.prefix { $0 != "/" })
                    if instance == "colima" { profiles.insert("default") }
                    else if instance.hasPrefix("colima-") { profiles.insert(String(instance.dropFirst("colima-".count))) }
                }
            }
        }
        return profiles
    }

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
        #"{"Id":{{json .Id}},"Name":{{json .Name}},"State":{"StartedAt":{{json .State.StartedAt}}},"NetworkSettings":{"Ports":{{json .NetworkSettings.Ports}}},"Service":{{json (index .Config.Labels "com.docker.compose.service")}},"ExecIDs":{{json .ExecIDs}},"Healthcheck":{{json .Config.Healthcheck}}}"#

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
    static func parseInspect(_ out: String) -> [String: (startedAt: Date, ports: [Int], service: String?, execIDs: [String], id: String?, healthcheck: [String]?)] {
        struct Binding: Decodable { let HostPort: String? }
        struct Row: Decodable {
            struct State: Decodable { let StartedAt: String }
            struct Network: Decodable { let Ports: [String: [Binding]?]? }
            let Name: String
            let State: State
            let NetworkSettings: Network
            let Service: String?
            let ExecIDs: [String]?
            let Id: String?
            struct Health: Decodable { let Test: [String]? }
            let Healthcheck: Health?
        }
        var result: [String: (startedAt: Date, ports: [Int], service: String?, execIDs: [String], id: String?, healthcheck: [String]?)] = [:]
        for row in jsonLines(out, as: Row.self) {
            // Docker's zero date means "never started"; treat it as unknown.
            guard let started = parseDate(row.State.StartedAt), started.timeIntervalSince1970 > 946_684_800 else { continue }
            let ports = (row.NetworkSettings.Ports ?? [:]).values
                .flatMap { $0 ?? [] }
                .compactMap { $0.HostPort.flatMap { Int($0) } }
            let service = row.Service.flatMap { $0.isEmpty ? nil : $0 }
            result[row.Name.hasPrefix("/") ? String(row.Name.dropFirst()) : row.Name] = (started, Array(Set(ports)).sorted(), service, row.ExecIDs ?? [], row.Id.map { String($0.lowercased().prefix(12)) }, row.Healthcheck?.Test)
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
        // No sample to compare with means it can't be checked: never stop on trust.
        if checkActivity {
            let (last, socket) = memory.withLock { ($0.samples[item.name]?.last, $0.socketPath) }
            guard let last, let socket, let bytes = await apiNetworkBytes(name: item.name, socket: socket) else {
                return .skipped(reason: "couldn't check \(item.name)'s traffic")
            }
            guard bytes >= last.bytes, bytes - last.bytes < ContainerJudge.idleNetBytes else {
                return .skipped(reason: "\(item.name) has network traffic")
            }
            // A shell opened from Docker Desktop or lazydocker since the scan shows only as an exec.
            let inspect = await run("docker", ["inspect", "--format", Self.inspectTemplate, item.name])
            guard inspect.status == 0, !inspect.timedOut, let row = Self.parseInspect(inspect.stdout)[item.name] else {
                return .skipped(reason: "couldn't check \(item.name) for shells")
            }
            if let scanned = Self.containerID(item), row.id != scanned {
                return .skipped(reason: "\(item.name) was replaced since")
            }
            guard let execs = await execActivity(execIDs: row.execIDs, healthcheck: row.healthcheck, socket: socket) else {
                return .skipped(reason: "couldn't check \(item.name) for shells")
            }
            guard execs.shells == 0 else { return .skipped(reason: "\(item.name) has a shell open") }
            guard execs.commands == 0 else { return .skipped(reason: "\(item.name) is running a command") }
        }
        // By ID when known: a container recreated under the same name since the scan is a different one.
        let result = await run("docker", ["stop", Self.containerID(item) ?? item.name])
        if result.timedOut { return .failed(reason: "docker stop timed out") }
        guard result.status == 0 else {
            return .failed(reason: Self.firstLine(result.stderr, fallback: "docker stop failed (\(result.status))"))
        }
        return .stopped(UndoToken(identity: item.id, action: "start", arguments: [item.name]))
    }

    /// The 12-character ID `docker ps` gave at scan time, when it looks like one.
    static func containerID(_ item: Item) -> String? {
        guard let id = item.detail["id"], id.utf8.count == 12,
              id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return id
    }

    private func stopEngine(_ item: Item) async -> StopResult {
        let rawName = String(item.id.rawValue.dropFirst(Self.engineIdentityPrefix.count))
        guard let engine = ContainerEngine(rawValue: rawName) else { return .failed(reason: "Unknown container engine") }
        switch engine {
        case .colima:
            // Only the profile docker was judged against; plain `colima stop` would stop the default one.
            guard let profile = item.detail["profile"], Self.isSafeName(profile) else {
                return .failed(reason: "Can't tell which Colima profile to stop")
            }
            let result = await run("colima", ["stop", "-p", profile])
            if result.timedOut { return .failed(reason: "colima stop timed out") }
            guard result.status == 0 else {
                return .failed(reason: Self.firstLine(result.stderr, fallback: "colima stop failed (\(result.status))"))
            }
            return .stopped(UndoToken(identity: item.id, action: "colima-start", arguments: [profile]))
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
        case ("colima-start", 1):
            guard let profile = token.arguments.first, Self.isSafeName(profile) else { return false }
            let result = await run("colima", ["start", "-p", profile])
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
        await MainActor.run {
            let running = NSWorkspace.shared.runningApplications.filter {
                guard let path = $0.bundleURL?.path else { return false }
                return path == appPath || path.hasPrefix(appPath + "/")
            }
            guard !running.isEmpty else { return false }
            return running.map { $0.terminate() }.contains(true)
        }
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
    /// Parsed arguments per process, kept between scans: a process's arguments rarely change, and
    /// parsing every argument of every process costs ~18 ms a scan. Keyed by pid + start time; the
    /// arguments' hash is checked so a process that rewrites them is parsed again.
    typealias Cache = [ProcessRef: Cached]
    struct Cached: Sendable {
        let argumentsHash: Int
        let entry: Entry?
    }

    struct Entry: Sendable {
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
        var cache = Cache()
        self.init(table, ownPID: ownPID, cache: &cache)
    }

    /// Same, reusing what `cache` already parsed; afterwards it holds exactly the processes in `table`.
    init(_ table: [Int32: ProcessInfoRecord], ownPID: Int32, cache: inout Cache) {
        let own = ProcessTree.ownTree(ownPID, in: table)
        var next = Cache(minimumCapacity: table.count)
        var entries: [Entry] = []
        for p in table.values.sorted(by: { $0.pid < $1.pid }) {
            let hash = p.arguments.hashValue
            let cached = cache[p.ref].flatMap { $0.argumentsHash == hash ? $0 : nil } ?? Cached(argumentsHash: hash, entry: Self.entry(p))
            next[p.ref] = cached
            if !own.contains(p.pid), let entry = cached.entry { entries.append(entry) }
        }
        cache = next
        self.entries = entries
    }

    private static func entry(_ p: ProcessInfoRecord) -> Entry? {
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
