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

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        processes: @escaping @Sendable () -> [Int32: ProcessInfoRecord] = ProcessTable.snapshot,
        sockets: @escaping @Sendable ([Int32]) -> [SocketInfo] = Sockets.tcp(for:),
        frontmostBundleID: @escaping @Sendable () async -> String? = SystemProbe.liveFrontmostBundleID,
        battery: @escaping @Sendable () -> BatteryReading? = Battery.read,
        swap: @escaping @Sendable () -> (used: UInt64, total: UInt64) = SystemMemory.swap,
        uptime: @escaping @Sendable () -> TimeInterval = SystemMemory.uptime,
        ownPID: Int32 = getpid()
    ) {
        self.now = now
        self.processes = processes
        self.sockets = sockets
        self.frontmostBundleID = frontmostBundleID
        self.battery = battery
        self.swap = swap
        self.uptime = uptime
        self.ownPID = ownPID
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

    /// A fresh context for acting right now (no CPU delta; modules re-verify live state from it).
    public func freshContext() async -> ScanContext {
        await context(now: now(), processes: processes(), cpu: [:], runExternal: true)
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

    /// Last items each module (by index) answered with in time.
    private var lastGood: [Int: [Item]] = [:]
    /// Scans that haven't answered yet; reused instead of piling up another call to a stuck module.
    private var inFlight: [Int: Task<[Item], Never>] = [:]
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

        let fresh = await runModules(ctx)
        for (index, items) in fresh { lastGood[index] = items }

        var byCategory: [CategoryID: [Item]] = [:]
        for index in modules.indices {
            byCategory[modules[index].id, default: []] += fresh[index] ?? lastGood[index] ?? []
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

    // MARK: Modules

    /// Items per module index, for the modules that answered within the timeout.
    private func runModules(_ ctx: ScanContext) async -> [Int: [Item]] {
        var tasks: [(Int, Task<[Item], Never>)] = []
        for (index, module) in modules.enumerated() {
            let task = inFlight[index] ?? Task.detached { await module.scan(ctx) }
            inFlight[index] = task
            tasks.append((index, task))
        }
        let timeout = categoryTimeout
        let answered = await withTaskGroup(of: (Int, [Item]?).self) { group in
            for (index, task) in tasks {
                group.addTask { (index, await Self.value(of: task, within: timeout)) }
            }
            var answered: [Int: [Item]] = [:]
            for await (index, items) in group {
                if let items { answered[index] = items }
            }
            return answered
        }
        for index in answered.keys { inFlight[index] = nil }
        return answered
    }

    /// The task's value, or nil if it takes longer than `timeout`. Never waits past the timeout, even
    /// for a task that ignores cancellation.
    private static func value(of task: Task<[Item], Never>, within timeout: Duration) async -> [Item]? {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<[Item]?, Never>?>(initialState: nil)
        let finish: @Sendable ([Item]?) -> Void = { value in
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
                let items = await task.value
                finish(items)
                timer.cancel()
            }
        }
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
