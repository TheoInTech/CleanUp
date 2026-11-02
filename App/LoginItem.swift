import Foundation
import os
import ServiceManagement

/// Open at login, through `SMAppService.mainApp`. The system owns the truth (the user can switch it
/// off in System Settings), so the status is always read back, never stored.
enum LoginItem {
    static let didSetUpKey = "didSetUpLoginItem"
    static let approvalMessage = "Allow CleanUp in System Settings → Login Items"

    private static let log = Logger(subsystem: "io.cleanup.CleanUp", category: "LoginItem")

    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static var needsApproval: Bool { status == .requiresApproval }

    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }

    /// Turns it on the first time the app ever runs, and never again (if the user later turns it off
    /// it stays off). Debug builds run from the build folder, so they don't register themselves.
    static func setUpOnFirstLaunch(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: didSetUpKey) else { return }
        #if DEBUG
        return
        #else
        defaults.set(true, forKey: didSetUpKey)
        do {
            try set(true)
        } catch {
            log.error("Couldn't open at login: \(String(describing: error), privacy: .public)")
        }
        #endif
    }

    /// What to tell the user when the toggle can't do what they asked.
    static func message(for error: any Error) -> String {
        needsApproval ? approvalMessage : error.localizedDescription
    }
}
