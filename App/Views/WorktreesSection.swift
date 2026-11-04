import CleanUpCore
import SwiftUI

/// The Worktrees category in the main window: a row like the others (tick, icon, "N of M ticked",
/// GB instead of cores) that opens into its worktrees, each with a size bar. It has its own Clean up
/// button and result card and never joins the main Clean up. What a cleanup moved to the Trash stays
/// on the row, with Put back and Delete now, until it is deleted or put back.
struct WorktreesSection: View {
    @Environment(AppModel.self) private var model
    let onExplain: (Item) -> Void
    /// The one question asked before anything is deleted for good.
    @State private var confirming: Confirmation?

    enum Confirmation: Equatable {
        /// Clean up with "Remove worktrees permanently" on.
        case cleanUp(count: Int)
        case deleteNow([UUID])

        var count: Int {
            switch self {
            case .cleanUp(let count): count
            case .deleteNow(let ids): ids.count
            }
        }

        var title: String { "Delete \(count == 1 ? "1 worktree" : "\(count) worktrees") permanently?" }
    }

    private var worktrees: WorktreesModel { model.worktrees }

    var body: some View {
        if let snapshot = worktrees.snapshot, !(snapshot.items.isEmpty && snapshot.trashed.isEmpty) {
            GlassEffectContainer(spacing: 8) {
                VStack(spacing: 8) {
                    WorktreesCard(snapshot: snapshot, onExplain: onExplain, confirming: $confirming)
                    if let outcome = worktrees.outcome {
                        WorktreeOutcomeCard(outcome: outcome, confirming: $confirming)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
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
        case .cleanUp: Task { await worktrees.cleanUp() }
        case .deleteNow(let ids): Task { await worktrees.deleteNow(ids) }
        }
    }
}

// MARK: The row

/// The glass card: header, the worktrees when open, the own button, and the "In the Trash" row.
private struct WorktreesCard: View {
    @Environment(AppModel.self) private var model
    let snapshot: WorktreeSnapshot
    let onExplain: (Item) -> Void
    @Binding var confirming: WorktreesSection.Confirmation?

    private var worktrees: WorktreesModel { model.worktrees }
    private var isExpanded: Bool { model.expanded.contains(.worktrees) }
    private var color: Color { Palette.indigo }
    private var subtitle: String { "\(worktrees.tickedItems.count) of \(snapshot.items.count) ticked" }
    /// While the result card offers Undo and Delete now for the last move, the Trash row would repeat it.
    private var showsTrash: Bool {
        guard !snapshot.trashed.isEmpty else { return false }
        if let outcome = worktrees.outcome, !outcome.permanent, !worktrees.lastMoved.isEmpty { return false }
        return true
    }

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
            if showsTrash {
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
            .disabled(!canTickAll)
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
        let count = worktrees.tickedItems.count
        let label = "Clean up \(count == 1 ? "1 worktree" : "\(count) worktrees")"
        let size = Bytes.gb(worktrees.tickedBytes)
        return Button {
            if worktrees.removePermanently {
                confirming = .cleanUp(count: count)
            } else {
                Task { await worktrees.cleanUp() }
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
    private var safe: Bool { item.judgement.verdict == .idle }
    private var tickable: Bool { safe && !model.keepList.contains(item.id) }
    private var ticked: Bool { model.worktrees.isTicked(item) }

    var body: some View {
        HStack(spacing: 10) {
            Button { model.worktrees.toggle(item) } label: {
                TickCircle(state: ticked ? .all : .none, color: color)
                    .opacity(tickable ? 1 : 0.4)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!tickable)
            .help(tickable ? "" : "Kept: \(item.judgement.fact)")
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
                if !item.judgement.fact.isEmpty {
                    Text(item.judgement.fact)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.detail["path"] ?? "")

            // A fixed column, so every size bar ends at the same place.
            Text(Bytes.gb(Self.bytes(item)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)

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
                    Text(trashed.count == 1 ? "1 worktree · not freed yet" : "\(trashed.count) worktrees · not freed yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // Plain text actions: glass buttons on the glass card would stack glass on glass.
                textButton("Put back", color: Palette.blue) { Task { await model.worktrees.putBack(trashed.map(\.id)) } }
                textButton("Delete now", color: Palette.red) { confirming = .deleteNow(trashed.map(\.id)) }
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

// MARK: Result card

/// What the worktrees' own Clean up did: "Moved 3 worktrees to the Trash", each worktree, Undo, and
/// "Delete now · frees 12.5 GB" to free the space for good.
private struct WorktreeOutcomeCard: View {
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
                    Button("Undo") { Task { await worktrees.undoLast() } }
                        .buttonStyle(.glass)
                        .controlSize(.small)
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
                Button { confirming = .deleteNow(worktrees.lastMoved) } label: {
                    Text("Delete now · frees \(Bytes.gb(freed))")
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .tint(Palette.red)
                .controlSize(.large)
                .disabled(worktrees.isBusy)
                .padding(.top, 2)
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
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
