public struct Signal: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case inUse, idle, neutral
    }

    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}
