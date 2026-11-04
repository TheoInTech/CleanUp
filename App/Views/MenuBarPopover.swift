import AppKit
import CleanUpCore
import SwiftUI

/// The menu bar popover: mini ring and status, the three biggest categories with their ticks, the
/// Clean up button and "Open full view". Does the whole job without the main window.
struct MenuBarPopover: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// The popover's own panel, so it can be dismissed explicitly.
    @State private var panel: NSWindow?
    /// The one category opened into its items (one at a time keeps the popover short).
    @State private var opened: CategoryID?

    init(opened: CategoryID? = nil) {
        _opened = State(initialValue: opened)
    }

    /// The three categories using the most CPU (ties broken by id so rows never swap places).
    /// Restart is advice, not something to tick.
    private var topCategories: [CategorySummary] {
        Array(model.snapshot.categories
            .filter { $0.id != .restart }
            .sorted { ($0.cores, $1.id.rawValue) > ($1.cores, $0.id.rawValue) }
            .prefix(3))
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            worktreesLine
            list
            if let outcome = model.outcome {
                OutcomeCard(outcome: outcome, maxRows: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(outcome.id)
            } else if let toast = model.toast {
                ToastView(toast: toast) { Task { await model.undoLast() } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
            CleanUpButton()
            footer
        }
        .animation(.snappy, value: model.toast?.id)
        .animation(.snappy, value: model.outcome?.id)
        .padding(14)
        .frame(width: 330)
        .background(WindowVisibility { model.popoverVisible = $0 } onWindow: { panel = $0 })
        // A MenuBarExtra builds its content at launch, before the panel is shown: trust the panel.
        .onAppear { model.popoverVisible = panel?.isVisible ?? false }
        .onDisappear { model.popoverVisible = false }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openFullView() } label: {
                Text("Open full view")
                    .font(.callout)
                    .foregroundStyle(Palette.blue)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer(minLength: 0)
            #if DEBUG
            iconButton("bell.badge", label: "Simulate drain warning", help: "Simulate drain warning") {
                model.simulateDrainWarning()
            }
            #endif
            iconButton("gearshape", label: "Settings", help: "Settings") {
                NSApp.activate()
                openSettings()
                dismissPanel()
            }
            iconButton("power", label: "Quit CleanUp", help: "Quit CleanUp") {
                NSApp.terminate(nil)
            }
        }
    }

    private func iconButton(_ symbol: String, label: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .glassEffect(.regular.interactive(), in: .circle)
        .help(help)
        .accessibilityLabel(label)
    }

    /// Opens the main window, optionally with an item's "?" sheet, and closes the popover.
    private func openFullView(explaining item: Item? = nil) {
        NSApp.activate()
        openWindow(id: "main")
        if let item { model.explaining = item }
        dismissPanel()
    }

    /// Closes the popover if it is still the key window (opening another window normally dismisses it).
    private func dismissPanel() {
        DispatchQueue.main.async {
            if let panel, panel.isKeyWindow { panel.close() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            RingView(snapshot: model.snapshot, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.snapshot.mood.label)
                    .font(.headline)
                Text(Self.statusLine(for: model.snapshot))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
    }

    /// "≈ 35m left · 10.5 cores busy" on battery (written like the menu bar's "2h 5m"), "10.5 cores busy" otherwise.
    static func statusLine(for snapshot: Snapshot) -> String {
        let busy = "\(Palette.cores(snapshot.coresBusy)) cores busy"
        if let battery = snapshot.battery, battery.onBattery, let minutes = battery.minutesLeft {
            return "≈ \(Palette.minutes(minutes)) left · \(busy)"
        }
        return busy
    }

    // MARK: Worktrees

    /// The storage bar as one compact line; it opens the window on the Worktrees row, where they are
    /// cleaned up (never from here, the widget or a notification).
    @ViewBuilder
    private var worktreesLine: some View {
        if let worktrees = model.worktrees.snapshot, !(worktrees.items.isEmpty && worktrees.trashed.isEmpty) {
            Button {
                model.expanded.insert(.worktrees)
                model.worktrees.reveal()
                openFullView()
            } label: {
                HStack(spacing: 6) {
                    StorageBar(
                        safe: model.worktrees.safeBytes, kept: model.worktrees.keptBytes, trashed: worktrees.trashedBytes,
                        compact: true)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show worktrees")
            .accessibilityHint("Opens the full view on the worktrees")
        }
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if !model.hasScanned {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else if topCategories.isEmpty {
            Text("Nothing running in the background.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 60)
        } else {
            GlassEffectContainer(spacing: 6) {
                VStack(spacing: 6) {
                    ForEach(topCategories, id: \.id) { category in
                        PopoverRow(
                            category: category,
                            isOpen: Binding(
                                get: { opened == category.id },
                                set: { open in withAnimation(.snappy(duration: 0.25)) { opened = open ? category.id : nil } }
                            ),
                            onExplain: { openFullView(explaining: $0) },
                            onMore: { openFullView() }
                        )
                    }
                }
            }
        }
    }
}

/// One category: tick, icon, name, "4 of 6 ticked", cores, chevron. Opens into its items, each
/// tickable on its own (apps are only ever ticked this way).
private struct PopoverRow: View {
    @Environment(AppModel.self) private var model
    let category: CategorySummary
    @Binding var isOpen: Bool
    let onExplain: (Item) -> Void
    let onMore: () -> Void

    /// Items shown when open before "+N more"; the full list is in the main window.
    private static let maxItems = 6

    private var color: Color { Palette.color(category.id) }
    private var state: TickState { model.selection.state(of: category.id, in: model.snapshot) }
    private var canTickAll: Bool { model.hasIdle(category.id) || state != .none }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isOpen {
                VStack(spacing: 0) {
                    ForEach(category.items.prefix(Self.maxItems)) { item in
                        Divider().padding(.leading, 28)
                        ItemRow(item: item, onExplain: { onExplain(item) })
                    }
                    if category.items.count > Self.maxItems {
                        Divider().padding(.leading, 28)
                        Button(action: onMore) {
                            Text("+\(category.items.count - Self.maxItems) more in full view")
                                .font(.caption)
                                .foregroundStyle(Palette.blue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 28)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.itemsReveal)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .clipShape(.rect(cornerRadius: 12))
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { model.toggleCategory(category.id) } label: {
                TickCircle(state: state, color: color)
                    .opacity(canTickAll ? 1 : 0.4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canTickAll)
            .help(canTickAll ? "Tick the idle ones" : "Nothing idle here: open it to tick items yourself")
            .accessibilityLabel("Tick idle \(Palette.name(category.id))")
            .accessibilityAddTraits(state == .all ? .isSelected : [])

            Button { isOpen.toggle() } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: Palette.symbol(category.id), color: color, size: 24)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Palette.name(category.id)).font(.callout.weight(.semibold))
                        Text("\(category.items.filter(model.isTicked).count) of \(category.items.count) ticked")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(Palette.cores(category.cores))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Palette.name(category.id)), \(category.items.filter(model.isTicked).count) of \(category.items.count) ticked")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
        }
        .padding(.vertical, 7)
    }
}
