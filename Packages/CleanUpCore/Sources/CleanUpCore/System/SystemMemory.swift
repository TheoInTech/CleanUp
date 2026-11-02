import Darwin
import Foundation

public enum SystemMemory {
    /// Swap currently used / allocated, in bytes. `(0, 0)` if the kernel won't say.
    public static func swap() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }

    /// Seconds since boot, *including* time asleep (unlike `ProcessInfo.systemUptime`), which is
    /// what "you haven't restarted in N days" should mean.
    public static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            return ProcessInfo.processInfo.systemUptime
        }
        let bootDate = Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
        return max(0, Date().timeIntervalSince(bootDate))
    }

    /// Parses `sysctl vm.swapusage` text such as
    /// `total = 23552.00M  used = 22424.62M  free = 1127.38M  (encrypted)`.
    public static func parseSwapUsage(_ s: String) -> (used: UInt64, total: UInt64)? {
        guard let total = value(after: "total", in: s), let used = value(after: "used", in: s) else { return nil }
        return (used, total)
    }

    private static func value(after key: String, in s: String) -> UInt64? {
        let tokens = s.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == "\t" }).map(String.init)
        guard let i = tokens.firstIndex(of: key), i + 1 < tokens.count, let unit = tokens[i + 1].last else {
            return nil
        }
        let multiplier: Double
        switch unit {
        case "K", "k": multiplier = 1_024
        case "M", "m": multiplier = 1_048_576
        case "G", "g": multiplier = 1_073_741_824
        case "T", "t": multiplier = 1_099_511_627_776
        default: return nil
        }
        guard let number = Double(tokens[i + 1].dropLast()), number >= 0 else { return nil }
        return UInt64(number * multiplier)
    }
}
