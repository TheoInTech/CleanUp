import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool

    public init(status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs an external tool with a hard deadline. On timeout the child (and its process group) is
/// SIGKILLed and the call returns promptly with whatever output was captured, so a wedged `docker`
/// or `simctl` can never stall a refresh.
public enum CommandRunner {
    /// GUI apps don't inherit the shell's PATH, so tools like `docker` and `xcrun` are looked up here.
    public static let searchPath: [String] = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        "/usr/bin",
        NSHomeDirectory() + "/.orbstack/bin",
        NSHomeDirectory() + "/.docker/bin",
        "/Applications/Docker.app/Contents/Resources/bin",
    ]

    /// Per-stream capture limit; output beyond this is read and discarded.
    private static let captureLimit = 16 * 1_024 * 1_024

    public static func run(_ launchPath: String, _ args: [String], timeout: Duration = .seconds(20)) async -> CommandResult {
        let deadlineMillis = max(0, Int(timeout.components.seconds) * 1000 + Int(timeout.components.attoseconds / 1_000_000_000_000_000))
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(launchPath, args, timeoutMillis: deadlineMillis))
            }
        }
    }

    // MARK: - Implementation

    private static func resolve(_ launchPath: String) -> String? {
        if launchPath.contains("/") {
            return FileManager.default.isExecutableFile(atPath: launchPath) ? launchPath : nil
        }
        return searchPath
            .map { $0 + "/" + launchPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        let inherited = env["PATH"].map { [$0] } ?? []
        env["PATH"] = (searchPath + inherited).joined(separator: ":")
        return env.map { "\($0.key)=\($0.value)" }
    }

    private static func failure(_ message: String) -> CommandResult {
        CommandResult(status: 127, stdout: "", stderr: message, timedOut: false)
    }

    private static func runBlocking(_ launchPath: String, _ args: [String], timeoutMillis: Int) -> CommandResult {
        guard let executable = resolve(launchPath) else { return failure("executable not found: \(launchPath)") }

        var outPipe: [Int32] = [-1, -1], errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { return failure("pipe failed") }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            return failure("pipe failed")
        }
        for fd in outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group so a timeout can kill grandchildren too.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv = ([executable] + args).map { strdup($0) } + [nil]
        let envp = environment().map { strdup($0) } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let spawnStatus = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(outPipe[1]); close(errPipe[1])
        guard spawnStatus == 0 else {
            close(outPipe[0]); close(errPipe[0])
            return failure("spawn failed (\(spawnStatus)): \(launchPath)")
        }
        defer { close(outPipe[0]); close(errPipe[0]) }
        for fd in [outPipe[0], errPipe[0]] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }

        var out = Capture(), err = Capture()
        var exitStatus: Int32?
        var timedOut = false
        let start = DispatchTime.now().uptimeNanoseconds

        while true {
            var fds: [pollfd] = []
            if !out.closed { fds.append(pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0)) }
            if !err.closed { fds.append(pollfd(fd: errPipe[0], events: Int16(POLLIN), revents: 0)) }

            let elapsed = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            let remaining = timeoutMillis - elapsed
            if remaining <= 0 { timedOut = true; break }

            // Short ticks keep exit detection prompt even if the child closed its pipes early.
            _ = poll(&fds, nfds_t(fds.count), Int32(min(remaining, fds.isEmpty ? 5 : 50)))
            out.drain(outPipe[0], limit: captureLimit)
            err.drain(errPipe[0], limit: captureLimit)

            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid { exitStatus = status; break }
        }

        if timedOut {
            kill(-pid, SIGKILL)
            kill(pid, SIGKILL)
            var status: Int32 = 0
            while waitpid(pid, &status, 0) < 0, errno == EINTR {}
            exitStatus = status
        }
        // Pick up anything the child wrote just before it exited or was killed.
        out.drain(outPipe[0], limit: captureLimit)
        err.drain(errPipe[0], limit: captureLimit)

        return CommandResult(
            status: decode(exitStatus ?? -1),
            stdout: String(decoding: out.data, as: UTF8.self),
            stderr: String(decoding: err.data, as: UTF8.self),
            timedOut: timedOut
        )
    }

    /// `WIFEXITED`/`WEXITSTATUS` are macros; shell convention for signals is 128 + signal.
    private static func decode(_ status: Int32) -> Int32 {
        if status < 0 { return -1 }
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private struct Capture {
        var data = Data()
        var closed = false

        /// Reads whatever is available without blocking; marks EOF.
        mutating func drain(_ fd: Int32, limit: Int) {
            guard !closed else { return }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n > 0 {
                    if data.count < limit { data.append(buffer, count: min(Int(n), limit - data.count)) }
                } else if n == 0 {
                    closed = true
                    return
                } else if errno == EINTR {
                    continue
                } else {
                    return   // EAGAIN: nothing more right now
                }
            }
        }
    }
}
