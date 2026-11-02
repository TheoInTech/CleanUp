public struct CategorySummary: Codable, Hashable, Sendable {
    public let id: CategoryID
    public let items: [Item]

    public var cores: Double { items.reduce(0) { $0 + $1.cores } }

    public init(id: CategoryID, items: [Item]) {
        self.id = id
        self.items = items
    }

    private enum CodingKeys: String, CodingKey {
        case id, items
    }
}
