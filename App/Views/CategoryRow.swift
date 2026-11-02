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
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if category.id == .restart {
                Color.clear.frame(width: 18, height: 18)
            } else {
                Button { model.toggleCategory(category.id) } label: {
                    TickCircle(state: model.selection.state(of: category.id, in: model.snapshot), color: color)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!model.hasIdle(category.id) && model.selection.state(of: category.id, in: model.snapshot) == .none)
                .help("Tick the idle ones")
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
