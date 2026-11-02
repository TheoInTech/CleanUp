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
    func stop(_ item: Item, ctx: ScanContext) async -> StopResult
    func undo(_ token: UndoToken) async -> Bool
}

/// Signals processes with the guard rails every module shares: only our own user's processes, only
/// when pid *and* start time still match (a recycled pid is never hit), never ourselves.
public enum ProcessSignaler {
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
            guard current.uid == getuid(), ref.pid != getpid(), ref.pid > 1 else {
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
