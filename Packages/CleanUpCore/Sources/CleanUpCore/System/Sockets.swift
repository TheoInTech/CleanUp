import Darwin
import Foundation

public struct SocketInfo: Sendable, Hashable {
    public enum State: Sendable { case listen, established }

    public let pid: Int32
    public let state: State
    public let localPort: Int
    public let remotePort: Int?

    public init(pid: Int32, state: State, localPort: Int, remotePort: Int?) {
        self.pid = pid
        self.state = state
        self.localPort = localPort
        self.remotePort = remotePort
    }
}

public enum Sockets {
    /// TCP sockets in LISTEN or ESTABLISHED state owned by the given pids. Pids we can't inspect
    /// (other users, exited) contribute nothing.
    public static func tcp(for pids: [Int32]) -> [SocketInfo] {
        var found: [SocketInfo] = []
        for pid in pids where pid > 0 {
            found.append(contentsOf: tcpSockets(of: pid))
        }
        return found
    }

    private static func tcpSockets(of pid: Int32) -> [SocketInfo] {
        let entrySize = MemoryLayout<proc_fdinfo>.size
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }

        // Leave headroom: descriptors may be opened between the two calls.
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / entrySize + 16)
        let got = fds.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        guard got > 0 else { return [] }

        var result: [SocketInfo] = []
        for fd in fds.prefix(Int(got) / entrySize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }

            let tcp = info.psi.soi_proto.pri_tcp
            let local = port(tcp.tcpsi_ini.insi_lport)
            let remote = port(tcp.tcpsi_ini.insi_fport)
            switch tcp.tcpsi_state {
            case TSI_S_LISTEN:
                result.append(SocketInfo(pid: pid, state: .listen, localPort: local, remotePort: nil))
            case TSI_S_ESTABLISHED:
                result.append(SocketInfo(pid: pid, state: .established, localPort: local, remotePort: remote))
            default:
                break
            }
        }
        return result
    }

    /// The kernel stores ports as network-order 16-bit values widened to Int32.
    private static func port(_ raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }
}
