import CleanUpCore
import Foundation
import os
@preconcurrency import UserNotifications

/// The drain warning and the quiet "Stopped N" follow-up. Everything here is local; nothing leaves the Mac.
enum Notifications {
    static let categoryID = "DRAIN"
    static let cleanAction = "CLEAN"
    static let showAction = "SHOW"
    static let didRequestKey = "didRequestNotificationAuthorization"

    private static let log = Logger(subsystem: "io.cleanup.CleanUp", category: "Notifications")

    /// Asks once, at first launch. If the user said no, we never ask again (no prompt loop); posting
    /// then silently does nothing.
    static func requestAuthorization(defaults: UserDefaults = .standard) async {
        guard !defaults.bool(forKey: didRequestKey) else { return }
        defaults.set(true, forKey: didRequestKey)
        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("Notification permission failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The warning's two buttons. Registered at launch too, so a warning delivered before this run
    /// (or tapped on a cold launch) still has them; `idleCount` nil → "Clean up idle".
    static func registerDrainCategory(idleCount: Int?) {
        let title = idleCount.map { DrainWarning(summary: "", idleCount: $0, minutesLeft: nil).actionTitle } ?? "Clean up idle"
        let clean = UNNotificationAction(identifier: cleanAction, title: title, options: [])
        let show = UNNotificationAction(identifier: showAction, title: "Show me", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: categoryID, actions: [clean, show], intentIdentifiers: [], options: []),
        ])
    }

    /// "Battery draining fast · 35 min left" with the idle culprits as the body and two buttons.
    /// The category is registered again before every post so "Clean up N idle" carries the current N.
    static func postDrainWarning(minutesLeft: Int?, idleSummary: String, idleCount: Int) async {
        let center = UNUserNotificationCenter.current()
        let warning = DrainWarning(summary: idleSummary, idleCount: idleCount, minutesLeft: minutesLeft)
        registerDrainCategory(idleCount: idleCount)

        let content = UNMutableNotificationContent()
        content.title = warning.title
        content.body = idleSummary
        content.categoryIdentifier = categoryID
        content.sound = .default
        content.interruptionLevel = .active
        await add(content, id: "drain-warning", to: center)
    }

    /// The result of a cleanup started from the notification or the widget while no CleanUp window is
    /// open, so the user still sees what happened. Shown as a banner (`.active`; `.passive` can stay
    /// hidden in Notification Center), but quiet: no sound.
    static func postResult(_ text: String) async {
        let content = UNMutableNotificationContent()
        content.title = text
        content.sound = nil
        content.interruptionLevel = .active
        await add(content, id: "cleanup-result", to: UNUserNotificationCenter.current())
    }

    private static func add(_ content: UNMutableNotificationContent, id: String, to center: UNUserNotificationCenter) async {
        // Same identifier replaces the previous one instead of stacking.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await center.add(request)
            let status = await center.notificationSettings().authorizationStatus
            log.notice("Posted \(id, privacy: .public) (permission \(status.rawValue))")
        } catch {
            log.error("Notification not posted: \(String(describing: error), privacy: .public)")
        }
    }
}

/// Receives notification taps and forwards them to the model (which is `@Observable`, not an `NSObject`).
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Banners show even while CleanUp is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        await MainActor.run {
            switch action {
            case Notifications.cleanAction:
                Task { await AppModel.shared.cleanIdle() }
            case Notifications.showAction, UNNotificationDefaultActionIdentifier:
                AppModel.shared.showMainWindow()
            default:
                break
            }
        }
    }
}
