import AppKit
import CleanUpCore
import SwiftUI

/// The menu bar item: a tiny ring tinted by mood, plus the minutes left while on battery.
/// MenuBarExtra labels only render images and text, so the ring is drawn into an `NSImage`.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabelContent(
            mood: model.snapshot.mood,
            minutes: model.hasScanned ? Self.minutes(in: model.snapshot) : nil
        )
        // The label is the one view that always exists, so it hands the model a way to open the
        // window ("Show me" on the warning notification).
        .onAppear { model.openMainWindow = { openWindow(id: "main") } }
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
    let minutes: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: MenuBarGlyph.image(mood: mood))
                .renderingMode(.original)
            if let minutes {
                Text(minutes).monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(minutes.map { "CleanUp, \($0) left" } ?? "CleanUp")
    }
}

/// The 14 pt ring, a full circle in the mood color. Rendered once per mood and reused, so the label
/// doesn't redraw an image on every 5 s refresh.
@MainActor
enum MenuBarGlyph {
    static let size: CGFloat = 14
    private static var cache: [Mood: NSImage] = [:]

    static func image(mood: Mood) -> NSImage {
        if let cached = cache[mood] { return cached }
        let ring = Circle()
            .strokeBorder(Palette.color(mood), lineWidth: 2.5)
            .padding(0.5)
            .frame(width: size, height: size)

        let renderer = ImageRenderer(content: ring)
        // The menu bar sits on the primary screen; 2x if no screen is reachable.
        renderer.scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        // The ring is colored on purpose: the menu bar must not turn it into a monochrome template.
        image.isTemplate = false
        cache[mood] = image
        return image
    }
}
