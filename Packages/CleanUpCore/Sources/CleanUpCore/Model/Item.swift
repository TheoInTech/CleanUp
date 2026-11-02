public struct Item: Codable, Identifiable, Hashable, Sendable {
    public var id: ItemIdentity
    public let category: CategoryID
    public let name: String
    /// SF Symbol name.
    public let symbol: String
    public let judgement: Judgement
    public let cores: Double
    public let memoryBytes: UInt64
    public let processes: [ProcessRef]
    /// Extra facts for the explainer, e.g. "path", "project", "command", "udid", "image".
    public let detail: [String: String]

    public init(
        id: ItemIdentity,
        category: CategoryID,
        name: String,
        symbol: String,
        judgement: Judgement,
        cores: Double,
        memoryBytes: UInt64,
        processes: [ProcessRef],
        detail: [String: String]
    ) {
        self.id = id
        self.category = category
        self.name = name
        self.symbol = symbol
        self.judgement = judgement
        self.cores = cores
        self.memoryBytes = memoryBytes
        self.processes = processes
        self.detail = detail
    }
}
