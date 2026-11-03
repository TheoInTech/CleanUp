import Darwin
import Foundation

public struct SocketInfo: Sendable, Hashable {
    public enum State: Sendable { case listen, established }

    public let pid: Int32
    public let state: State
    public let localPort: Int
    public let remotePort: Int?
    /// The other end is on this Mac (loopback, or this Mac's own address). Only then can a
    /// connection to a port be one to a local server; a remote host's port 8081 is not ours.
    public let remoteIsLocal: Bool

    public init(pid: Int32, state: State, localPort: Int, remotePort: Int?, remoteIsLocal: Bool = true) {
        self.pid = pid
        self.state = state
        self.localPort = localPort
        self.remotePort = remotePort
        self.remoteIsLocal = remoteIsLocal
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
                result.append(SocketInfo(
                    pid: pid, state: .established, localPort: local, remotePort: remote,
                    remoteIsLocal: isLocalPeer(tcp.tcpsi_ini)
                ))
            default:
                break
            }
        }
        return result
    }

    /// Loopback, or the same address as our own end (a connection to this Mac's LAN address).
    static func isLocalPeer(_ ini: in_sockinfo) -> Bool {
        var local = ini.insi_laddr, remote = ini.insi_faddr
        let same = withUnsafeBytes(of: &local) { l in withUnsafeBytes(of: &remote) { r in l.elementsEqual(r) } }
        if same { return true }
        if ini.insi_vflag & UInt8(INI_IPV4) != 0 {
            return UInt32(bigEndian: ini.insi_faddr.ina_46.i46a_addr4.s_addr) >> 24 == 127
        }
        let bytes = withUnsafeBytes(of: ini.insi_faddr.ina_6) { Array($0) }
        let loopback6 = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
        let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
        return loopback6 || (mapped && bytes[12] == 127)
    }

    /// The kernel stores ports as network-order 16-bit values widened to Int32.
    private static func port(_ raw: Int32) -> Int {
        Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw)))
    }
}
