import Foundation

/// Decides when to warn that the battery is draining fast because of idle work. Pure: the caller
/// supplies `idleShare` (cores the quick selection would free ÷ cores busy) and the clock.
public struct DrainMonitor: Sendable {
    public static let minimumIdleShare = 0.3
    public static let quietPeriod: TimeInterval = 30 * 60

    public var lastWarning: Date?

    public init(lastWarning: Date? = nil) {
        self.lastWarning = lastWarning
    }

    /// True iff the mood is `.drainingFast` (on battery), at least 30% of the load is idle work, and
    /// there was no warning in the last 30 minutes. Records the warning when it returns true.
    public mutating func shouldWarn(snapshot: Snapshot, idleShare: Double, now: Date) -> Bool {
        guard snapshot.mood == .drainingFast, snapshot.battery?.onBattery == true,
              idleShare >= Self.minimumIdleShare else { return false }
        if let lastWarning, now.timeIntervalSince(lastWarning) < Self.quietPeriod { return false }
        lastWarning = now
        return true
    }
}
