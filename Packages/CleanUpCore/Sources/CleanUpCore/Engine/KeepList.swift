import Foundation

/// Items the user never wants pre-ticked, persisted as identity → name pairs in `UserDefaults`.
public struct KeepList: Sendable {
    public static let defaultsKey = "io.cleanup.keepList"

    /// In memory only; nothing is persisted.
    public static let empty = KeepList(store: [:], defaults: nil)

    private var store: [String: String]
    /// `UserDefaults` is documented as thread-safe but not annotated `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults?

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        self.store = defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private init(store: [String: String], defaults: UserDefaults?) {
        self.store = store
        self.defaults = defaults
    }

    public func contains(_ id: ItemIdentity) -> Bool { store[id.rawValue] != nil }

    public mutating func add(_ id: ItemIdentity, name: String) {
        store[id.rawValue] = name
        save()
    }

    public mutating func remove(_ id: ItemIdentity) {
        store[id.rawValue] = nil
        save()
    }

    /// Sorted by name (then identity) for a stable list.
    public var entries: [(id: ItemIdentity, name: String)] {
        store
            .map { (id: ItemIdentity(rawValue: $0.key), name: $0.value) }
            .sorted { ($0.name, $0.id.rawValue) < ($1.name, $1.id.rawValue) }
    }

    private func save() {
        defaults?.set(store, forKey: Self.defaultsKey)
    }
}
