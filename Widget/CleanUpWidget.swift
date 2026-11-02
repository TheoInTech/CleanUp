import SwiftUI
import WidgetKit

struct PlaceholderEntry: TimelineEntry {
    let date: Date
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

struct CleanUpWidgetView: View {
    var entry: PlaceholderEntry

    var body: some View {
        Text("CleanUp")
    }
}

@main
struct CleanUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "io.cleanup.CleanUp.Widget", provider: PlaceholderProvider()) { entry in
            CleanUpWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("CleanUp")
        .description("Idle background work on this Mac.")
        .supportedFamilies([.systemSmall])
    }
}
