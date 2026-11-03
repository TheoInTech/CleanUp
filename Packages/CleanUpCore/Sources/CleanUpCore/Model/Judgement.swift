import Foundation

public struct Judgement: Codable, Hashable, Sendable {
    public let verdict: Verdict
    public let fact: String
    public let signals: [Signal]
    /// When CleanUp's watch of this item ends (it is in use at least until then because CleanUp
    /// hasn't watched it long enough); nil when no watch is pending.
    public let watchingUntil: Date?

    public init(verdict: Verdict, fact: String, signals: [Signal], watchingUntil: Date? = nil) {
        self.verdict = verdict
        self.fact = fact
        self.signals = signals
        self.watchingUntil = watchingUntil
    }
}
