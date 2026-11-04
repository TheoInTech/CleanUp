/// Stable identity of an item across refreshes. Encodes as a plain string.
public struct ItemIdentity: Codable, Hashable, Sendable, RawRepresentable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func simulator(udid: String) -> ItemIdentity { .init(rawValue: "sim:\(udid)") }
    public static func container(name: String) -> ItemIdentity { .init(rawValue: "container:\(name)") }
    public static func engine(name: String) -> ItemIdentity { .init(rawValue: "engine:\(name)") }
    public static func devServer(cwd: String, command: String) -> ItemIdentity { .init(rawValue: "dev:\(cwd)|\(command)") }
    public static func app(bundleID: String) -> ItemIdentity { .init(rawValue: "app:\(bundleID)") }
    public static func browserTab(pid: Int32) -> ItemIdentity { .init(rawValue: "tab:\(pid)") }
    public static let restart = ItemIdentity(rawValue: "restart")
    public static func worktree(path: String) -> ItemIdentity { .init(rawValue: "worktree:\(path)") }
    public static let worktreeLeftovers = ItemIdentity(rawValue: "worktree-leftovers")
}
