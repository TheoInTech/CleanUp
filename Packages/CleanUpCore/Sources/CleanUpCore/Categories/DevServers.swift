import Darwin
import Foundation
import os

// MARK: - Facts and judgement

public struct DevServerFacts: Sendable {
    /// The listening process (pid + start time); its start time gives the server's age.
    public let ref: ProcessRef
    /// Short command without ports, e.g. `expo start`.
    public let command: String
    public let projectName: String
    public let cwd: String
    public let ports: [Int]
    /// Established TCP connections to the server's ports right now, discounting the tree's own.
    public let establishedNow: Int
    public let lastConnectionSeen: Date?
    /// Whole-tree CPU, 100 = one full core. `.nan` when it has not been measured (first refresh).
    public let cpuPercent: Double
    /// The tree's root has been re-parented to launchd: the terminal that started it is gone.
    public let orphaned: Bool
    /// How long CleanUp has been watching this server without interruption.
    public let observedFor: TimeInterval

    public init(
        ref: ProcessRef, command: String, projectName: String, cwd: String, ports: [Int],
        establishedNow: Int, lastConnectionSeen: Date?, cpuPercent: Double, orphaned: Bool, observedFor: TimeInterval
    ) {
        self.ref = ref
        self.command = command
        self.projectName = projectName
        self.cwd = cwd
        self.ports = ports
        self.establishedNow = establishedNow
        self.lastConnectionSeen = lastConnectionSeen
        self.cpuPercent = cpuPercent
        self.orphaned = orphaned
        self.observedFor = observedFor
    }
}

public enum DevServerJudge {
    /// A server must have been up this long before it counts as idle.
    public static let minimumAge: TimeInterval = 6 * 3_600
    public static let idleCPUPercent = 2.0
    /// No connection may have been seen for this long.
    public static let quietPeriod: TimeInterval = 30 * 60
    /// HTTP connections are short-lived and a scan can miss them, so CleanUp must have watched this long.
    public static let observationWindow: TimeInterval = 30 * 60

    /// Idle only when every condition holds; anything unknown is in use.
    public static func judge(_ f: DevServerFacts, now: Date) -> Judgement {
        var signals: [Signal] = []
        var reasons: [String] = []   // in-use reasons, strongest first

        if f.establishedNow == 0 {
            signals.append(Signal(kind: .idle, text: "Nothing is connected to it"))
        } else {
            let text = f.establishedNow == 1 ? "1 connection" : "\(f.establishedNow) connections"
            signals.append(Signal(kind: .inUse, text: "\(text) open right now"))
            reasons.append(text)
        }

        if f.cpuPercent.isNaN {
            signals.append(Signal(kind: .inUse, text: "CPU use not measured yet"))
            reasons.append("measuring CPU")
        } else {
            let cpu = String(format: "%.1f", f.cpuPercent)
            if f.cpuPercent < idleCPUPercent {
                signals.append(Signal(kind: .idle, text: "Using \(cpu)% of a core"))
            } else {
                signals.append(Signal(kind: .inUse, text: "Using \(cpu)% of a core"))
                reasons.append("busy")
            }
        }

        if let last = f.lastConnectionSeen {
            let since = now.timeIntervalSince(last)
            if since >= quietPeriod {
                signals.append(Signal(kind: .idle, text: "Last connection \(RelativeAge.short(since)) ago"))
            } else {
                signals.append(Signal(kind: .inUse, text: "Connection seen \(RelativeAge.short(since)) ago"))
                reasons.append("connection \(RelativeAge.short(since)) ago")
            }
        } else {
            signals.append(Signal(kind: .idle, text: "No connection seen while watching"))
        }

        let age = now.timeIntervalSince(f.ref.startTime)
        if age >= minimumAge {
            signals.append(Signal(kind: .idle, text: "Running for \(RelativeAge.short(age))"))
        } else {
            signals.append(Signal(kind: .inUse, text: "Started \(RelativeAge.short(age)) ago"))
            reasons.append("started \(RelativeAge.short(age)) ago")
        }

        if f.observedFor >= observationWindow {
            signals.append(Signal(kind: .idle, text: "Watched for \(RelativeAge.short(f.observedFor))"))
        } else {
            let window = RelativeAge.short(observationWindow)
            signals.append(Signal(kind: .inUse, text: "Still watching for connections (\(window))"))
            reasons.append("watching for \(window)")
        }

        if f.orphaned {
            signals.append(Signal(kind: .neutral, text: "no terminal attached"))
        }

        if let reason = reasons.first {
            return Judgement(verdict: .inUse, fact: reason, signals: signals)
        }
        return Judgement(verdict: .idle, fact: "running \(RelativeAge.short(age))", signals: signals)
    }
}

// MARK: - Module

public struct DevServersModule: CategoryModule {
    public var id: CategoryID { .devServers }

    /// What CleanUp remembers about one server between scans.
    private struct Watch: Sendable {
        /// Distinguishes a restarted server (same identity, new process) from the old one.
        let startTime: Date
        let firstSeen: Date
        var lastConnection: Date?
    }

    private struct Memory: Sendable {
        var watches: [ItemIdentity: Watch] = [:]
        var projectNames: [String: String] = [:]
        var lastScan: Date?
    }

    private let memory = OSAllocatedUnfairLock(initialState: Memory())
    private let termGrace: Duration
    private let home: String
    private let fileExists: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - termGrace: how long SIGTERM'd processes get before SIGKILL.
    ///   - home: the user's home directory (listening binaries under it are candidates).
    ///   - fileExists: filesystem probe used to find project roots; injectable for tests.
    public init(
        termGrace: Duration = .seconds(5),
        home: String = NSHomeDirectory(),
        fileExists: (@Sendable (String) -> Bool)? = nil
    ) {
        self.termGrace = termGrace
        self.home = home
        self.fileExists = fileExists ?? { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: candidates

    private static let runtimeNames: Set<String> = [
        "node", "bun", "deno", "python", "python3", "ruby", "java", "php", "go", "uvicorn", "gunicorn", "rails",
    ]
    /// Processes the tree walk may climb through to find the server's root.
    private static let launcherNames: Set<String> = ["node", "npm", "npx", "yarn", "pnpm", "bun"]
    private static let scratchPrefixes = ["/private/var/folders/", "/private/tmp/", "/var/folders/", "/tmp/"]
    private static let shellsAndTerminals: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "launchd", "login", "tmux", "screen",
        "terminal", "iterm2", "iterm", "ghostty", "alacritty", "kitty", "wezterm", "wezterm-gui", "warp", "hyper",
    ]
    private static let agentNames: Set<String> = ["claude", "claude-code", "codex", "gemini", "aider", "opencode", "cursor-agent"]

    /// Ordinary user dev servers only: our own user's, outside `.app` bundles and system locations,
    /// and either a known runtime or a binary living under home / scratch space. Shells, terminals
    /// and coding agents never qualify, however they got a listening socket.
    public static func isCandidate(_ p: ProcessInfoRecord, ownUID: uid_t, home: String = NSHomeDirectory()) -> Bool {
        guard p.uid == ownUID, p.uid != 0, !p.path.isEmpty else { return false }
        guard !p.path.contains(".app/"), !ProcessSignaler.isProtected(path: p.path, name: p.name) else { return false }
        guard !isShellOrTerminal(p), !isAgent(p) else { return false }
        if isRuntime(p) { return true }
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        return p.path.hasPrefix(homePrefix) || scratchPrefixes.contains { p.path.hasPrefix($0) }
    }

    private static func lowercasedNames(_ p: ProcessInfoRecord) -> [String] {
        [p.name, (p.path as NSString).lastPathComponent].map { $0.lowercased() }
    }

    /// `python3.12` → `python`: runtime names with a version suffix still count.
    private static func stripVersion(_ name: String) -> String {
        name.trimmingCharacters(in: CharacterSet(charactersIn: "0123456789."))
    }

    private static func isRuntime(_ p: ProcessInfoRecord) -> Bool {
        lowercasedNames(p).contains { runtimeNames.contains($0) || runtimeNames.contains(stripVersion($0)) }
    }

    private static func isShellOrTerminal(_ p: ProcessInfoRecord) -> Bool {
        lowercasedNames(p).contains { shellsAndTerminals.contains($0) }
    }

    /// A coding agent is often just `node …/claude-code/cli.js`, so the arguments matter too.
    private static func isAgent(_ p: ProcessInfoRecord) -> Bool {
        if lowercasedNames(p).contains(where: agentNames.contains) { return true }
        return p.arguments.prefix(4).contains { argument in
            let lower = argument.lowercased()
            let leaf = (lower as NSString).lastPathComponent
            return lower.contains("claude-code") || lower.contains("@anthropic-ai") || lower.contains("@openai/codex")
                || agentNames.contains(leaf) || leaf == "codex.js"
        }
    }

    // MARK: display names

    private static let interpreterNames: Set<String> = ["node", "bun", "deno", "python", "ruby", "java", "php", "go", "tsx", "ts-node"]

    private static func leaf(_ argument: String) -> String {
        var name = (argument as NSString).lastPathComponent
        // `next-server (v16.2.10)`: node with a rewritten title.
        if let paren = name.range(of: " (") , name.hasSuffix(")") { name = String(name[..<paren.lowerBound]) }
        return name
    }

    private static func isInterpreter(_ name: String) -> Bool {
        let lower = name.lowercased()
        return interpreterNames.contains(lower) || interpreterNames.contains(stripVersion(lower))
    }

    private static func isSubcommand(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, word.count <= 16, ("a"..."z").contains(first) else { return false }
        return word.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    /// `node …/.bin/expo start --clear` → `expo start`; `next-server (v16.2.10)` → `next-server`.
    static func shortCommand(_ p: ProcessInfoRecord) -> String {
        let args = p.arguments.filter { !$0.isEmpty }
        guard let first = args.first else { return leaf(p.name) }
        var base = leaf(first)
        var rest = args.dropFirst()
        if isInterpreter(base) {
            // Skip interpreter flags up to the script.
            guard let scriptIndex = rest.firstIndex(where: { !$0.hasPrefix("-") }) else { return base }
            base = leaf(rest[scriptIndex])
            rest = rest[(scriptIndex + 1)...]
        }
        if let next = rest.first, isSubcommand(next) { return "\(base) \(next)" }
        return base
    }

    private static func displayName(command: String, ports: [Int]) -> String {
        ports.isEmpty ? command : "\(command) \(ports.map { ":\($0)" }.joined(separator: ", "))"
    }

    // MARK: project names

    /// Nearest ancestor of `cwd` holding `.git` or `package.json`; a `package.json` below a git root
    /// is shown as `<git-root>/<subpath>`. Stops at home. Without a cwd: the executable's folder.
    static func projectName(
        cwd: String?, executable: String, home: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "/" else {
            let folder = ((executable as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return folder.isEmpty || folder == "/" ? "unknown project" : folder
        }
        let homeDir = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        var dir = cwd
        var packageDir: String?
        var gitRoot: String?
        for _ in 0..<64 where dir != "/" && !dir.isEmpty && dir != homeDir {
            if exists(dir + "/.git") { gitRoot = dir; break }
            if packageDir == nil, !isGeneratedPath(dir), exists(dir + "/package.json") { packageDir = dir }
            dir = (dir as NSString).deletingLastPathComponent
        }
        let name = { (path: String) in (path as NSString).lastPathComponent }
        switch (gitRoot, packageDir) {
        case let (git?, pkg?):
            return name(git) + "/" + String(pkg.dropFirst(git.count + 1))
        case let (git?, nil):
            return name(git)
        case let (nil, pkg?):
            return name(pkg)
        case (nil, nil):
            return name(cwd)
        }
    }

    /// Build output that carries its own package.json (e.g. Next's `.next/standalone`) is never the project.
    private static func isGeneratedPath(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == ".next" || $0 == "node_modules" }
    }

    private func projectName(for process: ProcessInfoRecord) -> String {
        let key = (process.cwd ?? "") + "\n" + (process.cwd == nil ? process.path : "")
        if let cached = memory.withLock({ $0.projectNames[key] }) { return cached }
        let name = Self.projectName(cwd: process.cwd, executable: process.path, home: home, exists: fileExists)
        memory.withLock { state in
            if state.projectNames.count > 500 { state.projectNames.removeAll() }
            state.projectNames[key] = name
        }
        return name
    }

    // MARK: scan

    private struct Group {
        let root: ProcessInfoRecord
        var listeners: [ProcessInfoRecord] = []
    }

    public func restartObservation() {
        memory.withLock { $0.watches = [:] }
    }

    public func scan(_ ctx: ScanContext) async -> [Item] {
        let ownUID = getuid()
        let table = ctx.processes
        // Time between two scans far apart (sleep, App Nap) wasn't watched: connections then went unseen.
        memory.withLock { state in
            if ObservationWindow.isGap(since: state.lastScan, now: ctx.now) { state.watches = [:] }
            state.lastScan = max(state.lastScan ?? ctx.now, ctx.now)
        }

        var childRecords: [Int32: [ProcessInfoRecord]] = [:]
        for p in table.values where p.pid != p.ppid { childRecords[p.ppid, default: []].append(p) }
        func subtree(of root: Int32) -> Set<Int32> {
            var found: Set<Int32> = [root]
            var queue = [root]
            while let pid = queue.popLast() {
                for child in childRecords[pid] ?? [] where found.insert(child.pid).inserted { queue.append(child.pid) }
            }
            return found
        }
        let ownDescendants = subtree(of: ctx.ownPID)
        var ownAncestors: Set<Int32> = []
        var cursor = table[ctx.ownPID]?.ppid
        while let pid = cursor, pid > 1, ownAncestors.insert(pid).inserted { cursor = table[pid]?.ppid }

        var listening: [Int32: Set<Int>] = [:]
        for s in ctx.sockets where s.state == .listen { listening[s.pid, default: []].insert(s.localPort) }

        // Group candidate listeners by tree root.
        var groups: [Int32: Group] = [:]
        for pid in listening.keys.sorted() {
            guard let p = table[pid], !ownDescendants.contains(pid), !ownAncestors.contains(pid),
                  Self.isCandidate(p, ownUID: ownUID, home: home) else { continue }
            let root = Self.treeRoot(of: p, table: table, ownAncestors: ownAncestors)
            // A server started by a GUI app (MCP / language server of Claude, Cursor, VS Code, Raycast…) is that app's.
            guard !Self.isLaunchedByApp(root, table: table) else { continue }
            groups[root.pid, default: Group(root: root)].listeners.append(p)
        }

        var built: [Item] = []
        for group in groups.values {
            let pids = subtree(of: group.root.pid)
            // Never list or stop a tree CleanUp itself lives in.
            guard !pids.contains(ctx.ownPID) else { continue }
            let members = Self.members(from: group.root, children: childRecords, uid: ownUID).sorted { $0.pid < $1.pid }
            guard !members.isEmpty else { continue }
            let memberPIDs = Set(members.map(\.pid))

            // The youngest listener is the conservative choice for age.
            let primary = group.listeners.min { ($1.startTime, $0.pid) < ($0.startTime, $1.pid) }!
            let ports = Set(group.listeners.flatMap { listening[$0.pid] ?? [] }).sorted()
            let established = Self.establishedCount(ports: ports, pids: memberPIDs, sockets: ctx.sockets)

            let command = Self.shortCommand(primary)
            let name = Self.displayName(command: command, ports: ports)
            let cwd = primary.cwd ?? (primary.path as NSString).deletingLastPathComponent
            let identity = ItemIdentity.devServer(cwd: cwd, command: name)

            let cpuValues = members.map { ctx.cpu[$0.pid] }
            let cpu = cpuValues.contains { $0 == nil } ? Double.nan : cpuValues.reduce(0.0) { $0 + ($1 ?? 0) }

            let watch = remember(identity, startTime: primary.startTime, now: ctx.now, connected: established > 0)
            let facts = DevServerFacts(
                ref: primary.ref, command: command, projectName: projectName(for: primary), cwd: cwd, ports: ports,
                establishedNow: established, lastConnectionSeen: watch.lastConnection,
                cpuPercent: cpu, orphaned: Self.isOrphaned(group.root, table: table),
                observedFor: ctx.now.timeIntervalSince(watch.firstSeen)
            )
            let fullCommand = primary.arguments.isEmpty ? primary.path : primary.arguments.joined(separator: " ")
            let item = Item(
                id: identity,
                category: .devServers,
                name: name,
                symbol: "server.rack",
                judgement: DevServerJudge.judge(facts, now: ctx.now),
                cores: cpu.isNaN ? 0 : cpu / 100,
                memoryBytes: members.reduce(0) { $0 + $1.residentBytes },
                processes: members.map(\.ref),
                detail: [
                    "command": fullCommand,
                    "project": facts.projectName,
                    "cwd": cwd,
                    "path": primary.path,
                    "ports": ports.map(String.init).joined(separator: ","),
                ]
            )
            built.append(item)
        }

        // Forget servers that are gone: coming back starts a fresh watching period.
        let alive = Set(built.map(\.id))
        memory.withLock { state in state.watches = state.watches.filter { alive.contains($0.key) } }

        return built.sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
    }

    /// Updates and returns what we know about this server. A different start time means a restarted
    /// process: the old observations don't carry over.
    private func remember(_ identity: ItemIdentity, startTime: Date, now: Date, connected: Bool) -> Watch {
        memory.withLock { state in
            var watch = state.watches[identity]
            if watch == nil || watch?.startTime != startTime {
                watch = Watch(startTime: startTime, firstSeen: now, lastConnection: nil)
            }
            if connected { watch?.lastConnection = now }
            state.watches[identity] = watch
            return watch!
        }
    }

    /// Highest ancestor reachable through launcher processes (node, npm, npx, yarn, pnpm, bun). Shells,
    /// `launchd`, terminals, coding agents, other users' processes and CleanUp's own lineage never join.
    static func treeRoot(of listener: ProcessInfoRecord, table: [Int32: ProcessInfoRecord], ownAncestors: Set<Int32>) -> ProcessInfoRecord {
        var root = listener
        var visited: Set<Int32> = [listener.pid]
        while let parent = table[root.ppid], parent.pid > 1, visited.insert(parent.pid).inserted,
              parent.uid == listener.uid,
              lowercasedNames(parent).contains(where: launcherNames.contains),
              !isShellOrTerminal(parent), !isAgent(parent), !parent.path.contains(".app/"),
              !ProcessSignaler.isProtected(path: parent.path, name: parent.name),
              !ownAncestors.contains(parent.pid) {
            root = parent
        }
        return root
    }

    /// The first ancestor above the launcher chain owns the server when it is a GUI app's process.
    /// Shells, terminal apps, `launchd` and a missing parent are fine: a terminal's integrated shell
    /// has `.app` ancestors above the shell, and orphans stay allowed.
    static func isLaunchedByApp(_ root: ProcessInfoRecord, table: [Int32: ProcessInfoRecord]) -> Bool {
        guard let parent = table[root.ppid], parent.pid > 1 else { return false }
        if isShellOrTerminal(parent) { return false }
        return parent.path.contains(".app/")
    }

    /// The processes of a server's tree that CleanUp may list and signal: our own user's, not protected.
    /// Shells, terminals and coding agents are dropped together with everything below them.
    static func members(from root: ProcessInfoRecord, children: [Int32: [ProcessInfoRecord]], uid: uid_t) -> [ProcessInfoRecord] {
        var result: [ProcessInfoRecord] = []
        var seen: Set<Int32> = [root.pid]
        var queue = [root]
        while let current = queue.popLast() {
            if isShellOrTerminal(current) || isAgent(current) { continue }
            if current.uid == uid, !ProcessSignaler.isProtected(path: current.path, name: current.name) { result.append(current) }
            for child in children[current.pid] ?? [] where seen.insert(child.pid).inserted { queue.append(child) }
        }
        return result
    }

    private static func isOrphaned(_ root: ProcessInfoRecord, table: [Int32: ProcessInfoRecord]) -> Bool {
        root.ppid <= 1 || table[root.ppid] == nil
    }

    /// Connections to the server's ports from anywhere on this Mac. The server-side sockets are the
    /// primary source; client-side sockets of other processes cover servers whose sockets we can't read.
    /// Connections between processes of the tree itself (a wrapper talking to its child) don't count.
    private static func establishedCount(ports: [Int], pids: Set<Int32>, sockets: [SocketInfo]) -> Int {
        let portSet = Set(ports)
        var serverSide = 0, internalClients = 0, externalClients = 0
        for s in sockets where s.state == .established {
            if pids.contains(s.pid) {
                if portSet.contains(s.localPort) { serverSide += 1 }
                else if let remote = s.remotePort, portSet.contains(remote) { internalClients += 1 }
            } else if let remote = s.remotePort, portSet.contains(remote) {
                externalClients += 1
            }
        }
        return max(serverSide - internalClients, externalClients)
    }

    // MARK: stop / undo

    /// SIGTERM the tree (and any child spawned since the scan), SIGKILL survivors after the grace period.
    /// Every signal goes through `ProcessSignaler`, which re-verifies pid + start time each time.
    public func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult {
        guard force || item.judgement.verdict == .idle else { return .skipped(reason: "\(item.name) is in use") }

        let listed = item.processes.filter { ctx.processes[$0.pid]?.startTime == $0.startTime }
        guard !listed.isEmpty else { return .skipped(reason: "already gone") }

        let ports = Set((item.detail["ports"] ?? "").split(separator: ",").compactMap { Int($0) })
        let pids = Set(listed.map(\.pid))

        // Children spawned after the scan belong to the same tree, except shells, terminals and agents.
        var children: [Int32: [ProcessInfoRecord]] = [:]
        for p in ctx.processes.values where p.pid != p.ppid { children[p.ppid, default: []].append(p) }
        var refs = listed
        var known = pids
        for pid in listed.map(\.pid) {
            guard let record = ctx.processes[pid] else { continue }
            for member in Self.members(from: record, children: children, uid: getuid()) where known.insert(member.pid).inserted {
                refs.append(member.ref)
            }
        }

        // Something may have connected since the item was scanned: the server's side of a connection
        // on one of its ports, or a client's side (another process, remote port = one of its ports).
        if !force, ctx.sockets.contains(where: { socket in
            guard socket.state == .established else { return false }
            if known.contains(socket.pid) { return ports.contains(socket.localPort) }
            return socket.remotePort.map(ports.contains) ?? false
        }) {
            return .skipped(reason: "a connection arrived")
        }

        // CleanUp must never signal itself or the processes that launched it.
        var lineage: Set<Int32> = [ctx.ownPID]
        var cursor = ctx.processes[ctx.ownPID]?.ppid
        while let pid = cursor, pid > 1, lineage.insert(pid).inserted { cursor = ctx.processes[pid]?.ppid }
        if refs.contains(where: { lineage.contains($0.pid) }) { return .skipped(reason: "CleanUp is running inside this server") }

        let first = ProcessSignaler.terminate(refs, signal: SIGTERM)
        guard !first.signalled.isEmpty || !first.refused.isEmpty else { return .skipped(reason: "already gone") }

        let survivors = await waitForExit(of: refs.filter { first.signalled.contains($0.pid) })
        var refused = first.refused.count
        if !survivors.isEmpty {
            let second = ProcessSignaler.terminate(survivors, signal: SIGKILL)
            refused += second.refused.count
        }
        if refused > 0 { return .failed(reason: "Couldn't stop \(refused) process(es) of \(item.name)") }
        return .stopped(nil)   // a dev server has to be started again from its terminal; nothing to undo
    }

    /// Polls until every ref is gone or the grace period ends; returns the ones still alive.
    private func waitForExit(of refs: [ProcessRef]) async -> [ProcessRef] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: termGrace)
        var remaining = refs
        while true {
            let table = ProcessTable.snapshot()
            remaining = remaining.filter { table[$0.pid]?.startTime == $0.startTime }
            if remaining.isEmpty || clock.now >= deadline { return remaining }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    public func undo(_ token: UndoToken) async -> Bool { false }
}
