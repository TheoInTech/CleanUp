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
            list
            if let toast = model.toast {
                ToastView(toast: toast) { Task { await model.undoLast() } }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
            CleanUpButton()
            footer
        }
        .animation(.snappy, value: model.toast?.id)
        .padding(14)
        .frame(width: 290)
        .background(WindowVisibility { model.popoverVisible = $0 } onWindow: { panel = $0 })
        .onAppear { model.popoverVisible = true }
        .onDisappear { model.popoverVisible = false }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                NSApp.activate()
                openWindow(id: "main")
                dismissPanel()
            } label: {
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

    /// "≈ 35 min left · 10.5 cores busy" on battery, "10.5 cores busy" otherwise.
    static func statusLine(for snapshot: Snapshot) -> String {
        let busy = "\(Palette.cores(snapshot.coresBusy)) cores busy"
        if let battery = snapshot.battery, battery.onBattery, let minutes = battery.minutesLeft {
            return "≈ \(minutes) min left · \(busy)"
        }
        return busy
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
                    ForEach(topCategories, id: \.id) { PopoverRow(category: $0) }
                }
            }
        }
    }
}

/// One category: tick, icon, name, "4 of 6 ticked", cores.
private struct PopoverRow: View {
    @Environment(AppModel.self) private var model
    let category: CategorySummary

    private var color: Color { Palette.color(category.id) }
    private var state: TickState { model.selection.state(of: category.id, in: model.snapshot) }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.toggleCategory(category.id) } label: {
                TickCircle(state: state, color: color)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!model.hasIdle(category.id) && state == .none)
            .help("Tick the idle ones")
            .accessibilityLabel("Tick idle \(Palette.name(category.id))")
            .accessibilityAddTraits(state == .all ? .isSelected : [])

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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }
}
