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

    public func stop(_ item: Item, ctx: ScanContext) async -> StopResult {
        guard item.id == .restart else { return .skipped(reason: "not a restart item") }
        if let error = await restarter() { return .failed(reason: error) }
        return .skipped(reason: "restart dialog shown")
    }

    public func undo(_ token: UndoToken) async -> Bool { false }

    /// Asks loginwindow for the standard Restart confirmation. AppleScript must run on the main thread.
    @MainActor
    public static func showRestartDialog() -> String? {
        var error: NSDictionary?
        let script = NSAppleScript(source: #"tell application "loginwindow" to «event aevtrrst»"#)
        script?.executeAndReturnError(&error)
        guard script != nil else { return "Couldn't prepare the restart request" }
        guard let error else { return nil }
        return (error[NSAppleScript.errorMessage] as? String) ?? "Couldn't show the restart dialog"
    }
}
