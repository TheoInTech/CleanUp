import AppIntents
import CleanUpCore
import SwiftUI
import WidgetKit

/// What the widget draws: the app's latest snapshot, or nothing when the app hasn't written one.
struct CleanUpEntry: TimelineEntry {
    let date: Date
    let snapshot: Snapshot?

    /// Snapshots older than this mean the app isn't running; its numbers would be misleading.
    static let staleAfter: TimeInterval = 15 * 60

    /// The snapshot to show, or nil to show "Open CleanUp" instead.
    var fresh: Snapshot? {
        guard let snapshot, date.timeIntervalSince(snapshot.date) <= Self.staleAfter else { return nil }
        return snapshot
    }

    var isCalm: Bool { fresh?.mood == .allGood }
}

// MARK: - Root

struct CleanUpWidgetView: View {
    let entry: CleanUpEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        // Tapping anywhere but the button opens the app (the default for a widget without a URL).
        WidgetContent(entry: entry, family: family)
            .containerBackground(for: .widget) { WidgetBackground(calm: entry.isCalm) }
    }
}

/// Everything but the container background, so a script can render it on its own.
struct WidgetContent: View {
    let entry: CleanUpEntry
    let family: WidgetFamily

    var body: some View {
        if let snapshot = entry.fresh {
            switch family {
            case .systemMedium: MediumWidget(snapshot: snapshot)
            default: SmallWidget(snapshot: snapshot)
            }
        } else {
            OpenCleanUpWidget()
        }
    }
}

/// `.fill.tertiary`, with a green wash when everything is calm.
struct WidgetBackground: View {
    let calm: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.fill.tertiary)
            if calm { Palette.green.opacity(0.18) }
        }
    }
}

// MARK: - Small

struct SmallWidget: View {
    let snapshot: Snapshot

    var body: some View {
        VStack(spacing: 6) {
            WidgetRing(snapshot: snapshot, size: snapshot.idleCount > 0 ? 66 : 84)
            StatusLines(snapshot: snapshot, alignment: .center)
            if snapshot.idleCount > 0 { CleanUpButton() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium

struct MediumWidget: View {
    let snapshot: Snapshot

    /// The three categories using the most CPU; Restart is advice, not work.
    private var top: [CategorySummary] {
        Array(snapshot.categories
            .filter { $0.id != .restart && $0.cores > 0 }
            .sorted { ($0.cores, $1.id.rawValue) > ($1.cores, $0.id.rawValue) }
            .prefix(3))
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 6) {
                WidgetRing(snapshot: snapshot, size: snapshot.idleCount > 0 ? 66 : 84)
                StatusLines(snapshot: snapshot, alignment: .center)
                if snapshot.idleCount > 0 { CleanUpButton() }
            }
            .frame(width: 124)
            VStack(alignment: .leading, spacing: 8) {
                if top.isEmpty {
                    Text("Nothing is using the CPU")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(top, id: \.id) { category in
                        HStack(spacing: 8) {
                            IconTile(symbol: Palette.symbol(category.id), color: Palette.color(category.id), size: 24)
                            Text(Palette.name(category.id))
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text("\(Palette.cores(category.cores)) cores")
                                .font(.callout)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Pieces

/// The ring with the mood emoji in the middle.
private struct WidgetRing: View {
    let snapshot: Snapshot
    let size: CGFloat

    var body: some View {
        RingView(snapshot: snapshot, size: size, showsCenter: false)
            .overlay {
                Text(snapshot.mood.label.prefix(1))
                    .font(.system(size: size * 0.38))
            }
    }
}

/// Busy: "35m left" (or "10.5 cores" when plugged in). Calm: green "All good" over the same line.
private struct StatusLines: View {
    let snapshot: Snapshot
    let alignment: HorizontalAlignment

    private var detail: String {
        if let battery = snapshot.battery, battery.onBattery, let minutes = battery.minutesLeft {
            return "\(Palette.minutes(minutes)) left"   // "35m left", "2h 5m left", as in the menu bar
        }
        return "\(Palette.cores(snapshot.coresBusy)) cores"
    }

    var body: some View {
        VStack(spacing: 1) {
            if snapshot.mood == .allGood {
                Text("All good")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Palette.green)
            }
            Text(detail)
                .font(.system(size: snapshot.mood == .allGood ? 11 : 13, weight: snapshot.mood == .allGood ? .regular : .medium))
                .monospacedDigit()
                .foregroundStyle(snapshot.mood == .allGood ? .secondary : .primary)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

private struct CleanUpButton: View {
    var body: some View {
        Button(intent: CleanUpIdleIntent()) {
            Text("Clean up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(Palette.blue, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The app isn't running (or hasn't written a snapshot): no stale numbers, just a way in.
struct OpenCleanUpWidget: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Open CleanUp")
                .font(.system(size: 14, weight: .semibold))
            Text("Numbers are out of date")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Samples

extension Snapshot {
    private static func sampleItem(_ category: CategoryID, _ name: String, cores: Double) -> Item {
        Item(
            id: .app(bundleID: "sample.\(name)"), category: category, name: name, symbol: Palette.symbol(category),
            judgement: Judgement(verdict: .idle, fact: "Sample", signals: []),
            cores: cores, memoryBytes: 0, processes: [], detail: [:]
        )
    }

    /// What the placeholder shows: a calm Mac, six hours left.
    static func widgetCalmSample(date: Date = .now) -> Snapshot {
        Snapshot(
            date: date,
            battery: BatteryReading(onBattery: true, percent: 82, drainWatts: 5.2, minutesLeft: 370, healthPercent: 93, cycleCount: 221),
            coresBusy: 0.4, swapUsedBytes: 0, swapTotalBytes: 0, uptime: 3_600,
            categories: [
                CategorySummary(id: .apps, items: [sampleItem(.apps, "Safari", cores: 0.2)]),
                CategorySummary(id: .devServers, items: [sampleItem(.devServers, "Dev server", cores: 0.1)]),
            ],
            mood: .allGood
        )
    }

    /// What the widget gallery shows: the day this app was written for.
    static func widgetBusySample(date: Date = .now) -> Snapshot {
        Snapshot(
            date: date,
            battery: BatteryReading(onBattery: true, percent: 64, drainWatts: 38, minutesLeft: 35, healthPercent: 93, cycleCount: 221),
            coresBusy: 10.5, swapUsedBytes: 0, swapTotalBytes: 0, uptime: 3_600,
            categories: [
                CategorySummary(id: .simulators, items: [sampleItem(.simulators, "Simulators", cores: 5.4)]),
                CategorySummary(id: .containers, items: [sampleItem(.containers, "Containers", cores: 1.9)]),
                CategorySummary(id: .devServers, items: [sampleItem(.devServers, "Dev servers", cores: 1.6)]),
            ],
            mood: .drainingFast,
            idleCount: 11, freedCores: 8.0
        )
    }
}
