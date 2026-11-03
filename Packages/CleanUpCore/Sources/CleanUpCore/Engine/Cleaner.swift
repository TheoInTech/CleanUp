import Foundation

public struct CleanupReport: Sendable {
    public let stopped: [ItemIdentity]
    public let failed: [(ItemIdentity, String)]
    public let skipped: [(ItemIdentity, String)]
    public let undo: [UndoToken]
    /// Cores of the items actually stopped.
    public let freedCores: Double

    public init(
        stopped: [ItemIdentity], failed: [(ItemIdentity, String)], skipped: [(ItemIdentity, String)],
        undo: [UndoToken], freedCores: Double
    ) {
        self.stopped = stopped
        self.failed = failed
        self.skipped = skipped
        self.undo = undo
        self.freedCores = freedCores
    }
}

/// Stops ticked items through their category modules. Every module re-verifies against a context
/// built at clean time. Container engines get one more check: quitting an engine stops every
/// container in it, so just before that the containers are listed again (`docker ps`), and the
/// engine is skipped unless the fresh listing judges it idle and shows none of its containers.
public actor Cleaner {
    private let modules: [CategoryID: any CategoryModule]
    private let probe: SystemProbe
    private let undoRetries: Int
    private let undoRetryDelay: Duration
    private let engineCheckTimeout: Duration

    /// `undoRetries`/`undoRetryDelay`: after relaunching a container engine, container restarts that
    /// fail are retried while the engine comes up. `engineCheckTimeout`: how long the container
    /// re-listing before quitting an engine may take; past it the engine is skipped.
    public init(
        modules: [any CategoryModule],
        probe: SystemProbe = .live,
        undoRetries: Int = 12,
        undoRetryDelay: Duration = .seconds(5),
        engineCheckTimeout: Duration = .seconds(30)
    ) {
        var byID: [CategoryID: any CategoryModule] = [:]
        for module in modules {
            if byID[module.id] != nil {
                assertionFailure("Cleaner: more than one module for \(module.id); only the first is used")
                continue
            }
            byID[module.id] = module
        }
        self.modules = byID
        self.probe = probe
        self.undoRetries = undoRetries
        self.undoRetryDelay = undoRetryDelay
        self.engineCheckTimeout = engineCheckTimeout
    }

    /// Cleans against a fresh context (new process table, sockets and frontmost app). Items in
    /// `forced` ("Stop anyway") skip the idle/activity checks but none of the safety guards;
    /// engines are never forced.
    public func clean(_ items: [Item], forced: Set<ItemIdentity> = []) async -> CleanupReport {
        await clean(items, ctx: await probe.freshContext(), forced: forced)
    }

    /// Everything that isn't an engine first (categories in parallel, items within a category one by
    /// one), then the engines. A container engine is skipped if one of its containers in `items`
    /// didn't stop, or unless a fresh listing (new context, `runExternal: true`) judges the engine idle
    /// and shows no running container of it: quitting the engine would stop those containers.
    public func clean(_ items: [Item], ctx: ScanContext, forced: Set<ItemIdentity> = []) async -> CleanupReport {
        var results = [StopResult?](repeating: nil, count: items.count)
        let isEngine = items.map { $0.id.rawValue.hasPrefix(Selection.enginePrefix) }

        for (index, result) in await stop(items.indices.filter { !isEngine[$0] }, of: items, ctx: ctx, forced: forced) {
            results[index] = result
        }

        var engines: [Int] = []
        for index in items.indices where isEngine[index] {
            let engine = items[index]
            let holdout = items.indices.first { i in
                Selection.isContainer(items[i]) && Selection.container(items[i], belongsTo: engine)
                    && !Self.didStop(results[i])
            }
            if let holdout {
                results[index] = .skipped(reason: "\(items[holdout].name) is still running")
            } else {
                engines.append(index)
            }
        }
        var engineCtx = ctx
        let containerEngines = engines.filter { Selection.engineName(of: items[$0]) != nil }
        if !containerEngines.isEmpty {
            let fresh = await probe.freshContext()
            engineCtx = fresh
            let listed = await listContainers(ctx: fresh)
            for index in containerEngines {
                let engine = items[index]
                let skip: String?
                if let listed, let fresh = listed.first(where: { $0.id == engine.id }) {
                    let running = listed.contains { Selection.isContainer($0) && Selection.container($0, belongsTo: engine) }
                    if fresh.judgement.verdict != .idle {
                        // With several engines up, the module can't tell which hosts each container
                        // (it tags them all with one) and judges every engine in use.
                        // Otherwise the fresh judgement says why ("used by docker-buildx", "measuring activity").
                        let engineCount = listed.filter { Selection.engineName(of: $0) != nil }.count
                        skip = engineCount > 1 ? "another container engine is running" : fresh.judgement.fact
                    } else {
                        skip = running ? "a container is still running" : nil
                    }
                } else {
                    skip = "couldn't check containers"   // docker didn't answer, timed out, or no longer sees the engine
                }
                if let skip {
                    results[index] = .skipped(reason: skip)
                    engines.removeAll { $0 == index }
                }
            }
        }
        for (index, result) in await stop(engines, of: items, ctx: engineCtx, forced: []) {
            results[index] = result
        }

        var stopped: [ItemIdentity] = [], failed: [(ItemIdentity, String)] = [], skipped: [(ItemIdentity, String)] = []
        var undo: [UndoToken] = []
        var freed = 0.0
        for (item, result) in zip(items, results) {
            switch result ?? .failed(reason: "not attempted") {
            case .stopped(let token):
                stopped.append(item.id)
                freed += item.cores
                if let token { undo.append(token) }
            case .skipped(let reason): skipped.append((item.id, reason))
            case .failed(let reason): failed.append((item.id, reason))
            }
        }
        return CleanupReport(stopped: stopped, failed: failed, skipped: skipped, undo: undo, freedCores: freed)
    }

    /// Engines first (containers need theirs running), then everything else. Returns the tokens that
    /// couldn't be undone.
    @discardableResult
    public func undo(_ tokens: [UndoToken]) async -> [UndoToken] {
        var failed: [UndoToken] = []
        var containerEngineBack = false
        for token in tokens where token.identity.rawValue.hasPrefix(Selection.enginePrefix) {
            if await undoOne(token) {
                if Self.category(of: token) == .containers { containerEngineBack = true }
            } else {
                failed.append(token)
            }
        }

        var pending = tokens.filter { !$0.identity.rawValue.hasPrefix(Selection.enginePrefix) }
        var attempts = 0
        while !pending.isEmpty {
            var failing: [UndoToken] = []
            for token in pending where !(await undoOne(token)) { failing.append(token) }
            // Only container restarts are worth retrying, and only while a relaunched engine starts up.
            let retryable = failing.filter { Self.category(of: $0) == .containers }
            failed += failing.filter { Self.category(of: $0) != .containers }
            pending = retryable
            guard containerEngineBack, attempts < undoRetries, !pending.isEmpty else { break }
            attempts += 1
            try? await Task.sleep(for: undoRetryDelay)
        }
        return failed + pending
    }

    // MARK: Helpers

    private func stop(_ indices: [Int], of items: [Item], ctx: ScanContext, forced: Set<ItemIdentity>) async -> [(Int, StopResult)] {
        var groups: [CategoryID: [Int]] = [:]
        for index in indices { groups[items[index].category, default: []].append(index) }
        let modules = self.modules
        return await withTaskGroup(of: [(Int, StopResult)].self) { group in
            for (category, members) in groups {
                let module = modules[category]
                let work = members.map { ($0, items[$0], forced.contains(items[$0].id)) }
                group.addTask {
                    var out: [(Int, StopResult)] = []
                    for (index, item, force) in work {
                        guard let module else {
                            out.append((index, .failed(reason: "Nothing can stop \(category.rawValue) items")))
                            continue
                        }
                        out.append((index, await module.stop(item, ctx: ctx, force: force)))
                    }
                    return out
                }
            }
            var all: [(Int, StopResult)] = []
            for await part in group { all += part }
            return all
        }
    }

    /// The containers module's items for a fresh context; nil when there is no module or it doesn't
    /// answer in time.
    private func listContainers(ctx: ScanContext) async -> [Item]? {
        guard let module = modules[.containers] else { return nil }
        return await withTimeout(Task.detached { await module.scan(ctx) }, engineCheckTimeout)
    }

    private func undoOne(_ token: UndoToken) async -> Bool {
        guard let category = Self.category(of: token), let module = modules[category] else { return false }
        return await module.undo(token)
    }

    private static func didStop(_ result: StopResult?) -> Bool {
        if case .stopped = result { return true }
        return false
    }

    /// Tokens outlive the scan that produced them, so their category comes from the identity.
    static func category(of token: UndoToken) -> CategoryID? {
        let raw = token.identity.rawValue
        if token.identity == SimulatorsModule.engineIdentity { return .simulators }
        if token.identity == .restart { return .restart }
        let prefixes: [(String, CategoryID)] = [
            ("sim:", .simulators), ("container:", .containers), (Selection.enginePrefix, .containers),
            ("dev:", .devServers), ("app:", .apps), ("tab:", .browserTabs),
        ]
        return prefixes.first { raw.hasPrefix($0.0) }?.1
    }
}
