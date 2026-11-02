public enum Mood: String, Codable, Sendable {
    case allGood, busy, drainingFast

    public var label: String {
        switch self {
        case .allGood: "😌 All good"
        case .busy: "🟠 Busy"
        case .drainingFast: "🔥 Draining fast"
        }
    }
}
