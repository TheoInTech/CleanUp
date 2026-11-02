import AppIntents
import CleanUpCore
import Foundation

/// The widget's "Clean up" button. The widget is sandboxed and can't stop anything itself, so it
/// writes a request (the tap's time) into the App Group, then posts the Darwin notification; the
/// running app acts only on a fresh request, scans fresh and stops what Quick select proposes.
struct CleanUpIdleIntent: AppIntent {
    static let title: LocalizedStringResource = "Clean up idle"
    static let description = IntentDescription("Stops the idle simulators, containers and dev servers CleanUp finds.")
    /// Only meant for the widget's button, not Shortcuts or Spotlight.
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        guard let groupID = Bundle.main.object(forInfoDictionaryKey: "CleanUpAppGroup") as? String,
              !groupID.hasPrefix("."), let url = CleanupRequest.url(groupID: groupID) else { return .result() }
        try CleanupRequest.write(at: Date(), to: url)
        CleanupSignal.post()
        return .result()
    }
}
