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
    private var item: Item {
        model.snapshot.item(withID: original.id)
            ?? model.worktrees.snapshot?.items.first { $0.id == original.id }
            ?? original
    }
    private var verdict: Verdict { item.judgement.verdict }
    private var color: Color { Palette.color(item.category) }
    /// Worktrees are removed, not stopped, and only by their own Clean up: no Stop, no "Stop anyway".
    private var isWorktree: Bool { item.category == .worktrees }
    /// A worktree CleanUp would remove: judged safe and not always kept.
    private var worktreeSafe: Bool { model.worktrees.isSafe(item) }
    /// Why a kept worktree stays: its fact, or "always kept" for one on the Keep list.
    private var keptReason: String { verdict == .idle ? "always kept" : item.judgement.fact }

    private var signalsTitle: String {
        if isWorktree { return worktreeSafe ? "Why it's safe to remove" : "Why it's kept" }
        return switch verdict {
        case .idle: "Why we think it's idle"
        case .inUse: "Why we think it's in use"
        case .manual, .check, .advice: "What we see"
        }
    }

    private var safety: (text: String, color: Color) {
        if isWorktree { return worktreeSafe ? ("✓ Safe", Palette.green) : ("⚠︎ Kept", Palette.orange) }
        return switch verdict {
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
                    if isWorktree, let place = worktreePlace {
                        Text(place)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(item.detail["path"] ?? "")
                    }
                }
            }

            section("What is this?") {
                if let explanation {
                    Text(styled(explanation.whatIsIt)).fixedSize(horizontal: false, vertical: true)
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

            section(isWorktree ? "Safe to remove?" : "Safe to stop?") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(safety.text)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(safety.color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(safety.color.opacity(0.16)))
                    if let explanation {
                        Text(loseText(explanation))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if verdict == .check {
                Text(Self.tabAdvice(browser: item.detail["browser"]))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// What removing it would lose, only for a worktree CleanUp would remove; a kept one says why it stays.
    private func loseText(_ explanation: Explanation) -> AttributedString {
        guard isWorktree else { return AttributedString(explanation.whatYouLose) }
        return worktreeSafe
            ? styled(explanation.whatYouLose)
            : AttributedString("CleanUp won't remove it: \(keptReason)")
    }

    /// Worktree texts are fixed and mark file names as code ("like `.env`"); the model's text stays plain.
    private func styled(_ text: String) -> AttributedString {
        guard isWorktree,
              let styled = try? AttributedString(
                markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        return styled
    }

    /// "8.4 GB · ~/Projects/app/.codex/worktrees/feat": its size and where it is.
    private var worktreePlace: String? {
        let size = item.detail["bytes"].flatMap { Int64($0) }.map(Bytes.gb)
        let path = item.detail["path"].map { ($0 as NSString).abbreviatingWithTildeInPath }
        let parts = [size, path].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var buttons: some View {
        HStack(spacing: 10) {
            if isWorktree {
                worktreeButtons
            } else {
                stopButtons
            }
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// Keep (always), and Tick or Untick for one that is safe to remove; a kept one just closes.
    @ViewBuilder
    private var worktreeButtons: some View {
        let worktrees = model.worktrees
        Button {
            model.keep(item)
            worktrees.kept(item)
            dismiss()
        } label: {
            Text("Keep").frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
        if worktreeSafe {
            let ticked = worktrees.isTicked(item)
            Button {
                worktrees.toggle(item)
                dismiss()
            } label: {
                Text(ticked ? "Untick" : "Tick").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(color)
            .disabled(worktrees.isBusy)
        } else {
            Button { dismiss() } label: {
                Text("OK").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
        }
    }

    @ViewBuilder
    private var stopButtons: some View {
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
        case .inUse where item.isEngine:
            // Quitting an engine stops everything in it, so it is never forced: no "Stop anyway".
            VStack(alignment: .trailing, spacing: 8) {
                if item.category == .containers {
                    Text("Stop its containers first")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.keep(item)
                    dismiss()
                } label: {
                    Text("Keep").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
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
                let force = verdict == .inUse
                dismiss()
                Task { await model.stop(target, force: force) }
            } label: {
                Text(verdict == .inUse ? "Stop anyway" : "Stop").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(verdict == .inUse ? Palette.red : nil)
            .disabled(model.isCleaning || model.cleanIdleInFlight)
        }
    }

    /// Chromium browsers have a task manager (Shift+Esc); Safari and Firefox don't show one per tab.
    static func tabAdvice(browser: String?) -> String {
        let chromium: Set<String> = ["Chrome", "Brave", "Edge", "Chromium", "Arc", "Vivaldi", "Opera"]
        if let browser, chromium.contains(browser) {
            return "Open the browser's task manager to close it (Shift+Esc in Chrome, Brave, Edge)."
        }
        return "Close the busy tab in the browser."
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
