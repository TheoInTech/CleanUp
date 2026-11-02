import Foundation

/// Compact human ages for facts: "13 min", "3 h", "2 days". Largest unit only, rounded down.
public enum RelativeAge {
    public static func short(_ interval: TimeInterval) -> String {
        let seconds = max(0, interval)
        if seconds < 60 { return "<1 min" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h" }
        let days = hours / 24
        return days == 1 ? "1 day" : "\(days) days"
    }
}
