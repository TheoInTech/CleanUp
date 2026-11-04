#if DEBUG
import AppKit
import CleanUpCore

/// Debug builds only. `-debugWorktreeReport YES` scans for worktrees once, writes a plain-text report
/// to `-debugWorktreeReportPath <file>` (stdout when no path is given) and quits.
/// Strictly read-only: it builds a `WorktreeScanner` and nothing else. No trash, no reconcile, no
/// cleanup, no AppModel, and nothing is written except the report file.
enum DebugWorktreeReport {
    static var requested: Bool { UserDefaults.standard.bool(forKey: "debugWorktreeReport") }

    static func run() {
        Task.detached {
            let text = await report()
            if let path = UserDefaults.standard.string(forKey: "debugWorktreeReportPath") {
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                print(text)
            }
            exit(0)
        }
    }

    private static func report() async -> String {
        let started = Date()
        let snapshot = await WorktreeScanner().scan(
            processes: ProcessTable.snapshot(), ownPID: ProcessInfo.processInfo.processIdentifier,
            includeProtected: false, trashed: [], now: started)
        let seconds = Date().timeIntervalSince(started)
        guard let snapshot else { return "git is not available; nothing scanned" }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func tilde(_ p: String) -> String { p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p }
        func bytes(_ i: Item) -> Int64 { i.detail["bytes"].flatMap { Int64($0) } ?? 0 }

        let items = snapshot.items
        let leftovers = items.first { $0.id == .worktreeLeftovers }
        let leftoverCount = leftovers?.detail["paths"].map { $0.split(separator: "\n").count } ?? 0
        let worktrees = items.filter { $0.id != .worktreeLeftovers }
        let safe = items.filter { $0.judgement.verdict == .idle }

        var reasons: [String: Int] = [:]
        for i in items where i.judgement.verdict != .idle {
            let fact = i.judgement.fact
            let key = ["can't", "uncommitted", "not on", "in use", "changed", "locked", "measuring"]
                .first { fact.contains($0) } ?? "other"
            reasons[key, default: 0] += 1
        }

        var out = [
            "items (worktrees + leftovers entry): \(items.count)",
            "worktrees: \(worktrees.count)",
            "safe items: \(safe.count)",
            "safe: \(Bytes.gb(snapshot.safeBytes)) (\(snapshot.safeBytes) bytes)",
            "kept: \(Bytes.gb(snapshot.keptBytes)) (\(snapshot.keptBytes) bytes)",
            "leftover folders: \(leftoverCount)",
            String(format: "walk seconds: %.1f", seconds),
            "kept reasons: " + reasons.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "),
            "",
        ]
        for i in items {
            let verdict = i.judgement.verdict == .idle ? "safe" : "kept"
            out.append("\(verdict)\t\(Bytes.gb(bytes(i)))\t\(i.judgement.fact)\t\(tilde(i.detail["path"] ?? i.name))")
        }
        return out.joined(separator: "\n") + "\n"
    }
}
#endif
