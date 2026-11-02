import Foundation

/// A process pinned by pid and start time, so a recycled pid is never mistaken for the original.
public struct ProcessRef: Codable, Hashable, Sendable {
    public let pid: Int32
    public let startTime: Date

    public init(pid: Int32, startTime: Date) {
        self.pid = pid
        self.startTime = startTime
    }
}
