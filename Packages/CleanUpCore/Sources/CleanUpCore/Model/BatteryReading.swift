public struct BatteryReading: Codable, Hashable, Sendable {
    public let onBattery: Bool
    public let percent: Int
    public let drainWatts: Double?
    public let minutesLeft: Int?
    /// Maximum capacity as a share of the design capacity; nil when the battery doesn't say.
    public let healthPercent: Int?
    public let cycleCount: Int?

    public init(
        onBattery: Bool,
        percent: Int,
        drainWatts: Double?,
        minutesLeft: Int?,
        healthPercent: Int?,
        cycleCount: Int?
    ) {
        self.onBattery = onBattery
        self.percent = percent
        self.drainWatts = drainWatts
        self.minutesLeft = minutesLeft
        self.healthPercent = healthPercent
        self.cycleCount = cycleCount
    }
}
