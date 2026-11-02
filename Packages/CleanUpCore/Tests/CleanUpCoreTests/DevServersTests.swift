import Darwin
import Foundation
import Testing
@testable import CleanUpCore

// MARK: - Judge

@Test func eighteenDayExpoIsIdle() {
    let j = DevServerJudge.judge(.fixture(age: .days(18), established: 0, cpu: 0.1), now: now)
    #expect(j.verdict == .idle)
    #expect(j.fact == "running 18 days")
}

@Test func freshServerIsInUse() {
    let j = DevServerJudge.judge(.fixture(age: .minutes(11), established: 0, cpu: 0.2), now: now)
    #expect(j.verdict == .inUse)
    #expect(j.fact == "started 11 min ago")
}

@Test func orphanedButConnectedIsInUse() {
    let j = DevServerJudge.judge(.fixture(age: .days(2), established: 1, cpu: 0, orphaned: true), now: now)
    #expect(j.verdict == .inUse)
    #expect(j.fact == "1 connection")
}

@Test func severalConnectionsArePluralised() {
    #expect(DevServerJudge.judge(.fixture(established: 3), now: now).fact == "3 connections")
}

@Test func recentConnectionKeepsInUse() {
    let j = DevServerJudge.judge(.fixture(age: .days(2), established: 0, cpu: 0, lastSeenAgo: .minutes(5)), now: now)
    #expect(j.verdict == .inUse)
    #expect(j.fact == "connection 5 min ago")
}

@Test func connectionExactlyThirtyMinutesAgoIsIdle() {
    #expect(DevServerJudge.judge(.fixture(lastSeenAgo: .minutes(30)), now: now).verdict == .idle)
    #expect(DevServerJudge.judge(.fixture(lastSeenAgo: .minutes(29)), now: now).verdict == .inUse)
}

@Test func ageBoundaryIsSixHours() {
    #expect(DevServerJudge.judge(.fixture(age: .hours(6)), now: now).verdict == .idle)
    #expect(DevServerJudge.judge(.fixture(age: .hours(6) - 1), now: now).verdict == .inUse)
}

@Test func cpuBoundaryIsTwoPercent() {
    #expect(DevServerJudge.judge(.fixture(cpu: 1.9), now: now).verdict == .idle)
    #expect(DevServerJudge.judge(.fixture(cpu: 2.0), now: now).verdict == .inUse)
}

@Test func unmeasuredCPUIsInUse() {
    let j = DevServerJudge.judge(.fixture(cpu: .nan), now: now)
    #expect(j.verdict == .inUse)
    #expect(j.fact == "measuring CPU")
}

@Test func unobservedServerIsInUseUntilWatchedForThirtyMinutes() {
    let young = DevServerJudge.judge(.fixture(observedFor: .minutes(29)), now: now)
    #expect(young.verdict == .inUse)
    #expect(young.fact == "watching for 30 min")
    #expect(DevServerJudge.judge(.fixture(observedFor: .minutes(30)), now: now).verdict == .idle)
}

@Test func orphanedOnlyAddsANeutralSignal() {
    let plain = DevServerJudge.judge(.fixture(orphaned: false), now: now)
    let orphan = DevServerJudge.judge(.fixture(orphaned: true), now: now)
    #expect(orphan.verdict == .idle)
    #expect(orphan.signals.contains(Signal(kind: .neutral, text: "no terminal attached")))
    #expect(!plain.signals.contains { $0.text == "no terminal attached" })
    #expect(orphan.signals.filter { $0.kind != .neutral } == plain.signals.filter { $0.kind != .neutral })
}

@Test func idleVerdictHasNoInUseSignals() {
    let j = DevServerJudge.judge(.fixture(), now: now)
    #expect(j.verdict == .idle)
    #expect(!j.signals.contains { $0.kind == .inUse })
}

// MARK: - Candidates

private let home = "/Users/u"

@Test func appBundleProcessesAreNotCandidates() {
    #expect(!DevServersModule.isCandidate(.fixture(path: "/Applications/Raycast.app/Contents/MacOS/Raycast Backend"), ownUID: 501))
    #expect(DevServersModule.isCandidate(.fixture(uid: 501, path: "/Users/u/.nvm/versions/node/v22/bin/node"), ownUID: 501))
    #expect(!DevServersModule.isCandidate(.fixture(path: "/usr/libexec/rapportd"), ownUID: 501))
}

@Test func realIncidentProcessesAreCandidates() {
    func candidate(_ p: ProcessInfoRecord) -> Bool { DevServersModule.isCandidate(p, ownUID: getuid(), home: home) }
    // node with a rewritten title, binary under ~/.nvm
    #expect(candidate(.fixture(name: "next-server (v16.2.10)", path: "/Users/u/.nvm/versions/node/v22.1.0/bin/node")))
    // script in a scratchpad
    #expect(candidate(.fixture(name: "node", path: "/opt/homebrew/bin/node", arguments: ["node", "/private/tmp/x/cors-proxy.mjs"])))
    // Go binary under home, name not in the runtime list
    #expect(candidate(.fixture(name: "api", path: "/Users/u/Projects/evone/services/api-go/bin/api")))
    #expect(candidate(.fixture(name: "server", path: "/private/tmp/scratch/server")))
    #expect(candidate(.fixture(name: "server", path: "/private/var/folders/ab/T/server")))
    #expect(candidate(.fixture(name: "python3.12", path: "/opt/homebrew/bin/python3.12")))
    #expect(candidate(.fixture(name: "Python", path: "/opt/homebrew/Cellar/python/Python")))
    #expect(candidate(.fixture(name: "node", path: "/usr/local/bin/node")))
}

@Test func realIncidentNonCandidatesThatListen() {
    func candidate(_ p: ProcessInfoRecord) -> Bool { DevServersModule.isCandidate(p, ownUID: getuid(), home: home) }
    #expect(!candidate(.fixture(name: "Raycast Backend", path: "/Applications/Raycast.app/Contents/MacOS/Raycast Backend")))
    #expect(!candidate(.fixture(name: "Spotify", path: "/Users/u/Applications/Spotify.app/Contents/MacOS/Spotify")))
    #expect(!candidate(.fixture(name: "ControlCenter", path: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter")))
    #expect(!candidate(.fixture(name: "rapportd", path: "/usr/libexec/rapportd")))
    #expect(!candidate(.fixture(name: "com.docker.backend", path: "/Applications/Docker.app/Contents/MacOS/com.docker.backend")))
    // Not a runtime and not under home / scratch space.
    #expect(!candidate(.fixture(name: "postgres", path: "/opt/homebrew/opt/postgresql@16/bin/postgres")))
    // A runtime living in a protected location is still protected.
    #expect(!candidate(.fixture(name: "python3", path: "/usr/bin/python3")))
    #expect(!candidate(.fixture(name: "ruby", path: "/System/Library/Frameworks/Ruby.framework/Versions/2.6/usr/bin/ruby")))
}

@Test func otherUsersAndRootAreNotCandidates() {
    #expect(!DevServersModule.isCandidate(.fixture(uid: 0, name: "node", path: "/Users/u/.nvm/bin/node"), ownUID: getuid(), home: home))
    #expect(!DevServersModule.isCandidate(.fixture(uid: getuid() + 1, name: "node", path: "/Users/u/.nvm/bin/node"), ownUID: getuid(), home: home))
    #expect(!DevServersModule.isCandidate(.fixture(uid: 0, name: "node", path: "/Users/u/.nvm/bin/node"), ownUID: 0, home: home))
}

@Test func agentsAndShellsAreNotCandidates() {
    func candidate(_ p: ProcessInfoRecord) -> Bool { DevServersModule.isCandidate(p, ownUID: getuid(), home: home) }
    #expect(!candidate(.fixture(name: "claude", path: "/Users/u/.local/bin/claude")))
    #expect(!candidate(.fixture(name: "node", path: "/Users/u/.nvm/bin/node",
                                arguments: ["node", "/Users/u/.nvm/lib/node_modules/@anthropic-ai/claude-code/cli.js"])))
    #expect(!candidate(.fixture(name: "zsh", path: "/Users/u/bin/zsh")))
    // Codex runs as node too.
    #expect(!candidate(.fixture(name: "node", path: "/Users/u/.nvm/bin/node",
                                arguments: ["node", "/Users/u/.nvm/lib/node_modules/@openai/codex/bin/codex.js"])))
    #expect(!candidate(.fixture(name: "node", path: "/Users/u/.nvm/bin/node", arguments: ["node", "/opt/codex/codex.js", "--full-auto"])))
}

// MARK: - Display and project names

@Test func shortCommandNames() {
    func short(_ p: ProcessInfoRecord) -> String { DevServersModule.shortCommand(p) }
    #expect(short(.fixture(name: "node", arguments: ["node", "/Users/u/Projects/evone/node_modules/.bin/expo", "start", "--dev-client", "--clear"])) == "expo start")
    #expect(short(.fixture(name: "node", arguments: ["node", "/p/node_modules/.bin/next", "dev", "-p", "3001"])) == "next dev")
    #expect(short(.fixture(name: "next-server (v16.2.10)", arguments: ["next-server (v16.2.10)"])) == "next-server")
    #expect(short(.fixture(name: "node", arguments: ["node", "/private/tmp/x/cors-proxy.mjs"])) == "cors-proxy.mjs")
    #expect(short(.fixture(name: "api", arguments: ["/Users/u/Projects/evone/services/api-go/bin/api"])) == "api")
    #expect(short(.fixture(name: "python3", arguments: ["python3", "-m", "http.server", "8000"])) == "http.server")
    #expect(short(.fixture(name: "node", arguments: ["node", "--inspect", "server.js"])) == "server.js")
    #expect(short(.fixture(name: "node", arguments: ["node"])) == "node")
}

@Test func projectNameUsesGitRootAndSubpath() {
    let fs: Set<String> = ["/Users/u/Projects/evone/.git", "/Users/u/Projects/evone/apps/mobile/package.json"]
    func name(_ cwd: String?, exe: String = "/x/bin/api") -> String {
        DevServersModule.projectName(cwd: cwd, executable: exe, home: home, exists: { fs.contains($0) })
    }
    #expect(name("/Users/u/Projects/evone/apps/mobile") == "evone/apps/mobile")
    #expect(name("/Users/u/Projects/evone/apps/mobile/src/deep") == "evone/apps/mobile")
    #expect(name("/Users/u/Projects/evone/services/api-go") == "evone")
    #expect(name("/Users/u/Projects/evone") == "evone")
}

@Test func projectNamePackageOnlyAndFallbacks() {
    let fs: Set<String> = ["/Users/u/Projects/solo/package.json", "/Users/u/Projects/mono/.git", "/Users/u/Projects/mono/package.json",
                           "/Users/u/Projects/web/apps/landing/package.json", "/Users/u/Projects/web/.git",
                           "/Users/u/Projects/web/apps/landing/.next/standalone/package.json"]
    func name(_ cwd: String?, exe: String = "/Users/u/tools/bin/api") -> String {
        DevServersModule.projectName(cwd: cwd, executable: exe, home: home, exists: { fs.contains($0) })
    }
    #expect(name("/Users/u/Projects/solo/dist") == "solo")
    #expect(name("/Users/u/Projects/mono") == "mono")   // package.json next to .git is not a sub-path
    // A package.json that Next.js copies into .next/standalone is not the project.
    #expect(name("/Users/u/Projects/web/apps/landing/.next/standalone") == "web/apps/landing")
    #expect(name("/Users/u/scratch/thing") == "thing")  // no markers: the folder itself
    #expect(name(nil) == "bin")                         // no cwd: the executable's folder
    #expect(name(nil, exe: "") == "unknown project")
    #expect(name("/") == "bin")                         // "/" is no project either
}

@Test func projectNameStopsAtHome() {
    // Dotfile repo at home must not make every scratch folder "u".
    let fs: Set<String> = ["/Users/u/.git"]
    #expect(DevServersModule.projectName(cwd: "/Users/u/scratch/x", executable: "/x/y", home: home, exists: { fs.contains($0) }) == "x")
}

@Test func projectNameWorksOnRealFilesystem() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("devserver-\(UUID().uuidString)")
    let sub = root.appendingPathComponent("apps/web")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: sub.appendingPathComponent("package.json").path, contents: Data("{}".utf8))
    defer { try? FileManager.default.removeItem(at: root) }
    let resolved = root.resolvingSymlinksInPath()
    #expect(DevServersModule.projectName(cwd: sub.resolvingSymlinksInPath().path, executable: "/x", home: "/nonexistent")
            == "\(resolved.lastPathComponent)/apps/web")
}

// MARK: - Scan

private let evoneFS: Set<String> = ["/Users/u/Projects/evone/.git", "/Users/u/Projects/evone/apps/mobile/package.json",
                                    "/Users/u/Projects/evone-dm15-02/.git", "/Users/u/Projects/evone-dm15-02/apps/landing/package.json"]
private let nvmNode = "/Users/u/.nvm/versions/node/v22.1.0/bin/node"
private let mobileCwd = "/Users/u/Projects/evone/apps/mobile"

private func module(grace: Duration = .seconds(5)) -> DevServersModule {
    DevServersModule(termGrace: grace, home: home, fileExists: { evoneFS.contains($0) })
}

/// zsh -> node wrapper (86003) -> node expo (86037) listening on 8081, both 18 days old.
private func expoProcesses(wrapperParent: Int32 = 50) -> [ProcessInfoRecord] {
    [
        .fixture(pid: 50, ppid: 1, name: "zsh", path: "/bin/zsh", startedAgo: .days(30)),
        .fixture(pid: 86_003, ppid: wrapperParent, name: "node", path: nvmNode,
                 arguments: ["node", "../../scripts/mobile/with-root-env.mjs", "npx", "expo", "start", "--dev-client", "--clear"],
                 cwd: mobileCwd, startedAgo: .days(18)),
        .fixture(pid: 86_037, ppid: 86_003, name: "node", path: nvmNode,
                 arguments: ["node", "/Users/u/Projects/evone/node_modules/.bin/expo", "start", "--dev-client", "--clear"],
                 cwd: mobileCwd, startedAgo: .days(18)),
    ]
}

private func table(_ records: [ProcessInfoRecord]) -> [Int32: ProcessInfoRecord] {
    Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
}

private func context(
    _ records: [ProcessInfoRecord], at date: Date = fixedNow, sockets: [SocketInfo] = [], cpu: [Int32: Double]? = nil
) -> ScanContext {
    let cpuMap = cpu ?? Dictionary(uniqueKeysWithValues: records.map { ($0.pid, 0.0) })
    return .testContext(now: date, processes: table(records), cpu: cpuMap, sockets: sockets)
}

private let expoListen = SocketInfo(pid: 86_037, state: .listen, localPort: 8081, remotePort: nil)

/// Scans once a minute from `from` to `to` minutes after `fixedNow` (inclusive), as the refresh loop
/// does; returns the last scan.
private func scanEveryMinute(
    _ m: DevServersModule, _ records: [ProcessInfoRecord], from: Double = 0, to: Double,
    sockets: [SocketInfo] = [expoListen], cpu: [Int32: Double]? = nil
) async -> [Item] {
    var last: [Item] = []
    var minute = from
    while minute <= to {
        last = await m.scan(context(records, at: fixedNow + .minutes(minute), sockets: sockets, cpu: cpu))
        minute += 1
    }
    return last
}

@Test func scanGroupsExpoUnderItsWrapperAndShowsProject() async {
    let items = await module().scan(context(expoProcesses(), sockets: [expoListen]))
    #expect(items.count == 1)
    let item = items[0]
    #expect(item.category == .devServers)
    #expect(item.name == "expo start :8081")
    #expect(item.detail["project"] == "evone/apps/mobile")
    #expect(item.detail["cwd"] == mobileCwd)
    #expect(item.detail["command"] == "node /Users/u/Projects/evone/node_modules/.bin/expo start --dev-client --clear")
    #expect(item.id == .devServer(cwd: mobileCwd, command: "expo start :8081"))
    // The shell is never part of the tree.
    #expect(item.processes.map(\.pid) == [86_003, 86_037])
}

@Test func scanIsInUseUntilObservedForThirtyMinutes() async {
    let m = module()
    let procs = expoProcesses()
    let first = await m.scan(context(procs, sockets: [expoListen]))
    #expect(first[0].judgement.verdict == .inUse)
    #expect(first[0].judgement.fact == "watching for 30 min")

    let later = await scanEveryMinute(m, procs, from: 1, to: 29)
    #expect(later[0].judgement.verdict == .inUse)

    let idle = await m.scan(context(procs, at: fixedNow + .minutes(30), sockets: [expoListen]))
    #expect(idle[0].judgement.verdict == .idle)
    #expect(idle[0].judgement.fact == "running 18 days")
}

@Test func scanRemembersLastConnectionAndRestartsTheQuietPeriod() async {
    let m = module()
    let procs = expoProcesses()
    let client = SocketInfo(pid: 86_037, state: .established, localPort: 8081, remotePort: 52_000)
    _ = await scanEveryMinute(m, procs, to: 39)                                                    // t0 watching begins
    let connected = await m.scan(context(procs, at: fixedNow + .minutes(40), sockets: [expoListen, client]))
    #expect(connected[0].judgement.verdict == .inUse)
    #expect(connected[0].judgement.fact == "1 connection")
    let after10 = await scanEveryMinute(m, procs, from: 41, to: 50)
    #expect(after10[0].judgement.verdict == .inUse)
    #expect(after10[0].judgement.fact == "connection 10 min ago")
    let after30 = await scanEveryMinute(m, procs, from: 51, to: 70)
    #expect(after30[0].judgement.verdict == .idle)
}

@Test func scanCountsClientSideSocketsOfOtherProcesses() async {
    let m = module()
    let browser = SocketInfo(pid: 777, state: .established, localPort: 53_000, remotePort: 8081)
    let items = await m.scan(context(expoProcesses(), sockets: [expoListen, browser]))
    #expect(items[0].judgement.fact == "1 connection")
}

@Test func scanIgnoresConnectionsInsideTheTree() async {
    let m = module()
    // The wrapper talking to its own child is not a user.
    let server = SocketInfo(pid: 86_037, state: .established, localPort: 8081, remotePort: 53_000)
    let wrapperSide = SocketInfo(pid: 86_003, state: .established, localPort: 53_000, remotePort: 8081)
    let items = await scanEveryMinute(m, expoProcesses(), to: 31, sockets: [expoListen, server, wrapperSide])
    #expect(items[0].judgement.verdict == .idle)
}

@Test func scanIsInUseWhenCPUNotMeasuredYet() async {
    let m = module()
    let procs = expoProcesses()
    _ = await m.scan(context(procs, sockets: [expoListen], cpu: [:]))
    let items = await m.scan(context(procs, at: fixedNow + .minutes(31), sockets: [expoListen], cpu: [:]))
    #expect(items[0].judgement.verdict == .inUse)
}

@Test func scanTreatsTreeCPUAsBusy() async {
    let m = module()
    let procs = expoProcesses()
    _ = await m.scan(context(procs, sockets: [expoListen]))
    // The wrapper is compiling even though the listener is quiet.
    let items = await m.scan(context(procs, at: fixedNow + .minutes(31), sockets: [expoListen], cpu: [86_003: 40, 86_037: 0.1]))
    #expect(items[0].judgement.verdict == .inUse)
    #expect(abs(items[0].cores - 0.401) < 1e-9)
}

@Test func scanFlagsOrphanedTrees() async {
    let m = module()
    let items = await m.scan(context(Array(expoProcesses(wrapperParent: 1).dropFirst()), sockets: [expoListen]))
    #expect(items[0].judgement.signals.contains(Signal(kind: .neutral, text: "no terminal attached")))
    let attached = await module().scan(context(expoProcesses(), sockets: [expoListen]))
    #expect(!attached[0].judgement.signals.contains { $0.text == "no terminal attached" })
}

@Test func scanNeverClimbsPastShellsOrAgents() async {
    // claude (a node process) -> node dev server: the agent must not become the tree root.
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 60, ppid: 1, name: "node", path: nvmNode,
                 arguments: ["node", "/Users/u/.nvm/lib/node_modules/@anthropic-ai/claude-code/cli.js"], startedAgo: .days(2)),
        .fixture(pid: 61, ppid: 60, name: "node", path: nvmNode, arguments: ["node", "server.js"], cwd: mobileCwd, startedAgo: .days(2)),
    ]
    let listen = SocketInfo(pid: 61, state: .listen, localPort: 4000, remotePort: nil)
    let items = await module().scan(context(procs, sockets: [listen]))
    #expect(items.count == 1)
    #expect(items[0].processes.map(\.pid) == [61])
}

@Test func scanClimbsThroughPackageManagers() async {
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 50, ppid: 1, name: "zsh", path: "/bin/zsh"),
        .fixture(pid: 70, ppid: 50, name: "npm", path: nvmNode, arguments: ["npm", "run", "dev"], cwd: mobileCwd),
        .fixture(pid: 71, ppid: 70, name: "node", path: nvmNode, arguments: ["node", "/p/node_modules/.bin/vite"], cwd: mobileCwd),
    ]
    let listen = SocketInfo(pid: 71, state: .listen, localPort: 5173, remotePort: nil)
    let items = await module().scan(context(procs, sockets: [listen]))
    #expect(items[0].processes.map(\.pid) == [70, 71])
    #expect(items[0].name == "vite :5173")
}

@Test func scanKeepsSeparateServersSeparateAndNamesPorts() async {
    let cwd = "/Users/u/Projects/evone-dm15-02/apps/landing/.next/standalone"
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 90, ppid: 1, name: "next-server (v16.2.10)", path: nvmNode, arguments: ["next-server (v16.2.10)"], cwd: cwd, startedAgo: .days(5)),
        .fixture(pid: 91, ppid: 1, name: "next-server (v16.2.10)", path: nvmNode, arguments: ["next-server (v16.2.10)"], cwd: cwd, startedAgo: .days(5)),
    ]
    let sockets = [SocketInfo(pid: 90, state: .listen, localPort: 3917, remotePort: nil),
                   SocketInfo(pid: 91, state: .listen, localPort: 3918, remotePort: nil)]
    let items = await module().scan(context(procs, sockets: sockets))
    #expect(items.map(\.name) == ["next-server :3917", "next-server :3918"])
    #expect(Set(items.map(\.id)).count == 2)
    #expect(items.allSatisfy { $0.detail["project"] == "evone-dm15-02/apps/landing" })
}

@Test func scanSkipsNonCandidatesAndOthersProcessesAndOurOwn() async {
    let own = getpid()
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 200, name: "Raycast Backend", path: "/Applications/Raycast.app/Contents/MacOS/Raycast Backend"),
        .fixture(pid: 201, name: "rapportd", path: "/usr/libexec/rapportd"),
        .fixture(pid: 202, uid: 0, name: "node", path: nvmNode),
        .fixture(pid: own, name: "node", path: nvmNode),
        .fixture(pid: 203, ppid: own, name: "node", path: nvmNode),
        .fixture(pid: 204, name: "node", path: nvmNode),   // listens in no socket: not a server
    ]
    let sockets = [200, 201, 202, own, 203].map { SocketInfo(pid: $0, state: .listen, localPort: 9_000 + Int($0 % 100), remotePort: nil) }
    #expect(await module().scan(context(procs, sockets: sockets)).isEmpty)
}

@Test func scanLeavesOutProtectedOrForeignProcessesFromTheTree() async {
    // The tree's protected shell and a root-owned child are not listed (the signaler would refuse it).
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 70, ppid: 1, name: "node", path: nvmNode, arguments: ["node", "/x/npm-cli.js", "run", "dev"], cwd: mobileCwd),
        .fixture(pid: 71, ppid: 70, name: "sh", path: "/bin/sh", arguments: ["sh", "-c", "next dev"], cwd: mobileCwd),
        .fixture(pid: 72, ppid: 70, name: "node", path: nvmNode, arguments: ["node", "/p/node_modules/.bin/next", "dev", "-p", "3001"], cwd: mobileCwd),
        .fixture(pid: 73, ppid: 70, uid: 0, name: "node", path: nvmNode, arguments: ["node", "helper"], cwd: mobileCwd),
    ]
    let listen = SocketInfo(pid: 72, state: .listen, localPort: 3001, remotePort: nil)
    let items = await module().scan(context(procs, sockets: [listen]))
    #expect(items[0].processes.map(\.pid) == [70, 72])
    #expect(items[0].name == "next dev :3001")
}

@Test func aGapBetweenScansStartsTheWatchOver() async {
    // The Mac slept from minute 10 to 40: a connection then would have gone unseen.
    let m = module()
    let procs = expoProcesses()
    _ = await scanEveryMinute(m, procs, to: 10)
    let woke = await m.scan(context(procs, at: fixedNow + .minutes(40), sockets: [expoListen]))
    #expect(woke[0].judgement.verdict == .inUse)
    #expect(woke[0].judgement.fact == "watching for 30 min")
    #expect(await scanEveryMinute(m, procs, from: 41, to: 69)[0].judgement.verdict == .inUse)
    #expect(await m.scan(context(procs, at: fixedNow + .minutes(70), sockets: [expoListen]))[0].judgement.verdict == .idle)
}

@Test func restartObservationStartsTheWatchOver() async {
    let m = module()
    let procs = expoProcesses()
    #expect(await scanEveryMinute(m, procs, to: 30)[0].judgement.verdict == .idle)
    m.restartObservation()
    #expect(await m.scan(context(procs, at: fixedNow + .minutes(31), sockets: [expoListen]))[0].judgement.verdict == .inUse)
}

@Test func scanForgetsServersThatDisappear() async {
    let m = module()
    let procs = expoProcesses()
    _ = await m.scan(context(procs, sockets: [expoListen]))
    #expect(await m.scan(context(procs, at: fixedNow + .minutes(20))).isEmpty)
    // Back after a gap: the watching period starts over.
    let again = await m.scan(context(procs, at: fixedNow + .minutes(45), sockets: [expoListen]))
    #expect(again[0].judgement.verdict == .inUse)
}

@Test func scanRestartsObservationWhenTheProcessIsReplaced() async {
    let m = module()
    _ = await m.scan(context(expoProcesses(), sockets: [expoListen]))
    var restarted = expoProcesses()
    restarted[2] = .fixture(pid: 86_037, ppid: 86_003, name: "node", path: nvmNode,
                            arguments: restarted[2].arguments, cwd: mobileCwd, startedAgo: .days(17))
    let items = await m.scan(context(restarted, at: fixedNow + .minutes(40), sockets: [expoListen]))
    #expect(items[0].judgement.verdict == .inUse)
    #expect(items[0].judgement.fact == "watching for 30 min")
}

// MARK: - Servers owned by GUI apps

private func listen(_ pid: Int32, _ port: Int = 4000) -> SocketInfo { SocketInfo(pid: pid, state: .listen, localPort: port, remotePort: nil) }

private func appProcess(_ pid: Int32, ppid: Int32 = 1, name: String, path: String) -> ProcessInfoRecord {
    .fixture(pid: pid, ppid: ppid, name: name, path: path, startedAgo: .days(3))
}

@Test func nodeSpawnedByAGUIAppIsNotListed() async {
    let claude = [
        appProcess(300, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude"),
        .fixture(pid: 301, ppid: 300, name: "node", path: nvmNode, arguments: ["node", "mcp-server.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    #expect(await module().scan(context(claude, sockets: [listen(301)])).isEmpty)

    let cursor = [
        appProcess(330, name: "Cursor Helper (Plugin)", path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
        .fixture(pid: 331, ppid: 330, name: "node", path: nvmNode, arguments: ["node", "language-server.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    #expect(await module().scan(context(cursor, sockets: [listen(331)])).isEmpty)
}

@Test func launcherChainBelowAGUIAppIsNotListed() async {
    // The first ancestor above npm -> node is the app helper.
    let procs = [
        appProcess(330, name: "Raycast Helper", path: "/Applications/Raycast.app/Contents/Frameworks/Raycast Helper.app/Contents/MacOS/Raycast Helper"),
        .fixture(pid: 331, ppid: 330, name: "npm", path: nvmNode, arguments: ["npm", "run", "serve"], cwd: mobileCwd, startedAgo: .days(3)),
        .fixture(pid: 332, ppid: 331, name: "node", path: nvmNode, arguments: ["node", "serve.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    #expect(await module().scan(context(procs, sockets: [listen(332)])).isEmpty)
}

@Test func terminalAppsAndIntegratedTerminalsStayCandidates() async {
    // Terminal.app -> zsh -> node
    let terminal = [
        appProcess(310, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
        .fixture(pid: 311, ppid: 310, name: "zsh", path: "/bin/zsh", startedAgo: .days(3)),
        .fixture(pid: 312, ppid: 311, name: "node", path: nvmNode, arguments: ["node", "server.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    #expect(await module().scan(context(terminal, sockets: [listen(312)])).count == 1)

    // VS Code -> zsh -> npm -> node: the app sits above the shell, so the server is still the user's.
    let code = [
        appProcess(320, name: "Electron", path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron"),
        .fixture(pid: 321, ppid: 320, name: "zsh", path: "/bin/zsh", startedAgo: .days(3)),
        .fixture(pid: 322, ppid: 321, name: "npm", path: nvmNode, arguments: ["npm", "run", "dev"], cwd: mobileCwd, startedAgo: .days(3)),
        .fixture(pid: 323, ppid: 322, name: "node", path: nvmNode, arguments: ["node", "server.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    let items = await module().scan(context(code, sockets: [listen(323)]))
    #expect(items.count == 1)
    #expect(items[0].processes.map(\.pid) == [322, 323])

    // A terminal app that is the direct parent is fine too.
    let direct = [
        appProcess(340, name: "iTerm2", path: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
        .fixture(pid: 341, ppid: 340, name: "node", path: nvmNode, arguments: ["node", "server.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    #expect(await module().scan(context(direct, sockets: [listen(341)])).count == 1)
}

@Test func nodeInsideAnAppBundleIsNeverUsedAsTreeRoot() async {
    let procs = [
        appProcess(350, name: "node", path: "/Applications/Foo.app/Contents/Resources/node"),
        .fixture(pid: 351, ppid: 350, name: "node", path: nvmNode, arguments: ["node", "server.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    #expect(DevServersModule.treeRoot(of: procs[1], table: table(procs), ownAncestors: []).pid == 351)
    #expect(await module().scan(context(procs, sockets: [listen(351)])).isEmpty)
}

@Test func orphanedServersStayCandidates() async {
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 360, ppid: 99_999, name: "node", path: nvmNode, arguments: ["node", "server.js"], cwd: mobileCwd, startedAgo: .days(3)),
        .fixture(pid: 361, ppid: 1, name: "node", path: nvmNode, arguments: ["node", "other.js"], cwd: mobileCwd, startedAgo: .days(3)),
    ]
    #expect(await module().scan(context(procs, sockets: [listen(360, 4000), listen(361, 4001)])).count == 2)
}

// MARK: - Shells and agents inside the tree

@Test func scanDropsShellsAndAgentsWithTheirSubtrees() async {
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 70, ppid: 1, name: "npm", path: nvmNode, arguments: ["npm", "run", "dev"], cwd: mobileCwd),
        .fixture(pid: 71, ppid: 70, name: "zsh", path: "/opt/homebrew/bin/zsh", cwd: mobileCwd),
        .fixture(pid: 72, ppid: 71, name: "node", path: nvmNode, arguments: ["node", "under-a-shell.js"], cwd: mobileCwd),
        .fixture(pid: 73, ppid: 70, name: "node", path: nvmNode,
                 arguments: ["node", "/Users/u/.nvm/lib/node_modules/@anthropic-ai/claude-code/cli.js"], cwd: mobileCwd),
        .fixture(pid: 74, ppid: 70, name: "node", path: nvmNode, arguments: ["node", "/p/node_modules/.bin/vite"], cwd: mobileCwd),
        .fixture(pid: 75, ppid: 73, name: "node", path: nvmNode, arguments: ["node", "agent-child.js"], cwd: mobileCwd),
    ]
    let items = await module().scan(context(procs, sockets: [listen(74, 5173)]))
    #expect(items.count == 1)
    #expect(items[0].processes.map(\.pid) == [70, 74])
}

@Test func agentConnectionsToTheServerStillCountAsUse() async {
    // An agent below the server's root curling the server is a real client.
    let procs: [ProcessInfoRecord] = [
        .fixture(pid: 70, ppid: 1, name: "npm", path: nvmNode, arguments: ["npm", "run", "dev"], cwd: mobileCwd),
        .fixture(pid: 74, ppid: 70, name: "node", path: nvmNode, arguments: ["node", "/p/node_modules/.bin/vite"], cwd: mobileCwd),
        .fixture(pid: 73, ppid: 70, name: "claude", path: "/Users/u/.local/bin/claude"),
    ]
    let client = SocketInfo(pid: 73, state: .established, localPort: 52_000, remotePort: 5173)
    let items = await module().scan(context(procs, sockets: [listen(74, 5173), client]))
    #expect(items[0].judgement.fact == "1 connection")
}

@Test func stopLeavesShellChildrenAddedSinceTheScanAlone() async throws {
    let parent = try spawnSleeper()
    defer { parent.dispose() }
    let shell = try spawnSleeper(parent: parent.record.pid, named: "zsh")
    defer { shell.dispose() }
    let item = Item.fixtureDevServer(ref: parent.record.ref)
    let ctx = ScanContext.testContext(processes: ProcessTable.snapshot().merging([shell.record.pid: shell.record]) { _, new in new })
    #expect(await module().stop(item, ctx: ctx) == .stopped(nil))
    parent.process.waitUntilExit()
    #expect(!parent.process.isRunning)
    #expect(shell.process.isRunning)
}

// MARK: - Stop

@Test func stopSkipsReusedPID() async {
    let item = Item.fixtureDevServer(ref: ProcessRef(pid: 4242, startTime: .distantPast))
    let r = await DevServersModule().stop(item, ctx: .testContext(processes: [4242: .fixture(pid: 4242, start: .now)]))
    #expect(r == .skipped(reason: "already gone"))
}

@Test func stopSkipsMissingProcess() async {
    let item = Item.fixtureDevServer(ref: ProcessRef(pid: 4242, startTime: now))
    #expect(await DevServersModule().stop(item, ctx: .testContext()) == .skipped(reason: "already gone"))
}

@Test func stopRefusesItemsThatAreInUse() async throws {
    let child = try spawnSleeper()
    defer { child.dispose() }
    let item = Item.fixtureDevServer(ref: child.record.ref, verdict: .inUse)
    guard case .skipped = await module().stop(item, ctx: .testContext(processes: [child.record.pid: child.record])) else {
        Issue.record("expected skipped"); return
    }
    #expect(child.process.isRunning)
}

@Test func stopSkipsWhenAClientConnectedSinceTheScan() async throws {
    let child = try spawnSleeper()
    defer { child.dispose() }
    let item = Item.fixtureDevServer(ref: child.record.ref)
    let sockets = [SocketInfo(pid: child.record.pid, state: .established, localPort: 8081, remotePort: 55_000)]
    let r = await module().stop(item, ctx: .testContext(processes: [child.record.pid: child.record], sockets: sockets))
    #expect(r == .skipped(reason: "a connection arrived"))
    #expect(child.process.isRunning)
}

@Test func stopSkipsWhenAnotherProcessConnectedSinceTheScan() async throws {
    // Only the client's side of the connection is visible (say, the server's sockets can't be read).
    let child = try spawnSleeper()
    defer { child.dispose() }
    let item = Item.fixtureDevServer(ref: child.record.ref)
    let sockets = [SocketInfo(pid: 777, state: .established, localPort: 55_000, remotePort: 8081)]
    let r = await module().stop(item, ctx: .testContext(processes: [child.record.pid: child.record], sockets: sockets))
    #expect(r == .skipped(reason: "a connection arrived"))
    #expect(child.process.isRunning)
}

@Test func forcedStopOfInUseServerTerminatesItEvenWithAClient() async throws {
    let child = try spawnSleeper()
    defer { child.dispose() }
    let item = Item.fixtureDevServer(ref: child.record.ref, verdict: .inUse)
    let sockets = [SocketInfo(pid: child.record.pid, state: .established, localPort: 8081, remotePort: 55_000)]
    let r = await module().stop(item, ctx: .testContext(processes: ProcessTable.snapshot(), sockets: sockets), force: true)
    #expect(r == .stopped(nil))
    child.process.waitUntilExit()
    #expect(!child.process.isRunning)
}

@Test func forcedStopStillLeavesAReusedPIDAlone() async throws {
    let child = try spawnSleeper()
    defer { child.dispose() }
    let stale = ProcessRef(pid: child.record.pid, startTime: child.record.startTime.addingTimeInterval(-100))
    let item = Item.fixtureDevServer(ref: stale, verdict: .inUse)
    let r = await module().stop(item, ctx: .testContext(processes: ProcessTable.snapshot()), force: true)
    #expect(r == .skipped(reason: "already gone"))
    #expect(child.process.isRunning)
}

@Test func forcedStopStillRefusesTreesContainingCleanUp() async {
    let own = ProcessTable.snapshot()[getpid()]!
    let item = Item.fixtureDevServer(ref: own.ref, verdict: .inUse)
    guard case .skipped = await module().stop(item, ctx: .testContext(processes: [own.pid: own]), force: true) else {
        Issue.record("expected skipped"); return
    }
}

@Test func stopRefusesTreesContainingCleanUp() async {
    let own = ProcessTable.snapshot()[getpid()]!
    let item = Item.fixtureDevServer(ref: own.ref)
    guard case .skipped = await module().stop(item, ctx: .testContext(processes: [own.pid: own])) else {
        Issue.record("expected skipped"); return
    }
}

@Test func stopTerminatesTheWholeTreeThroughTheSignaler() async throws {
    let child = try spawnSleeper()
    defer { child.dispose() }
    let item = Item.fixtureDevServer(ref: child.record.ref)
    let result = await module(grace: .seconds(5)).stop(item, ctx: .testContext(processes: ProcessTable.snapshot()))
    #expect(result == .stopped(nil))
    child.process.waitUntilExit()
    #expect(child.process.terminationReason == .uncaughtSignal)
    #expect(child.process.terminationStatus == SIGTERM)
}

@Test func stopLeavesAReusedPIDAlone() async throws {
    let child = try spawnSleeper()
    defer { child.dispose() }
    let stale = ProcessRef(pid: child.record.pid, startTime: child.record.startTime.addingTimeInterval(-100))
    let r = await module().stop(Item.fixtureDevServer(ref: stale), ctx: .testContext(processes: ProcessTable.snapshot()))
    #expect(r == .skipped(reason: "already gone"))
    #expect(child.process.isRunning)
}

@Test func stopEscalatesToSIGKILLForProcessesThatIgnoreSIGTERM() async throws {
    let stubborn = try spawnStubborn()
    defer { stubborn.dispose() }
    let item = Item.fixtureDevServer(ref: stubborn.record.ref)
    let clock = ContinuousClock()
    let started = clock.now
    let result = await module(grace: .milliseconds(400)).stop(item, ctx: .testContext(processes: ProcessTable.snapshot()))
    #expect(result == .stopped(nil))
    #expect(clock.now - started >= .milliseconds(400))
    stubborn.process.waitUntilExit()
    #expect(stubborn.process.terminationStatus == SIGKILL)
}

@Test func stopAlsoTerminatesChildrenSpawnedAfterTheScan() async throws {
    let parent = try spawnSleeper()
    defer { parent.dispose() }
    // A child of the item's process that the item doesn't list yet.
    let kid = try spawnSleeper(parent: parent.record.pid)
    defer { kid.dispose() }
    let item = Item.fixtureDevServer(ref: parent.record.ref)
    let ctx = ScanContext.testContext(processes: ProcessTable.snapshot().merging([kid.record.pid: kid.record]) { _, new in new })
    _ = await module().stop(item, ctx: ctx)
    kid.process.waitUntilExit()
    #expect(!kid.process.isRunning)
}

@Test func undoIsNotSupported() async {
    #expect(await DevServersModule().undo(UndoToken(identity: .devServer(cwd: "/x", command: "y"), action: "start", arguments: [])) == false)
}

// MARK: - Throwaway processes (copies of system binaries, so nothing real is ever signalled)

private struct Spawned {
    let process: Process
    let record: ProcessInfoRecord

    /// Kills the throwaway (it may ignore SIGTERM) and removes its temp directory.
    func dispose() {
        if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: record.path).deletingLastPathComponent())
    }
}

private func spawnSleeper(parent: Int32? = nil, named name: String = "fake-dev-server") throws -> Spawned {
    let copy = try throwawayCopy(of: "/bin/sleep", named: name)
    let process = Process()
    process.executableURL = copy
    process.arguments = ["120"]
    try process.run()
    return try Spawned(process: process, record: liveRecord(process, ppidOverride: parent))
}

/// A sleep copy that ignores SIGTERM: a shell sets the disposition and execs it (ignored signals survive exec).
private func spawnStubborn() throws -> Spawned {
    let copy = try throwawayCopy(of: "/bin/sleep", named: "stubborn-server")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "trap '' TERM; exec '\(copy.path)' 120"]
    try process.run()
    // Wait for the exec to land.
    for _ in 0..<50 {
        if let record = ProcessTable.snapshot()[process.processIdentifier], record.name == "stubborn-server" {
            return Spawned(process: process, record: record)
        }
        Thread.sleep(forTimeInterval: 0.05)
    }
    process.terminate()
    throw SpawnError.neverExecuted
}

private enum SpawnError: Error { case neverExecuted }

private func liveRecord(_ process: Process, ppidOverride: Int32?) throws -> ProcessInfoRecord {
    let real = try #require(ProcessTable.snapshot()[process.processIdentifier])
    guard let ppid = ppidOverride else { return real }
    return ProcessInfoRecord(
        pid: real.pid, ppid: ppid, pgid: real.pgid, uid: real.uid, name: real.name, path: real.path,
        arguments: real.arguments, cwd: real.cwd, startTime: real.startTime, cpuTimeNanos: 0, residentBytes: 0
    )
}
