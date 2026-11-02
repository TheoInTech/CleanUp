import Darwin
import Foundation

/// One row of the process table. Fields we cannot read (other users' processes, races with exit)
/// are empty/zero/nil rather than errors.
public struct ProcessInfoRecord: Sendable, Hashable {
    public let pid: Int32
    public let ppid: Int32
    public let pgid: Int32
    public let uid: uid_t
    public let name: String
    public let path: String
    public let arguments: [String]
    public let cwd: String?
    public let startTime: Date
    public let cpuTimeNanos: UInt64
    public let residentBytes: UInt64
    /// A debugger is attached (`P_TRACED`).
    public let isTraced: Bool

    public var ref: ProcessRef { ProcessRef(pid: pid, startTime: startTime) }

    public init(
        pid: Int32, ppid: Int32, pgid: Int32, uid: uid_t, name: String, path: String,
        arguments: [String], cwd: String?, startTime: Date, cpuTimeNanos: UInt64, residentBytes: UInt64,
        isTraced: Bool = false
    ) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.uid = uid
        self.name = name
        self.path = path
        self.arguments = arguments
        self.cwd = cwd
        self.startTime = startTime
        self.cpuTimeNanos = cpuTimeNanos
        self.residentBytes = residentBytes
        self.isTraced = isTraced
    }
}

/// Reads the process table straight from libproc / sysctl (no `ps`), so a refresh stays cheap
/// even when the machine is badly overloaded.
public enum ProcessTable {
    /// `PROC_PIDPATHINFO_MAXSIZE` (a C macro Swift can't import) is `4 * MAXPATHLEN`.
    private static let pathBufferSize = 4 * Int(MAXPATHLEN)

    /// Every process visible to the current user, keyed by pid. Never throws; processes that can't
    /// be inspected (zombies, other users, exited mid-scan) are skipped or have empty fields.
    public static func snapshot() -> [Int32: ProcessInfoRecord] {
        let pids = listPIDs()
        let timebase = machTimebase()
        let argCapacity = maxArgumentBytes()
        let argBuffer = UnsafeMutableRawPointer.allocate(byteCount: argCapacity, alignment: 16)
        defer { argBuffer.deallocate() }
        let pathBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: pathBufferSize)
        defer { pathBuffer.deallocate() }

        var table: [Int32: ProcessInfoRecord] = [:]
        table.reserveCapacity(pids.count)
        for pid in pids where pid > 0 {
            guard let record = record(
                for: pid, timebase: timebase,
                argBuffer: argBuffer, argCapacity: argCapacity, pathBuffer: pathBuffer
            ) else { continue }
            table[pid] = record
        }
        return table
    }

    // MARK: - Per-process reads

    private static func record(
        for pid: Int32,
        timebase: mach_timebase_info_data_t,
        argBuffer: UnsafeMutableRawPointer,
        argCapacity: Int,
        pathBuffer: UnsafeMutablePointer<CChar>
    ) -> ProcessInfoRecord? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize else { return nil }
        guard bsd.pbi_status != UInt32(SZOMB) else { return nil }

        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        var cpuNanos: UInt64 = 0
        var resident: UInt64 = 0
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize {
            let ticks = task.pti_total_user &+ task.pti_total_system
            cpuNanos = machTicksToNanos(ticks, timebase)
            resident = task.pti_resident_size
        }

        let pathLength = proc_pidpath(pid, pathBuffer, UInt32(pathBufferSize))
        let path = pathLength > 0 ? String(cString: pathBuffer) : ""

        var name = cString(bsd.pbi_name)
        if name.isEmpty { name = cString(bsd.pbi_comm) }
        if name.isEmpty, !path.isEmpty { name = (path as NSString).lastPathComponent }

        let started = TimeInterval(bsd.pbi_start_tvsec) + TimeInterval(bsd.pbi_start_tvusec) / 1_000_000

        return ProcessInfoRecord(
            pid: pid,
            ppid: Int32(bitPattern: bsd.pbi_ppid),
            pgid: Int32(bitPattern: bsd.pbi_pgid),
            uid: bsd.pbi_uid,
            name: name,
            path: path,
            arguments: arguments(for: pid, buffer: argBuffer, capacity: argCapacity),
            cwd: currentDirectory(for: pid),
            startTime: Date(timeIntervalSince1970: started),
            cpuTimeNanos: cpuNanos,
            residentBytes: resident,
            isTraced: bsd.pbi_flags & UInt32(PROC_FLAG_TRACED) != 0
        )
    }

    private static func currentDirectory(for pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let cwd = cString(info.pvi_cdir.vip_path)
        return cwd.isEmpty ? nil : cwd
    }

    /// `KERN_PROCARGS2` layout: `Int32 argc`, exec path, NUL padding, then `argc` NUL-terminated
    /// strings (argv), then the environment (ignored).
    private static func arguments(for pid: Int32, buffer: UnsafeMutableRawPointer, capacity: Int) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = capacity
        guard sysctl(&mib, 3, buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }

        let bytes = UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: size)
        let argc = Int(buffer.loadUnaligned(as: Int32.self))
        var index = MemoryLayout<Int32>.size
        while index < size, bytes[index] != 0 { index += 1 }   // exec path
        while index < size, bytes[index] == 0 { index += 1 }   // padding

        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, bytes[index] != 0 { index += 1 }
            args.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    // MARK: - Helpers

    private static func listPIDs() -> [Int32] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        let capacity = Int(estimate) * 2 + 64   // processes may spawn between the two calls
        var pids = [Int32](repeating: 0, count: capacity)
        let written = pids.withUnsafeMutableBytes {
            proc_listallpids($0.baseAddress, Int32($0.count))
        }
        guard written > 0 else { return [] }
        return Array(pids.prefix(min(Int(written), capacity)))
    }

    private static func maxArgumentBytes() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 1 << 20 }
        return Int(value)
    }

    private static func machTimebase() -> mach_timebase_info_data_t {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        if info.denom == 0 { return mach_timebase_info_data_t(numer: 1, denom: 1) }
        return info
    }

    /// `pti_total_*` are Mach absolute-time ticks on Apple Silicon (1 tick != 1 ns).
    private static func machTicksToNanos(_ ticks: UInt64, _ tb: mach_timebase_info_data_t) -> UInt64 {
        let numer = UInt64(tb.numer), denom = UInt64(tb.denom)
        return (ticks / denom) &* numer &+ (ticks % denom) &* numer / denom
    }

    private static func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
