import CleanUpCore
import SwiftUI

/// One category on glass: header tick, icon, name, "4 of 6 ticked", cores, chevron. Opens into
/// its item rows.
struct CategoryRow: View {
    @Environment(AppModel.self) private var model
    let category: CategorySummary
    let onExplain: (Item) -> Void

    private var color: Color { Palette.color(category.id) }
    private var isExpanded: Bool { model.expanded.contains(category.id) }

    private var subtitle: String {
        if category.id == .restart { return category.items.first?.judgement.fact ?? "" }
        let ticked = category.items.filter(model.isTicked).count
        return "\(ticked) of \(category.items.count) ticked"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(category.items) { item in
                        Divider().padding(.leading, 30)
                        ItemRow(item: item, onExplain: { onExplain(item) })
                    }
                }
                .transition(.itemsReveal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        // Items fade in inside the card as it grows; without the clip they'd draw over the rows above.
        .clipShape(.rect(cornerRadius: 16))
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if category.id == .restart {
                Color.clear.frame(width: 18, height: 18)
            } else {
                let canTickAll = model.hasIdle(category.id) || model.selection.state(of: category.id, in: model.snapshot) != .none
                Button { model.toggleCategory(category.id) } label: {
                    TickCircle(state: model.selection.state(of: category.id, in: model.snapshot), color: color)
                        .opacity(canTickAll ? 1 : 0.4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canTickAll)
                .help(canTickAll ? "Tick the idle ones" : "Nothing idle here: open it to tick items yourself")
                .accessibilityLabel("Tick idle \(Palette.name(category.id))")
                .accessibilityAddTraits(model.selection.state(of: category.id, in: model.snapshot) == .all ? .isSelected : [])
            }

            Button { model.toggleExpanded(category.id) } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: Palette.symbol(category.id), color: color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Palette.name(category.id)).font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if category.cores > 0 {
                        Text(Palette.cores(category.cores))
                            .font(.callout)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Palette.name(category.id)), \(subtitle)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        .padding(.vertical, 8)
    }
}

extension AnyTransition {
    /// A category's items opening: fade in with a short drop, staying inside their card.
    static var itemsReveal: AnyTransition {
        .asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity)
    }
}
