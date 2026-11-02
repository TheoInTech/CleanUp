import Foundation

/// Turns cumulative CPU time into a percentage over the interval between two snapshots.
public actor CPUSampler {
    private struct Previous {
        let startTime: Date
        let cpuTimeNanos: UInt64
    }

    private var previous: [Int32: Previous] = [:]
    private var previousDate: Date?

    public init() {}

    /// CPU % per pid since the previous call (100 = one full core). The first call, or a call whose
    /// timestamp is not after the previous one, returns `[:]`. Processes that are new since the last
    /// sample (or whose pid was recycled) are omitted until they have two samples.
    public func sample(_ table: [Int32: ProcessInfoRecord], at date: Date) -> [Int32: Double] {
        defer {
            previous = table.mapValues { Previous(startTime: $0.startTime, cpuTimeNanos: $0.cpuTimeNanos) }
            previousDate = date
        }
        guard let last = previousDate else { return [:] }
        return Self.percentages(
            from: previous.mapValues { ($0.startTime, $0.cpuTimeNanos) }, at: last, to: table, at: date
        )
    }

    /// CPU % per pid between two snapshots of the table. Empty when `end` is not after `start`;
    /// processes missing from the first snapshot (or with a recycled pid) are left out.
    public static func percentages(
        from first: [Int32: ProcessInfoRecord], at start: Date, to second: [Int32: ProcessInfoRecord], at end: Date
    ) -> [Int32: Double] {
        percentages(from: first.mapValues { ($0.startTime, $0.cpuTimeNanos) }, at: start, to: second, at: end)
    }

    private static func percentages(
        from first: [Int32: (startTime: Date, cpuTimeNanos: UInt64)], at start: Date,
        to second: [Int32: ProcessInfoRecord], at end: Date
    ) -> [Int32: Double] {
        let elapsedNanos = end.timeIntervalSince(start) * 1_000_000_000
        guard elapsedNanos > 0 else { return [:] }
        var result: [Int32: Double] = [:]
        result.reserveCapacity(second.count)
        for (pid, record) in second {
            guard let old = first[pid], old.startTime == record.startTime else { continue }
            let delta = record.cpuTimeNanos >= old.cpuTimeNanos ? record.cpuTimeNanos - old.cpuTimeNanos : 0
            result[pid] = Double(delta) / elapsedNanos * 100
        }
        return result
    }
}
