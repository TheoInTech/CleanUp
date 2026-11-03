import CleanUpCore
import SwiftUI

/// What the last Clean up did: "✓ Stopped 3 · freed 1.2 cores", then each item by name, stopped or
/// left running with the reason, and Undo.
struct OutcomeCard: View {
    @Environment(AppModel.self) private var model
    let outcome: CleanupOutcome
    /// Rows shown before "+N more", so the popover stays short.
    var maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: outcome.allStopped ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(outcome.allStopped ? Palette.green : Palette.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.title).font(.headline)
                    if let subtitle = outcome.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if outcome.canUndo {
                    Button("Undo") { Task { await model.undoLast() } }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                Button { model.dismissOutcome() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Done")
                .accessibilityLabel("Done")
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(outcome.entries.prefix(maxRows)) { entry in
                    EntryRow(entry: entry)
                }
                if outcome.entries.count > maxRows {
                    Text("+\(outcome.entries.count - maxRows) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }
}

/// One item: icon, name, and a green "Stopped" or the reason it is still running.
private struct EntryRow: View {
    let entry: CleanupOutcome.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            IconTile(symbol: entry.symbol, color: Palette.color(entry.category), size: 20)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            Text(entry.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            switch entry.result {
            case .stopped:
                Label("Stopped", systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.green)
                    .fixedSize()
            case .notStopped(let reason):
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
