import Darwin
import Dispatch
import notify

/// "Clean idle now", posted by the widget and observed by the app, over the Darwin notify center.
public enum CleanupSignal {
    public static let name = "io.cleanup.cleanIdle"

    public static func post() {
        notify_post(name)
    }

    /// Calls `handler` (on a background queue) every time the signal is posted. Returns the
    /// registration token for `cancel(_:)`, or `NOTIFY_TOKEN_INVALID` if registration failed.
    @discardableResult
    public static func observe(_ handler: @escaping @Sendable () -> Void) -> Int32 {
        var token: Int32 = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(name, &token, DispatchQueue.global(qos: .userInitiated)) { _ in handler() }
        return status == NOTIFY_STATUS_OK ? token : NOTIFY_TOKEN_INVALID
    }

    public static func cancel(_ token: Int32) {
        guard token != NOTIFY_TOKEN_INVALID else { return }
        notify_cancel(token)
    }
}
