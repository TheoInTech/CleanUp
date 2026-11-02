import Darwin
import Dispatch
import Foundation
import notify

/// "Clean idle now", posted by the widget and observed by the app, over the Darwin notify center.
/// Anyone can post a Darwin notification, so the signal alone proves nothing: the widget first
/// writes a `CleanupRequest` into the App Group, and the app acts only on a fresh one
/// (`CleanupSignalGate`).
public enum CleanupSignal {
    public static let name = "io.cleanup.cleanIdle"

    public static func post(name: String = name) {
        notify_post(name)
    }

    /// Calls `handler` (on a background queue) every time the signal is posted. Returns the
    /// registration token for `cancel(_:)`, or `NOTIFY_TOKEN_INVALID` if registration failed.
    @discardableResult
    public static func observe(name: String = name, _ handler: @escaping @Sendable () -> Void) -> Int32 {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .userInitiated)) { _ in handler() }
        return status == NOTIFY_STATUS_OK ? token : NOTIFY_TOKEN_INVALID
    }

    public static func cancel(_ token: Int32) {
        guard token != NOTIFY_TOKEN_INVALID else { return }
        notify_cancel(token)
    }
}

/// The widget's proof that it asked: when its Clean up button was tapped, written into the App
/// Group container (only the app and its widget can write there) just before the signal.
public enum CleanupRequest {
    public static let fileName = "cleanup-request.json"
    /// A request older than this is stale: the signal it came with is ignored.
    public static let maxAge: TimeInterval = 10

    private struct Payload: Codable {
        let requestedAt: Date
    }

    public static func url(groupID: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent(fileName)
    }

    public static func write(at date: Date, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Payload(requestedAt: date)).write(to: url, options: .atomic)
    }

    /// nil when there is no request or it can't be read.
    public static func read(from url: URL) -> Date? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONDecoder().decode(Payload.self, from: data))?.requestedAt
    }
}

/// Decides whether a received signal starts a cleanup: only for a request less than 10 s old, newer
/// than the last one handled, and at most once every 30 s.
public struct CleanupSignalGate: Sendable {
    public static let debounce: TimeInterval = 30
    /// Clocks of the widget and the app are the same Mac's; allow for a little scheduling skew.
    static let futureTolerance: TimeInterval = 2

    public private(set) var lastHandledRequest: Date?
    public private(set) var lastSignalCleanup: Date?

    public init() {}

    /// True (and recorded) when the signal should start a cleanup now.
    public mutating func accept(requestedAt: Date?, now: Date) -> Bool {
        guard let requestedAt else { return false }
        let age = now.timeIntervalSince(requestedAt)
        guard age < CleanupRequest.maxAge, age > -Self.futureTolerance else { return false }
        if let lastHandledRequest, requestedAt <= lastHandledRequest { return false }
        lastHandledRequest = requestedAt
        if let lastSignalCleanup, now.timeIntervalSince(lastSignalCleanup) < Self.debounce { return false }
        lastSignalCleanup = now
        return true
    }
}
