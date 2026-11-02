import CleanUpCore
import SwiftUI

/// One item inside an opened category: tick, icon, name, one short fact, badge, "?".
/// Advice (Restart) gets a "Restart…" button instead of a tick.
struct ItemRow: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let onExplain: () -> Void

    private var color: Color { Palette.color(item.category) }
    private var verdict: Verdict { item.judgement.verdict }
    private var tickable: Bool { Selection.isTickable(item) }

    var body: some View {
        HStack(spacing: 10) {
            if verdict == .advice || verdict == .check {
                // Advice and busy tabs can't be stopped from here: no tick.
                Color.clear.frame(width: 18, height: 18)
            } else {
                Button { model.toggle(item) } label: {
                    TickCircle(state: model.isTicked(item) ? .all : .none, color: color)
                        .opacity(tickable ? 1 : 0.4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!tickable)
                .accessibilityLabel("Tick \(item.name)")
                .accessibilityAddTraits(model.isTicked(item) ? .isSelected : [])
            }

            IconTile(symbol: item.symbol, color: color, size: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // A short manual fact ("not used 5 h") is the badge itself.
                if !VerdictBadge.factFitsBadge(item), !item.judgement.fact.isEmpty {
                    Text(item.judgement.fact)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if verdict == .advice {
                Button("Restart…") { Task { await model.showRestartDialog() } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            } else {
                VerdictBadge(item: item)
            }

            Button(action: onExplain) {
                Image(systemName: "questionmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(Palette.track))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("What is this?")
            .accessibilityLabel("What is \(item.name)?")
        }
        .padding(.vertical, 7)
    }
}

/// `💤 idle` green, `● in use` blue, the fact in gray for manual items, `check` amber.
private struct VerdictBadge: View {
    let item: Item

    /// "not used 5 h" fits a badge; "not used since CleanUp started" goes on the fact line instead.
    static func factFitsBadge(_ item: Item) -> Bool {
        item.judgement.verdict == .manual && item.judgement.fact.count <= 16
    }

    private var style: (text: String, color: Color) {
        switch item.judgement.verdict {
        case .idle: ("💤 idle", Palette.green)
        case .inUse: ("● in use", Palette.blue)
        case .manual: (Self.factFitsBadge(item) ? item.judgement.fact : "not used", Palette.gray)
        case .check: ("check", Palette.amber)
        case .advice: ("", Palette.gray)
        }
    }

    var body: some View {
        Text(style.text)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(style.color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(style.color.opacity(0.16)))
            .fixedSize()
    }
}
