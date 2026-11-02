import SwiftUI

/// A short message after an action: "Stopped 3 · Undo", "Always kept".
struct ToastState: Equatable, Identifiable {
    let id = UUID()
    /// Segments joined with " · ", e.g. ["Stopped 3", "Couldn't stop 1"].
    let parts: [String]
    /// Shows a trailing "Undo" button.
    let canUndo: Bool

    init(_ parts: String..., canUndo: Bool = false) {
        self.parts = parts
        self.canUndo = canUndo
    }

    init(parts: [String], canUndo: Bool) {
        self.parts = parts
        self.canUndo = canUndo
    }
}

struct ToastView: View {
    let toast: ToastState
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(toast.parts.joined(separator: " · "))
            if toast.canUndo {
                Text("·").foregroundStyle(.secondary)
                Button("Undo", action: onUndo)
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.blue)
                    .fontWeight(.semibold)
            }
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: .capsule)
    }
}
