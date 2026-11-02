import SwiftUI

/// The Clean up button shared by the window and the menu bar popover: "Clean up 4 idle · frees 3.1
/// cores", or a disabled "Nothing idle". Stops everything ticked.
struct CleanUpButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let count = model.selection.count
        Button {
            Task { await model.cleanUp() }
        } label: {
            HStack(spacing: 4) {
                if model.isCleaning {
                    ProgressView().controlSize(.small)
                }
                if count == 0 {
                    Text("Nothing idle")
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
