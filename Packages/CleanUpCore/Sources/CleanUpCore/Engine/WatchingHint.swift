import Foundation

extension Snapshot {
    /// When CleanUp will have watched everything in use long enough to judge it: the latest pending
    /// watch among items in use. Nil when nothing is waiting on a watch.
    public func watchingUntil(now: Date) -> Date? {
        categories
            .flatMap(\.items)
            .filter { $0.judgement.verdict == .inUse }
            .compactMap(\.judgement.watchingUntil)
            .filter { $0 > now }
            .max()
    }
}

/// The line under a disabled Clean up button while CleanUp is still watching: nothing looks idle
/// yet because it hasn't watched long enough, not because nothing is.
public enum WatchingHint {
    /// "Still watching · ready in 25 min" (whole minutes, rounded up); nil once the watch is over.
    public static func text(until: Date, now: Date) -> String? {
        let left = until.timeIntervalSince(now)
        guard left > 0 else { return nil }
        return "Still watching · ready in \(max(1, Int((left / 60).rounded(.up)))) min"
    }
}
