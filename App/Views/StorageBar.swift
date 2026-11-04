import CleanUpCore
import SwiftUI

/// How much disk the worktrees take, as one bar: green is safe to remove, gray is kept, striped green
/// is in the Trash from a cleanup. Its full width is all of it. The caption says the same in words:
/// "14.2 GB safe to remove · 8.2 GB kept". `compact` is the popover's version: a short bar beside the
/// caption, or the bar over it when the caption (with "in the Trash") is too long for one line.
struct StorageBar: View {
    let safe: Int64
    let kept: Int64
    let trashed: Int64
    var compact = false

    private var caption: String { WorktreeStorageCaption.text(safe: safe, kept: kept, trashed: trashed) }

    var body: some View {
        Group {
            if compact {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        bar.frame(width: 64, height: 6)
                        captionText.fixedSize()
                        Spacer(minLength: 0)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        bar.frame(height: 6)
                        captionText.minimumScaleFactor(0.85)
                    }
                }
            } else {
                VStack(spacing: 6) {
                    bar.frame(height: 8)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    private var captionText: some View {
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var bar: some View {
        GeometryReader { geo in
            let widths = Self.widths([safe, kept, trashed], in: geo.size.width, gap: Self.gap)
            HStack(spacing: Self.gap) {
                if widths[0] > 0 { Rectangle().fill(Palette.green).frame(width: widths[0]) }
                if widths[1] > 0 { Rectangle().fill(Palette.keptFill).frame(width: widths[1]) }
                if widths[2] > 0 { StripedFill(color: Palette.green).frame(width: widths[2]) }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background(Palette.track)
            .clipShape(Capsule())
        }
        .animation(.snappy(duration: 0.35), value: [safe, kept, trashed])
    }

    private static let gap: CGFloat = 1.5
    /// A part this small still shows as a sliver, so "<0.1 GB kept" is never invisible.
    private static let minimumWidth: CGFloat = 3

    /// Each part's share of `width`, after the gaps between the parts that are there.
    static func widths(_ parts: [Int64], in width: CGFloat, gap: CGFloat) -> [CGFloat] {
        let present = parts.filter { $0 > 0 }.count
        let total = parts.reduce(0) { $0 + max(0, $1) }
        guard total > 0, width > 0 else { return parts.map { _ in 0 } }
        let available = max(0, width - gap * CGFloat(max(0, present - 1)))
        var widths = parts.map { $0 > 0 ? max(minimumWidth, available * CGFloat($0) / CGFloat(total)) : 0 }
        // Slivers borrow from the largest part so the bar never overflows.
        let overflow = widths.reduce(0, +) - available
        if overflow > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] = max(minimumWidth, widths[largest] - overflow)
        }
        return widths
    }
}

/// One worktree's size against the largest one: green if it is safe to remove, gray if kept.
struct SizeBar: View {
    let bytes: Int64
    let largest: Int64
    let safe: Bool

    var body: some View {
        GeometryReader { geo in
            let fraction = largest > 0 ? min(1, CGFloat(max(0, bytes)) / CGFloat(largest)) : 0
            Capsule()
                .fill(safe ? Palette.green : Palette.keptFill)
                .frame(width: bytes > 0 ? max(4, geo.size.width * fraction) : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(Palette.track))
        }
        .frame(height: 4)
        .animation(.snappy(duration: 0.35), value: bytes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Bytes.gb(bytes))
    }
}

/// Diagonal stripes in `color` over a pale wash of it: what is in the Trash, not yet freed.
struct StripedFill: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.3)))
            var stripes = Path()
            let step: CGFloat = 5
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(stripes, with: .color(color), lineWidth: 1.8)
        }
    }
}

extension Palette {
    /// Kept worktrees, in the storage and size bars.
    static let keptFill = gray.opacity(0.55)
    /// The Worktrees category's own colour.
    static let indigo = color(.worktrees)
}
