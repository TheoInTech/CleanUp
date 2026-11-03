import AppKit
import CleanUpCore
import SwiftUI

/// The main window: ring, mood, Quick select | Choose myself, the category checklist and the
/// Clean up button.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @State private var showsBattery = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 16) {
                    RingView(snapshot: model.snapshot, size: 170)
                        .padding(.top, 4)
                    moodLine
                    ModePicker(mode: Binding(get: { model.mode }, set: { model.mode = $0 }))
                    checklist
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            if let outcome = model.outcome {
                OutcomeCard(outcome: outcome)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(outcome.id)
            }

            CleanUpButton()
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
        }
        .animation(.snappy, value: model.outcome?.id)
        .frame(minWidth: 420, maxWidth: 420, minHeight: 520, idealHeight: 700, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .glassEffect(.regular.interactive(), in: .circle)
            .padding(.trailing, 14)
            .padding(.top, 6)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast) { Task { await model.undoLast() } }
                    .padding(.bottom, 76)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .sheet(item: Binding(get: { model.explaining }, set: { model.explaining = $0 })) { item in
            ExplainSheet(item: item).environment(model)
        }
        .background(WindowVisibility { model.windowVisible = $0 })
        .onAppear {
            model.windowVisible = true
            NSApp.activate()
        }
        .onDisappear { model.windowVisible = false }
    }

    // MARK: Mood

    private var moodLine: some View {
        HStack(spacing: 6) {
            Text(model.snapshot.mood.label)
                .font(.title3.weight(.semibold))
            if let battery = model.snapshot.battery, let health = battery.healthPercent {
                Button { showsBattery.toggle() } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Battery health")
                .accessibilityLabel("Battery health")
                .popover(isPresented: $showsBattery, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(battery.cycleCount.map { "Battery health \(health)% · \($0) cycles" } ?? "Battery health \(health)%")
                        if health >= 80 {
                            Text("It's not your battery.").foregroundStyle(.secondary)
                        }
                    }
                    .padding(14)
                }
            }
        }
    }

    // MARK: Checklist

    @ViewBuilder
    private var checklist: some View {
        if !model.hasScanned {
            ProgressView()
                .controlSize(.small)
                .padding(.top, 24)
        } else if model.snapshot.categories.isEmpty {
            Text("Nothing running in the background.")
                .foregroundStyle(.secondary)
                .padding(.top, 24)
        } else {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    ForEach(model.snapshot.categories, id: \.id) { category in
                        CategoryRow(category: category) { model.explaining = $0 }
                    }
                }
            }
        }
    }
}

/// Quick select | Choose myself, as a glass capsule.
private struct ModePicker: View {
    @Binding var mode: AppModel.Mode
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            segment("Quick select", .quick)
            segment("Choose myself", .manual)
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
    }

    private func segment(_ title: String, _ value: AppModel.Mode) -> some View {
        let selected = mode == value
        return Button {
            withAnimation(.snappy(duration: 0.25)) { mode = value }
        } label: {
            Text(title)
                .font(.callout.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background {
                    if selected {
                        Capsule().fill(Palette.blue).matchedGeometryEffect(id: "pill", in: pill)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
