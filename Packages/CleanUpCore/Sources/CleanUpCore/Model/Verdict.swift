/// `manual` = apps, `check` = browser tabs, `advice` = restart.
public enum Verdict: String, Codable, Sendable {
    case idle, inUse, manual, check, advice
}
