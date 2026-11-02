import AppKit
import CleanUpCore
import SwiftUI

/// The menu bar item: a tiny ring tinted by mood, plus the minutes left while on battery.
/// MenuBarExtra labels only render images and text, so the ring is drawn into an `NSImage`.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        MenuBarLabelContent(
            mood: model.snapshot.mood,
            load: MenuBarGlyph.load(of: model.snapshot),
            minutes: model.hasScanned ? Self.minutes(in: model.snapshot) : nil
        )
    }

    /// "35m" on battery, nil when plugged in (or the estimate isn't known yet).
    static func minutes(in snapshot: Snapshot) -> String? {
        guard let battery = snapshot.battery, battery.onBattery, let minutes = battery.minutesLeft else { return nil }
        return Palette.minutes(minutes)
    }
}

/// Split from `MenuBarLabel` so the debug renderer can draw it without a model.
struct MenuBarLabelContent: View {
    let mood: Mood
    /// 0...1: how much of the ring is filled.
    let load: Double
    let minutes: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image(mood: mood, load: load))
                .renderingMode(.original)
            if let minutes {
                Text(minutes).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(minutes.map { "CleanUp, \($0) left" } ?? "CleanUp")
    }
}

/// The 14 pt ring: a faint track with an arc in the mood color showing how busy the CPU is.
enum MenuBarGlyph {
    static let size: CGFloat = 14

    /// Share of the CPU in use, so a calm Mac shows a short arc and a drained one a nearly full ring.
    static func load(of snapshot: Snapshot) -> Double {
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        return min(1, max(0, snapshot.coresBusy / cores))
    }

    @MainActor
    static func image(mood: Mood, load: Double) -> NSImage {
        let color = Palette.color(mood)
        let ring = ZStack {
            Circle().stroke(Palette.gray.opacity(0.45), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.12, load))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(1.25)
        .frame(width: size, height: size)

        let renderer = ImageRenderer(content: ring)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        // The ring is colored on purpose: the menu bar must not turn it into a monochrome template.
        image.isTemplate = false
        return image
    }
}
