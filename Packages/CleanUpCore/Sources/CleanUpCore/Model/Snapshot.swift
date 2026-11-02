import Foundation

public struct Snapshot: Codable, Hashable, Sendable {
    public let date: Date
    public let battery: BatteryReading?
    public let coresBusy: Double
    public let swapUsedBytes: UInt64
    public let swapTotalBytes: UInt64
    public let uptime: TimeInterval
    public let categories: [CategorySummary]
    public let mood: Mood

    public init(
        date: Date,
        battery: BatteryReading?,
        coresBusy: Double,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        uptime: TimeInterval,
        categories: [CategorySummary],
        mood: Mood
    ) {
        self.date = date
        self.battery = battery
        self.coresBusy = coresBusy
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.uptime = uptime
        self.categories = categories
        self.mood = mood
    }

    public static let empty = Snapshot(
        date: Date(timeIntervalSince1970: 0),
        battery: nil,
        coresBusy: 0,
        swapUsedBytes: 0,
        swapTotalBytes: 0,
        uptime: 0,
        categories: [],
        mood: .allGood
    )
}
