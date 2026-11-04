import CleanUpCore
import SwiftUI

/// The Worktrees category in the main window: a row like the others (tick, icon, "N of M ticked",
/// GB instead of cores) that opens into its worktrees, each with a size bar. It has its own Clean up
/// button and result (inside the same card) and never joins the main Clean up. What a cleanup moved to
/// the Trash stays on the row, under the result, with Put back and Delete now.
struct WorktreesSection: View {
    @Environment(AppModel.self) private var model
    let onExplain: (Item) -> Void
    /// The one question asked before anything is deleted for good.
    @State private var confirming: Confirmation?

    /// What the dialog asks about, captured when the button was pressed: the dialog's count and the
    /// removal both come from this same set, whatever a scan changes meanwhile.
    enum Confirmation: Equatable {
        /// Clean up with "Remove worktrees permanently" on when it was pressed.
        case cleanUp(ids: Set<ItemIdentity>, phrase: String)
        case deleteNow(ids: [UUID], phrase: String)

        var title: String {
            switch self {
            case .cleanUp(_, let phrase), .deleteNow(_, let phrase): "Delete \(phrase) permanently?"
            }
        }
    }

    private var worktrees: WorktreesModel { model.worktrees }

    var body: some View {
        if let snapshot = worktrees.snapshot, !(snapshot.items.isEmpty && snapshot.trashed.isEmpty) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    WorktreesCard(snapshot: snapshot, onExplain: onExplain, confirming: $confirming)
                }
            }
            .animation(.snappy, value: worktrees.outcome)
            .confirmationDialog(
                confirming?.title ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { confirmation in
                Button("Delete", role: .destructive) { perform(confirmation) }
                Button("Cancel", role: .cancel) {}
                    .keyboardShortcut(.defaultAction)
            } message: { _ in
                Text("This can't be undone.")
            }
        }
    }

    private func perform(_ confirmation: Confirmation) {
        switch confirmation {
        case .cleanUp(let ids, _): Task { await worktrees.cleanUp(ids: ids, permanent: true) }
        case .deleteNow(let ids, _): Task { await worktrees.deleteNow(ids) }
        }
    }
}

// MARK: The row

/// The glass card: header, the worktrees when open, the own button, the last result, and the
/// "In the Trash" row. The result opens inside the card, clipped to it, so nothing slides over the rows.
private struct WorktreesCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: WorktreeSnapshot
    let onExplain: (Item) -> Void
    @Binding var confirming: WorktreesSection.Confirmation?

    private var worktrees: WorktreesModel { model.worktrees }
    private var isExpanded: Bool { model.expanded.contains(.worktrees) }
    private var color: Color { Palette.indigo }
    private var subtitle: String { "\(worktrees.tickedItems.count) of \(snapshot.items.count) ticked" }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded, !snapshot.items.isEmpty {
                VStack(spacing: 0) {
                    let largest = snapshot.items.map(WorktreeRow.bytes).max() ?? 0
                    let repeated = Self.repeatedNames(snapshot.items)
                    ForEach(snapshot.items) { item in
                        Divider().padding(.leading, 30)
                        WorktreeRow(item: item, largest: largest, showsRepo: repeated.contains(item.name)) {
                            onExplain(item)
                        }
                    }
                    if !worktrees.tickedItems.isEmpty {
                        cleanUpButton
                            .padding(.top, 6)
                            .padding(.bottom, 8)
                    }
                }
                .transition(.itemsReveal)
            }
            if let outcome = worktrees.outcome {
                VStack(spacing: 0) {
                    Divider().padding(.leading, 30)
                    WorktreeOutcomeView(outcome: outcome, confirming: $confirming)
                        .padding(.vertical, 10)
                }
                .transition(.itemsReveal)
            }
            // Always there while anything is in the Trash, so older entries stay reachable under a result.
            if !snapshot.trashed.isEmpty {
                Divider().padding(.leading, 30)
                TrashRow(trashed: snapshot.trashed, confirming: $confirming)
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
            let state = worktrees.tickState
            let canTickAll = !worktrees.tickableItems.isEmpty
            Button { worktrees.toggleAll() } label: {
                TickCircle(state: state, color: color)
                    .opacity(canTickAll ? 1 : 0.4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canTickAll || worktrees.isBusy)
            .help(canTickAll ? "Tick the ones safe to remove" : "Nothing here is safe to remove")
            .accessibilityLabel("Tick worktrees safe to remove")
            .accessibilityAddTraits(state == .all ? .isSelected : [])

            Button { model.toggleExpanded(.worktrees) } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: Palette.symbol(.worktrees), color: color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(Palette.name(.worktrees)).font(.headline)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(Bytes.gb(snapshot.safeBytes + snapshot.keptBytes))
                        .font(.callout)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(Palette.name(.worktrees)), \(subtitle)")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        .padding(.vertical, 8)
    }

    /// "Clean up 3 worktrees · 14.2 GB": only what is ticked, never the main Clean up's items.
    private var cleanUpButton: some View {
        let phrase = WorktreeCount.phrase(worktrees.tickedItems)
        let label = "Clean up \(phrase)"
        let size = Bytes.gb(worktrees.tickedBytes)
        return Button {
            // What is ticked and how it goes are fixed now; a scan landing later can't add to it.
            let ids = Set(worktrees.tickedItems.map(\.id))
            if worktrees.removePermanently {
                confirming = .cleanUp(ids: ids, phrase: phrase)
            } else {
                Task { await worktrees.cleanUp(ids: ids, permanent: false) }
            }
        } label: {
            HStack(spacing: 4) {
                if worktrees.isBusy {
                    ProgressView().controlSize(.small)
                }
                Text(label)
                Text("· \(size)").opacity(0.8)
            }
            .font(.callout.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
        }
        .buttonStyle(.glassProminent)
        .tint(color)
        .controlSize(.large)
        .disabled(worktrees.isBusy)
        .accessibilityLabel("\(label) · \(size)")
    }

    /// Folder names that appear more than once (the same task name in two repos) also show their repo.
    private static func repeatedNames(_ items: [Item]) -> Set<String> {
        var seen: Set<String> = []
        var repeated: Set<String> = []
        for item in items where !seen.insert(item.name).inserted { repeated.insert(item.name) }
        return repeated
    }
}

/// One worktree: tick (only if safe to remove), icon, folder name, a size bar against the largest
/// worktree, the fact ("merged 6 days ago · Codex" or why it's kept), its size and "?".
private struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let item: Item
    let largest: Int64
    let showsRepo: Bool
    let onExplain: () -> Void

    static func bytes(_ item: Item) -> Int64 { item.detail["bytes"].flatMap { Int64($0) } ?? 0 }

    private var color: Color { Palette.indigo }
    /// Safe to remove, with the Keep list: an always-kept one is kept, gray and dimmed like the others.
    private var safe: Bool { model.worktrees.isSafe(item) }
    private var ticked: Bool { model.worktrees.isTicked(item) }
    /// Kept rows are dimmed like ItemRow's in-use tick; the "?" stays bright so the reason is easy to find.
    private var dim: Double { safe ? 1 : 0.4 }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.worktrees.toggle(item) } label: {
                TickCircle(state: ticked ? .all : .none, color: color)
                    .opacity(dim)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!safe || model.worktrees.isBusy)
            .help(safe ? "" : "Kept: \(keptReason)")
            .accessibilityLabel("Tick \(item.name)")
            .accessibilityAddTraits(ticked ? .isSelected : [])

            IconTile(symbol: item.id == .worktreeLeftovers ? "folder" : item.symbol, color: color, size: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showsRepo, let repo = item.detail["repoName"] {
                        Text("· \(repo)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                .font(.callout)
                SizeBar(bytes: Self.bytes(item), largest: largest, safe: safe)
                    .padding(.vertical, 1)
                if !keptReason.isEmpty {
                    Text(keptReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(dim)
            .help(item.detail["path"] ?? "")

            // A fixed column, so every size bar ends at the same place.
            Text(Bytes.gb(Self.bytes(item)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
                .opacity(dim)

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

    /// The fact, or "always kept" for one on the Keep list that would otherwise be safe.
    private var keptReason: String {
        item.judgement.verdict == .idle && !safe ? "always kept" : item.judgement.fact
    }
}

/// "In the Trash · 3.1 GB": what CleanUp moved there, still taking space, with Put back and Delete now.
private struct TrashRow: View {
    @Environment(AppModel.self) private var model
    let trashed: [TrashedWorktree]
    @Binding var confirming: WorktreesSection.Confirmation?

    private var bytes: Int64 { trashed.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Color.clear.frame(width: 18, height: 18)
                IconTile(symbol: "trash", color: Palette.gray, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("In the Trash · \(Bytes.gb(bytes))")
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(WorktreeCount.phrase(trashed)) · not freed yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Plain text actions: glass buttons on the glass card would stack glass on glass.
                textButton("Put back", color: Palette.blue) { Task { await model.worktrees.putBack(trashed.map(\.id)) } }
                textButton("Delete now", color: Palette.red) {
                    confirming = .deleteNow(ids: trashed.map(\.id), phrase: WorktreeCount.phrase(trashed))
                }
            }
            // What the last put back or delete couldn't do; those entries stay until they can be.
            if let failure = model.worktrees.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Palette.orange)
                    .padding(.leading, 60)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(model.worktrees.isBusy)
        .padding(.vertical, 7)
    }

    private func textButton(_ title: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

// MARK: Result

/// What the worktrees' own Clean up did: "Moved 3 worktrees to the Trash", each worktree, Undo, and
/// "Delete now · frees 12.5 GB" to free the space for good. Drawn inside the Worktrees card.
private struct WorktreeOutcomeView: View {
    @Environment(AppModel.self) private var model
    let outcome: WorktreeOutcome
    @Binding var confirming: WorktreesSection.Confirmation?
    var maxRows = 6

    private var worktrees: WorktreesModel { model.worktrees }
    /// Undo and Delete now act on what the last move put in the Trash, while it is still there.
    private var inTrash: Bool { !outcome.permanent && !worktrees.lastMoved.isEmpty }
    private var freed: Int64 { worktrees.lastMovedBytes > 0 ? worktrees.lastMovedBytes : outcome.bytes }

    private enum Entry: Identifiable {
        case moved(Item)
        case skipped(Item, String)
        var id: ItemIdentity {
            switch self {
            case .moved(let item), .skipped(let item, _): item.id
            }
        }
    }

    private var entries: [Entry] { outcome.moved.map(Entry.moved) + outcome.skipped.map { .skipped($0.0, $0.1) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: outcome.skipped.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(outcome.skipped.isEmpty ? Palette.green : Palette.amber)
                VStack(alignment: .leading, spacing: 1) {
                    Text(outcome.title).font(.headline)
                    if let subtitle = outcome.subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if inTrash {
                    // Plain text, like the Trash row's actions: no glass on the card's glass.
                    Button { Task { await worktrees.undoLast() } } label: {
                        Text("Undo")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Palette.blue)
                            .padding(4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(worktrees.isBusy)
                }
                Button { worktrees.dismissOutcome() } label: {
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
                ForEach(entries.prefix(maxRows)) { entry in
                    EntryRow(entry: entry, permanent: outcome.permanent)
                }
                if entries.count > maxRows {
                    Text("+\(entries.count - maxRows) more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                }
            }

            if inTrash {
                Button {
                    let ids = worktrees.lastMoved
                    let moved = Set(ids)
                    let entries = (worktrees.snapshot?.trashed ?? []).filter { moved.contains($0.id) }
                    confirming = .deleteNow(
                        ids: ids, phrase: entries.isEmpty ? WorktreeCount.phrase(outcome.moved) : WorktreeCount.phrase(entries))
                } label: {
                    Text("Delete now · frees \(Bytes.gb(freed))")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                }
                // Like the "?" sheet's "Stop anyway": prominent and red, and it still asks first.
                .buttonStyle(.glassProminent)
                .tint(Palette.red)
                .controlSize(.large)
                .disabled(worktrees.isBusy)
                .padding(.top, 2)
            }
        }
    }

    /// One worktree: icon, name, and a green "Moved" (or "Removed") or the reason it was kept.
    private struct EntryRow: View {
        let entry: Entry
        let permanent: Bool

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let item: Item = switch entry {
                case .moved(let item), .skipped(let item, _): item
                }
                IconTile(
                    symbol: item.id == .worktreeLeftovers ? "folder" : item.symbol, color: Palette.indigo, size: 20)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                switch entry {
                case .moved:
                    Label(permanent ? "Removed" : "Moved", systemImage: "checkmark")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.green)
                        .fixedSize()
                case .skipped(_, let reason):
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
}
