import AppIntents
import CleanUpCore

/// The widget's "Clean up" button. The widget is sandboxed and can't stop anything itself, so it only
/// posts the Darwin notification; the running app scans fresh and stops what Quick select proposes.
struct CleanUpIdleIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean up idle"
    static let description = IntentDescription("Stops the idle simulators, containers and dev servers CleanUp finds.")
    /// Only meant for the widget's button, not Shortcuts or Spotlight.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        CleanupSignal.post()
        return .result()
    }
}
