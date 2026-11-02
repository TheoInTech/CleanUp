import CleanUpCore
import SwiftUI
import WidgetKit

struct CleanUpProvider: TimelineProvider {
    /// How often the widget re-reads the snapshot on its own; the app also asks for a reload whenever
    /// the mood or the idle count changes.
    static let refreshInterval: TimeInterval = 5 * 60

    func placeholder(in context: Context) -> CleanUpEntry {
        CleanUpEntry(date: .now, snapshot: .widgetCalmSample())
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (CleanUpEntry) -> Void) {
        let now = Date.now
        completion(CleanUpEntry(date: now, snapshot: context.isPreview ? .widgetBusySample(date: now) : Self.load()))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<CleanUpEntry>) -> Void) {
        let now = Date.now
        let snapshot = Self.load()
        var entries = [CleanUpEntry(date: now, snapshot: snapshot)]
        // Flip to "Open CleanUp" on time even if the app never wakes the widget again.
        if let snapshot, now.timeIntervalSince(snapshot.date) <= CleanUpEntry.staleAfter {
            entries.append(CleanUpEntry(date: snapshot.date.addingTimeInterval(CleanUpEntry.staleAfter + 1), snapshot: snapshot))
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(Self.refreshInterval))))
    }

    /// The app's latest snapshot from the App Group container; nil when there is none yet.
    private static func load() -> Snapshot? {
        guard let groupID = Bundle.main.object(forInfoDictionaryKey: "CleanUpAppGroup") as? String,
              !groupID.hasPrefix(".") else { return nil }
        return SnapshotStore.read(groupID: groupID)
    }
}

@main
struct CleanUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.cleanup.CleanUp.Widget", provider: CleanUpProvider()) { entry in
            CleanUpWidgetView(entry: entry)
        }
        .configurationDisplayName("CleanUp")
        .description("What is draining the battery, and a button to stop the idle culprits.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
