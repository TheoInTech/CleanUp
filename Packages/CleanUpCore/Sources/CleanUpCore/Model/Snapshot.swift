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
    /// How many items Quick select would stop right now, and the cores they use. The app fills these
    /// in (it alone knows the Always-kept list) so the sandboxed widget can show its Clean up button
    /// without scanning. 0 in a fresh scan and in JSON written before these existed.
    public let idleCount: Int
    public let freedCores: Double

    public init(
        date: Date,
        battery: BatteryReading?,
        coresBusy: Double,
        swapUsedBytes: UInt64,
        swapTotalBytes: UInt64,
        uptime: TimeInterval,
        categories: [CategorySummary],
        mood: Mood,
        idleCount: Int = 0,
        freedCores: Double = 0
    ) {
        self.date = date
        self.battery = battery
        self.coresBusy = coresBusy
        self.swapUsedBytes = swapUsedBytes
        self.swapTotalBytes = swapTotalBytes
        self.uptime = uptime
        self.categories = categories
        self.mood = mood
        self.idleCount = idleCount
        self.freedCores = freedCores
    }

    /// A copy carrying what Quick select would stop, for the widget.
    public func withQuickSummary(idleCount: Int, freedCores: Double) -> Snapshot {
        Snapshot(
            date: date, battery: battery, coresBusy: coresBusy, swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapTotalBytes, uptime: uptime, categories: categories, mood: mood,
            idleCount: idleCount, freedCores: freedCores
        )
    }

    /// The copy shared with the widget: items keep their name, verdict, fact and cores, but no
    /// details, signals or processes (command lines and paths never leave the app).
    public func forWidget() -> Snapshot {
        let lean = categories.map { category in
            CategorySummary(id: category.id, items: category.items.map { item in
                Item(
                    id: item.id, category: item.category, name: item.name, symbol: item.symbol,
                    judgement: Judgement(verdict: item.judgement.verdict, fact: item.judgement.fact, signals: []),
                    cores: item.cores, memoryBytes: item.memoryBytes, processes: [], detail: [:]
                )
            })
        }
        return Snapshot(
            date: date, battery: battery, coresBusy: coresBusy, swapUsedBytes: swapUsedBytes,
            swapTotalBytes: swapTotalBytes, uptime: uptime, categories: lean, mood: mood,
            idleCount: idleCount, freedCores: freedCores
        )
    }

    /// Older JSON has no `idleCount` / `freedCores`; they read as 0.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        battery = try c.decodeIfPresent(BatteryReading.self, forKey: .battery)
        coresBusy = try c.decode(Double.self, forKey: .coresBusy)
        swapUsedBytes = try c.decode(UInt64.self, forKey: .swapUsedBytes)
        swapTotalBytes = try c.decode(UInt64.self, forKey: .swapTotalBytes)
        uptime = try c.decode(TimeInterval.self, forKey: .uptime)
        categories = try c.decode([CategorySummary].self, forKey: .categories)
        mood = try c.decode(Mood.self, forKey: .mood)
        idleCount = try c.decodeIfPresent(Int.self, forKey: .idleCount) ?? 0
        freedCores = try c.decodeIfPresent(Double.self, forKey: .freedCores) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case date, battery, coresBusy, swapUsedBytes, swapTotalBytes, uptime, categories, mood, idleCount, freedCores
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
