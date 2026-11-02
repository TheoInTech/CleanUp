import Darwin
import Foundation

/// Everything a module needs for one refresh, captured once so all modules judge the same moment.
public struct ScanContext: Sendable {
    public let now: Date
    public let processes: [Int32: ProcessInfoRecord]
    /// CPU % per pid (100 = one full core). Empty on the first refresh.
    public let cpu: [Int32: Double]
    public let sockets: [SocketInfo]
    public let frontmostBundleID: String?
    public let ownPID: Int32
    /// `false` → reuse cached results of external commands (`simctl`, `docker`, …) instead of running them.
    public let runExternal: Bool

    public init(
        now: Date,
        processes: [Int32: ProcessInfoRecord],
        cpu: [Int32: Double],
        sockets: [SocketInfo],
        frontmostBundleID: String?,
        ownPID: Int32,
        runExternal: Bool
    ) {
        self.now = now
        self.processes = processes
        self.cpu = cpu
        self.sockets = sockets
        self.frontmostBundleID = frontmostBundleID
        self.ownPID = ownPID
        self.runExternal = runExternal
    }
}

/// Everything needed to reverse a stop (e.g. `simctl boot <udid>`). Persisted by the engine.
public struct UndoToken: Codable, Hashable, Sendable {
    public let identity: ItemIdentity
    public let action: String
    public let arguments: [String]

    public init(identity: ItemIdentity, action: String, arguments: [String]) {
        self.identity = identity
        self.action = action
        self.arguments = arguments
    }
}

public enum StopResult: Sendable, Equatable {
    case stopped(UndoToken?)
    case skipped(reason: String)
    case failed(reason: String)
}

public protocol CategoryModule: Sendable {
    var id: CategoryID { get }
    func scan(_ ctx: ScanContext) async -> [Item]
    /// `force` ("Stop anyway") skips only the idle/activity checks (verdict, connections, traffic).
    /// Every identity and safety guard still applies: pid + start time, the never-stop list,
    /// CleanUp's own process tree, id validation. Engines are never forced.
    func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult
    func undo(_ token: UndoToken) async -> Bool
    /// Forget every observation window (quiet clocks, traffic baselines, "watched for"): the time
    /// since the last scan wasn't watched, e.g. the Mac slept. Modules with no windows do nothing.
    func restartObservation()
}

extension CategoryModule {
    /// A normal (not forced) stop.
    public func stop(_ item: Item, ctx: ScanContext) async -> StopResult {
        await stop(item, ctx: ctx, force: false)
    }

    public func restartObservation() {}
}

/// How observation windows treat time CleanUp didn't watch.
public enum Observation {
    /// Scans come every 5 s (window open) or 60 s (background). A longer gap between two scans
    /// (sleep, App Nap, a stuck refresh) wasn't watched, so it can't count as quiet time: every
    /// window starts over.
    public static let maxGap: TimeInterval = 150

    /// True when `now` is more than `maxGap` after `last`.
    public static func isGap(since last: Date?, now: Date) -> Bool {
        guard let last else { return false }
        return now.timeIntervalSince(last) > maxGap
    }
}

/// Signals processes with the guard rails every module shares: only our own user's processes, only
/// when pid *and* start time still match (a recycled pid is never hit), never ourselves, and never
/// anything on the global never-stop list (system software, Finder, Dock, WindowServer).
public enum ProcessSignaler {
    private static let protectedPrefixes = ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"]
    /// Third-party tools installed under /usr/local are ordinary user software, not system software.
    private static let unprotectedPrefixes = ["/usr/local/"]
    private static let protectedNames: Set<String> = ["Finder", "Dock", "WindowServer"]

    /// The global never-stop list.
    public static func isProtected(path: String, name: String) -> Bool {
        if protectedNames.contains(name) || protectedNames.contains((path as NSString).lastPathComponent) { return true }
        if unprotectedPrefixes.contains(where: path.hasPrefix) { return false }
        return protectedPrefixes.contains(where: path.hasPrefix)
    }

    public struct Outcome: Sendable, Equatable {
        /// Signalled now.
        public var signalled: [Int32] = []
        /// Already gone, or the pid now belongs to a different process: nothing left to stop.
        public var gone: [Int32] = []
        /// Still there but refused (other user / root / ourselves / kernel said no).
        public var refused: [Int32] = []
    }

    public static func terminate(_ refs: [ProcessRef], signal: Int32 = SIGTERM) -> Outcome {
        let table = ProcessTable.snapshot()
        var outcome = Outcome()
        for ref in refs {
            guard let current = table[ref.pid], current.startTime == ref.startTime else {
                outcome.gone.append(ref.pid)
                continue
            }
            guard current.uid == getuid(), ref.pid != getpid(), ref.pid > 1,
                  !isProtected(path: current.path, name: current.name) else {
                outcome.refused.append(ref.pid)
                continue
            }
            if kill(ref.pid, signal) == 0 {
                outcome.signalled.append(ref.pid)
            } else if errno == ESRCH {
                outcome.gone.append(ref.pid)
            } else {
                outcome.refused.append(ref.pid)
            }
        }
        return outcome
    }
}
