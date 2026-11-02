public struct Judgement: Codable, Hashable, Sendable {
    public let verdict: Verdict
    public let fact: String
    public let signals: [Signal]

    public init(verdict: Verdict, fact: String, signals: [Signal]) {
        self.verdict = verdict
        self.fact = fact
        self.signals = signals
    }
}
