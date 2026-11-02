import AppKit
import Darwin
import Foundation
import os

/// The machine readers the engine uses, as closures so tests can run without the real machine.
public struct SystemProbe: Sendable {
    public var now: @Sendable () -> Date
    public var processes: @Sendable () -> [Int32: ProcessInfoRecord]
    public var sockets: @Sendable ([Int32]) -> [SocketInfo]
    public var frontmostBundleID: @Sendable () async -> String?
    public var battery: @Sendable () -> BatteryReading?
    public var swap: @Sendable () -> (used: UInt64, total: UInt64)
    public var uptime: @Sendable () -> TimeInterval
    public var ownPID: Int32
    /// How long `freshContext()` watches CPU before acting, so modules can re-judge activity right
    /// before a stop. `.zero` → no sample (empty CPU map).
    public var freshSampleInterval: Duration

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        processes: @escaping @Sendable () -> [Int32: ProcessInfoRecord] = ProcessTable.snapshot,
        sockets: @escaping @Sendable ([Int32]) -> [SocketInfo] = Sockets.tcp(for:),
        frontmostBundleID: @escaping @Sendable () async -> String? = SystemProbe.liveFrontmostBundleID,
        battery: @escaping @Sendable () -> BatteryReading? = Battery.read,
        swap: @escaping @Sendable () -> (used: UInt64, total: UInt64) = SystemMemory.swap,
        uptime: @escaping @Sendable () -> TimeInterval = SystemMemory.uptime,
        ownPID: Int32 = getpid(),
        freshSampleInterval: Duration = .seconds(1)
    ) {
        self.now = now
        self.processes = processes
        self.sockets = sockets
        self.frontmostBundleID = frontmostBundleID
        self.battery = battery
        self.swap = swap
        self.uptime = uptime
        self.ownPID = ownPID
        self.freshSampleInterval = freshSampleInterval
    }

    public static let live = SystemProbe()

    /// Reads `NSWorkspace` on the main actor; the hop is one property read.
    @Sendable public static func liveFrontmostBundleID() async -> String? {
        await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    }

    /// A context for one moment: the given process table, sockets for all of its pids, and the
    /// frontmost app.
    public func context(
        now: Date, processes: [Int32: ProcessInfoRecord], cpu: [Int32: Double], runExternal: Bool
    ) async -> ScanContext {
        let sockets = sockets(Array(processes.keys))
        let frontmost = await frontmostBundleID()
        return ScanContext(
            now: now, processes: processes, cpu: cpu, sockets: sockets,
            frontmostBundleID: frontmost, ownPID: ownPID, runExternal: runExternal
        )
    }

    /// A fresh context for acting right now: modules re-verify live state from it. CPU comes from a
    /// short sample (`freshSampleInterval`), so "busy right now" is seen even if the last scan is old.
    public func freshContext() async -> ScanContext {
        guard freshSampleInterval > .zero else {
            return await context(now: now(), processes: processes(), cpu: [:], runExternal: true)
        }
        let start = now(), first = processes()
        try? await Task.sleep(for: freshSampleInterval)
        let end = now(), second = processes()
        let cpu = CPUSampler.percentages(from: first, at: start, to: second, at: end)
        return await context(now: end, processes: second, cpu: cpu, runExternal: true)
    }
}

/// Runs every category module against one shared context and assembles the `Snapshot`.
public actor Scanner {
    /// Drain samples are kept for this long.
    public static let drainWindow: TimeInterval = 5 * 60
    /// Drain counts as sustained only once samples reach back this far: the window minus one
    /// background sampling interval (60 s).
    public static let drainCoverage: TimeInterval = 4 * 60

    private let modules: [any CategoryModule]
    private let categoryTimeout: Duration
    private let probe: SystemProbe
    private let sampler = CPUSampler()

    /// Last items each module (by index) answered with, possibly from an older context.
    private var lastGood: [Int: [Item]] = [:]
    /// Scans that haven't answered yet, with the scan generation whose context they judge; reused
    /// instead of piling up another call to a stuck module.
    private var inFlight: [Int: (generation: Int, task: Task<[Item], Never>)] = [:]
    private var generation = 0
    private var drainSamples: [(date: Date, watts: Double)] = []

    public init(modules: [any CategoryModule], categoryTimeout: Duration = .seconds(25), probe: SystemProbe = .live) {
        self.modules = modules
        self.categoryTimeout = categoryTimeout
        self.probe = probe
    }

    public func scan(runExternal: Bool) async -> Snapshot {
        let now = probe.now()
        let table = probe.processes()
        let cpu = await sampler.sample(table, at: now)
        let ctx = await probe.context(now: now, processes: table, cpu: cpu, runExternal: runExternal)

        generation += 1
        let (fresh, late) = await runModules(ctx, generation: generation)
        for (index, items) in fresh.merging(late, uniquingKeysWith: { a, _ in a }) { lastGood[index] = items }

        // Only answers judged against this scan's context count. Anything older stays visible but
        // can't be idle: nothing may be stopped on the strength of a stale judgement.
        var byCategory: [CategoryID: [Item]] = [:]
        for index in modules.indices {
            let items = fresh[index] ?? (lastGood[index] ?? []).map(Self.unchecked)
            byCategory[modules[index].id, default: []] += items
        }
        let categories = CategoryID.allCases.compactMap { id -> CategorySummary? in
            var items = byCategory[id] ?? []
            if id == .restart { items = items.filter { $0.judgement.verdict == .advice } }
            return items.isEmpty ? nil : CategorySummary(id: id, items: items)
        }

        let battery = probe.battery()
        recordDrain(battery, at: now)
        let coresBusy = cpu.values.reduce(0, +) / 100
        let swap = probe.swap()
        return Snapshot(
            date: now,
            battery: battery,
            coresBusy: coresBusy,
            swapUsedBytes: swap.used,
            swapTotalBytes: swap.total,
            uptime: probe.uptime(),
            categories: categories,
            mood: StatusCalculator.mood(battery: battery, coresBusy: coresBusy, drainHistory: sustainedDrain(at: now))
        )
    }

    /// Every module forgets its observation windows (the Mac slept: that time wasn't watched).
    public func restartObservation() {
        for module in modules { module.restartObservation() }
    }

    // MARK: Modules

    /// `fresh`: answers judged against `ctx`, within the timeout. `late`: answers that arrived now
    /// from scans started by an earlier refresh (judged against an older context).
    private func runModules(_ ctx: ScanContext, generation: Int) async -> (fresh: [Int: [Item]], late: [Int: [Item]]) {
        var tasks: [(index: Int, generation: Int, task: Task<[Item], Never>)] = []
        for (index, module) in modules.enumerated() {
            let running = inFlight[index] ?? (generation, Task.detached { await module.scan(ctx) })
            inFlight[index] = running
            tasks.append((index, running.generation, running.task))
        }
        let timeout = categoryTimeout
        let answered = await withTaskGroup(of: (Int, [Item]?).self) { group in
            for entry in tasks {
                group.addTask { (entry.index, await withTimeout(entry.task, timeout)) }
            }
            var answered: [Int: [Item]] = [:]
            for await (index, items) in group {
                if let items { answered[index] = items }
            }
            return answered
        }
        var fresh: [Int: [Item]] = [:], late: [Int: [Item]] = [:]
        for entry in tasks {
            guard let items = answered[entry.index] else { continue }
            inFlight[entry.index] = nil
            if entry.generation == generation { fresh[entry.index] = items } else { late[entry.index] = items }
        }
        return (fresh, late)
    }

    static let uncheckedSignal = Signal(kind: .neutral, text: "Couldn't check just now")

    /// An item from an older context: shown, but an idle verdict is downgraded so it's never pre-ticked or stopped.
    static func unchecked(_ item: Item) -> Item {
        guard item.judgement.verdict == .idle else { return item }
        return Item(
            id: item.id, category: item.category, name: item.name, symbol: item.symbol,
            judgement: Judgement(verdict: .inUse, fact: "couldn't check", signals: item.judgement.signals + [uncheckedSignal]),
            cores: item.cores, memoryBytes: item.memoryBytes, processes: item.processes, detail: item.detail
        )
    }

    // MARK: Drain

    private func recordDrain(_ battery: BatteryReading?, at now: Date) {
        guard let battery, battery.onBattery else {
            drainSamples.removeAll()
            return
        }
        if let watts = battery.drainWatts { drainSamples.append((now, watts)) }
        drainSamples.removeAll { now.timeIntervalSince($0.date) > Self.drainWindow }
    }

    /// The last five minutes of drain, or nothing while the samples don't yet cover that window.
    private func sustainedDrain(at now: Date) -> [Double] {
        guard let oldest = drainSamples.first, now.timeIntervalSince(oldest.date) >= Self.drainCoverage else { return [] }
        return drainSamples.map(\.watts)
    }
}

/// The task's value, or nil if it takes longer than `timeout`. Never waits past the timeout, even for
/// a task that ignores cancellation (the task keeps running; its value is simply not waited for).
func withTimeout<T: Sendable>(_ task: Task<T, Never>, _ timeout: Duration) async -> T? {
    let pending = OSAllocatedUnfairLock<CheckedContinuation<T?, Never>?>(initialState: nil)
    let finish: @Sendable (T?) -> Void = { value in
        pending.withLock { $0.take() }?.resume(returning: value)
    }
    return await withCheckedContinuation { continuation in
        pending.withLock { $0 = continuation }
        let timer = Task.detached {
            do {
                try await Task.sleep(for: timeout)
                finish(nil)
            } catch {}
        }
        Task.detached {
            let value = await task.value
            finish(value)
            timer.cancel()
        }
    }
}
