import Foundation

/// Parent/child walks over a process table snapshot.
enum ProcessTree {
    /// Every descendant of `roots` (the roots themselves excluded).
    static func descendants(of roots: Set<Int32>, in table: [Int32: ProcessInfoRecord]) -> Set<Int32> {
        guard !roots.isEmpty else { return [] }
        var children: [Int32: [Int32]] = [:]
        for process in table.values where process.pid != process.ppid { children[process.ppid, default: []].append(process.pid) }
        var found = Set<Int32>()
        var queue = Array(roots)
        while let pid = queue.popLast() {
            for child in children[pid] ?? [] where found.insert(child).inserted { queue.append(child) }
        }
        return found
    }

    /// CleanUp itself and everything it started (its own `docker`, `xcrun`, `curl` calls).
    static func ownTree(_ ownPID: Int32, in table: [Int32: ProcessInfoRecord]) -> Set<Int32> {
        descendants(of: [ownPID], in: table).union([ownPID])
    }

    /// The executable's file name, falling back to the kernel's process name.
    static func leaf(_ p: ProcessInfoRecord) -> String {
        let leaf = (p.path as NSString).lastPathComponent
        return leaf.isEmpty ? p.name : leaf
    }
}
