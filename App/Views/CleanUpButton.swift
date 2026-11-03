import CleanUpCore
import SwiftUI

/// The Clean up button shared by the window and the menu bar popover: "Clean up 4 idle · frees 3.1
/// cores", or a disabled "Nothing ticked" / "Nothing idle". Stops everything ticked. With nothing
/// ticked during CleanUp's first watch, a line under it says when idle items can show up.
struct CleanUpButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            button
            if model.selection.count == 0, let until = model.snapshot.watchingUntil(now: Date()),
               let hint = WatchingHint.text(until: until, now: Date()) {
                Label(hint, systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .help("CleanUp only calls something idle after watching it for a while")
            }
        }
    }

    private var button: some View {
        let count = model.selection.count
        return Button {
            Task { await model.cleanUp() }
        } label: {
            HStack(spacing: 4) {
                if model.isCleaning {
                    ProgressView().controlSize(.small)
                }
                if count == 0 {
                    // Apps (ticked by hand) can be there with nothing idle: say what's missing.
                    Text(model.hasTickable ? "Nothing ticked" : "Nothing idle")
                } else {
                    Text("Clean up \(count) idle")
                    Text("· frees \(Palette.cores(model.freedCores)) cores").opacity(0.8)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
        .disabled(count == 0 || model.isCleaning || model.cleanIdleInFlight)
    }
}
