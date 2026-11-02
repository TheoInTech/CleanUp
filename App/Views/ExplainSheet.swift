import CleanUpCore
import SwiftUI

/// The "?" sheet: what it is, why we think it's idle or in use, whether it's safe to stop, and
/// Keep / Stop. The verdict comes from the engine; only the plain-words text comes from the explainer.
struct ExplainSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: Item
    @State private var explanation: Explanation?

    init(item: Item) {
        original = item
    }

    /// The latest version of the item, so the verdict stays current while the sheet is open.
    private var item: Item { model.snapshot.item(withID: original.id) ?? original }
    private var verdict: Verdict { item.judgement.verdict }
    private var color: Color { Palette.color(item.category) }

    private var signalsTitle: String {
        switch verdict {
        case .idle: "Why we think it's idle"
        case .inUse: "Why we think it's in use"
        case .manual, .check, .advice: "What we see"
        }
    }

    private var safety: (text: String, color: Color) {
        switch verdict {
        case .idle: ("✓ Safe", Palette.green)
        case .inUse: ("⚠︎ Probably being used", Palette.orange)
        case .manual, .check, .advice: ("Your call", Palette.gray)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: item.symbol, color: color, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.title3.bold()).lineLimit(2)
                    Text("\(Palette.name(item.category)) · \(item.judgement.fact)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            section("What is this?") {
                if let explanation {
                    Text(explanation.whatIsIt).fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            if !item.judgement.signals.isEmpty {
                section(signalsTitle) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(item.judgement.signals.enumerated()), id: \.offset) { _, signal in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "circle.fill")
                                    .font(.system(size: 7))
                                    .foregroundStyle(signalColor(signal.kind))
                                Text(signal.text).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }

            section("Safe to stop?") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(safety.text)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(safety.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(safety.color.opacity(0.16)))
                    if let explanation {
                        Text(explanation.whatYouLose)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if explanation?.byAI == true {
                Text("✨ Explained by Apple Intelligence, on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            buttons
        }
        .padding(20)
        .frame(width: 360)
        .task(id: original.id) {
            explanation = await model.explain(original)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            switch verdict {
            case .advice:
                Button { dismiss() } label: {
                    Text("Not now").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button {
                    dismiss()
                    Task { await model.showRestartDialog() }
                } label: {
                    Text("Restart…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            case .check:
                // CleanUp can't tell which tab it is; the browser's own task manager can close it.
                Button { dismiss() } label: {
                    Text("OK").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
            case .idle, .inUse, .manual:
                Button {
                    model.keep(item)
                    dismiss()
                } label: {
                    Text("Keep").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button {
                    let target = item
                    dismiss()
                    Task { await model.stop(target) }
                } label: {
                    Text(verdict == .inUse ? "Stop anyway" : "Stop").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .tint(verdict == .inUse ? Palette.red : nil)
                .disabled(model.isCleaning)
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func signalColor(_ kind: Signal.Kind) -> Color {
        switch kind {
        case .idle: Palette.green
        case .inUse: Palette.blue
        case .neutral: Palette.gray
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}
