import Foundation

/// One piece of advice: the Mac has been up long enough, with swap full enough, that a restart is
/// the only real fix. Stopping it shows the normal Restart dialog; the user still decides.
public struct RestartModule: CategoryModule {
    public var id: CategoryID { .restart }

    private let swap: @Sendable () -> (used: UInt64, total: UInt64)
    private let uptime: @Sendable () -> TimeInterval
    /// Shows the Restart dialog. Returns an error message, or nil on success.
    private let restarter: @Sendable () async -> String?

    public init(
        swap: @escaping @Sendable () -> (used: UInt64, total: UInt64) = SystemMemory.swap,
        uptime: @escaping @Sendable () -> TimeInterval = SystemMemory.uptime,
        restarter: @escaping @Sendable () async -> String? = RestartModule.showRestartDialog
    ) {
        self.swap = swap
        self.uptime = uptime
        self.restarter = restarter
    }

    /// Swap is nearly full and large, or the Mac has been up for weeks with swap more than half full.
    public static func shouldAdviseRestart(swapUsed: UInt64, swapTotal: UInt64, uptime: TimeInterval) -> Bool {
        let used = Double(swapUsed), total = Double(swapTotal)
        let nearlyFull = used > 0.75 * total && swapUsed > 8 << 30
        let longUp = uptime > 14 * 86_400 && used > 0.5 * total
        return nearlyFull || longUp
    }

    public func scan(_ ctx: ScanContext) async -> [Item] {
        let (used, total) = swap()
        let up = uptime()
        guard Self.shouldAdviseRestart(swapUsed: used, swapTotal: total, uptime: up) else { return [] }

        let gigabytes = Int((Double(used) / Double(1 << 30)).rounded())
        let upText = RelativeAge.short(up)
        return [Item(
            id: .restart,
            category: .restart,
            name: "Restart your Mac",
            symbol: "restart",
            judgement: Judgement(
                verdict: .advice,
                fact: "swap \(gigabytes) GB · up \(upText)",
                signals: [
                    Signal(kind: .neutral, text: "Using \(gigabytes) GB of swap"),
                    Signal(kind: .neutral, text: "Up for \(upText) without a restart"),
                    Signal(kind: .neutral, text: "A restart clears swap that stopping apps can't"),
                ]
            ),
            cores: 0,
            memoryBytes: 0,
            processes: [],
            detail: ["swapUsed": String(used), "swapTotal": String(total), "uptime": String(Int(up))]
        )]
    }

    public func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult {
        guard item.id == .restart else { return .skipped(reason: "not a restart item") }
        if let error = await restarter() { return .failed(reason: error) }
        return .skipped(reason: "restart dialog shown")
    }

    public func undo(_ token: UndoToken) async -> Bool { false }

    private static let restartTimeout: Duration = .seconds(30)

    /// Asks loginwindow for the standard Restart confirmation through `osascript`, off the main thread
    /// (the first call can wait on the Automation prompt).
    public static func showRestartDialog() async -> String? {
        let result = await CommandRunner.run(
            "/usr/bin/osascript",
            ["-e", #"tell application "loginwindow" to «event aevtrrst»"#],
            timeout: restartTimeout
        )
        if result.timedOut { return "Restart request timed out" }
        guard result.status != 0 else { return nil }
        let line = result.stderr.split(whereSeparator: \.isNewline).first.map(String.init)
        return (line?.isEmpty == false ? line : nil) ?? "Couldn't show the restart dialog"
    }
}
