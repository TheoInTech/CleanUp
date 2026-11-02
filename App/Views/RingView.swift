import CleanUpCore
import SwiftUI

/// One colored segment per category, sized by its share of the CPU in use; gray is everything else.
/// The center shows time left on battery, or cores busy when plugged in. Depends only on CleanUpCore
/// so the widget can draw it too.
struct RingView: View {
    let snapshot: Snapshot
    let size: CGFloat
    /// False when the caller puts its own content in the middle (the widget's mood emoji).
    var showsCenter = true

    private struct Segment: Identifiable {
        let id: CategoryID
        let start: Double
        let end: Double
    }

    /// Segments laid end to end from the top, each `cores / max(coresBusy, sum of category cores, 1)`.
    /// The floor of one core keeps a calm Mac mostly gray instead of one category filling the ring.
    private var segments: [Segment] {
        let shown = snapshot.categories.filter { $0.cores > 0 }
        let total = max(snapshot.coresBusy, shown.reduce(0) { $0 + $1.cores }, 1.0)
        guard total > 0 else { return [] }
        var start = 0.0
        return shown.map { category in
            let end = min(1, start + category.cores / total)
            defer { start = end }
            return Segment(id: category.id, start: start, end: end)
        }
    }

    private var lineWidth: CGFloat { max(3, size * 0.11) }

    private var center: (value: String, caption: String) {
        if let battery = snapshot.battery, battery.onBattery, let minutes = battery.minutesLeft {
            return (Palette.minutes(minutes), "left")
        }
        return (Palette.cores(snapshot.coresBusy), "cores busy")
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track, lineWidth: lineWidth)
            ForEach(segments) { segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(Palette.color(segment.id), style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
            }
            if showsCenter, size >= 60 {
                VStack(spacing: 0) {
                    Text(center.value)
                        .font(.system(size: size * 0.2, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(center.caption)
                        .font(.system(size: max(9, size * 0.075)))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
        .animation(.smooth(duration: 0.6), value: snapshot)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(center.value) \(center.caption)")
    }
}
