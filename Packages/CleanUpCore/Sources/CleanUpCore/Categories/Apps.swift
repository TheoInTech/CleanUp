import AppKit
import Darwin
import Foundation

// MARK: - Activation log

/// When each app was last in front, so "not used 5 h" is knowable. The app feeds it from
/// `NSWorkspace.didActivateApplicationNotification`; it persists across launches in the
/// `io.cleanup` defaults domain.
public actor ActivationLog {
    public static let shared = ActivationLog(suiteName: "io.cleanup")

    private static let activationsKey = "activationLog.lastActivated"
    private static let trackingKey = "activationLog.trackingSince"

    private let defaults: UserDefaults
    private var activations: [String: Double]
    /// When CleanUp first started recording. Apps launched before this and never seen since have an
    /// unknown last use; the fact says "since CleanUp started" rather than guessing.
    public let trackingSince: Date

    init(suiteName: String, now: Date = Date()) {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.defaults = defaults
        activations = defaults.dictionary(forKey: Self.activationsKey) as? [String: Double] ?? [:]
        if let stored = defaults.object(forKey: Self.trackingKey) as? Double {
            trackingSince = Date(timeIntervalSince1970: stored)
        } else {
            trackingSince = now
            defaults.set(now.timeIntervalSince1970, forKey: Self.trackingKey)
        }
    }

    public func record(bundleID: String, at date: Date) {
        let stamp = date.timeIntervalSince1970
        guard stamp > (activations[bundleID] ?? -.infinity) else { return }
        activations[bundleID] = stamp
        defaults.set(activations, forKey: Self.activationsKey)
    }

    public func lastActivated(_ bundleID: String) -> Date? {
        activations[bundleID].map { Date(timeIntervalSince1970: $0) }
    }
}

// MARK: - Running apps

public struct RunningAppInfo: Sendable, Hashable {
    public let bundleID: String
    public let name: String
    public let bundlePath: String
    public let pid: Int32
    public let lastActivated: Date?

    public init(bundleID: String, name: String, bundlePath: String, pid: Int32, lastActivated: Date?) {
        self.bundleID = bundleID
        self.name = name
        self.bundlePath = bundlePath
        self.pid = pid
        self.lastActivated = lastActivated
    }
}

/// What a terminator needs to be sure it is quitting the app that was listed, not a pid's new owner.
public struct AppTerminationRequest: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String
    /// Start time of the listed process, when known.
    public let launchedAt: Date?

    public init(pid: Int32, bundleID: String, launchedAt: Date?) {
        self.pid = pid
        self.bundleID = bundleID
        self.launchedAt = launchedAt
    }
}

public enum AppTerminationOutcome: Sendable, Equatable {
    case quit
    /// Nothing runs under that pid any more.
    case notRunning
    /// The pid now belongs to a different app; it was left alone.
    case mismatch
    case didntQuit
}

public typealias AppTerminator = @Sendable (AppTerminationRequest) async -> AppTerminationOutcome

// MARK: - Module

public struct AppsModule: CategoryModule {
    public var id: CategoryID { .apps }

    /// Never offered, whatever else is true.
    static let neverOffered: Set<String> = ["com.apple.finder", "com.apple.dock", "io.cleanup.CleanUp"]
    /// `launchDate` is set by LaunchServices a moment after the kernel starts the process.
    static let launchDateTolerance: TimeInterval = 30

    private let apps: @Sendable () async -> [RunningAppInfo]
    private let trackingSince: @Sendable () async -> Date
    private let terminator: AppTerminator
    private let opener: @Sendable (URL) async -> Bool

    public init(
        apps: @escaping @Sendable () async -> [RunningAppInfo] = AppsModule.runningApps,
        trackingSince: @escaping @Sendable () async -> Date = { await ActivationLog.shared.trackingSince },
        terminator: @escaping AppTerminator = AppsModule.nativeTerminator(),
        opener: @escaping @Sendable (URL) async -> Bool = AppsModule.nativeOpener
    ) {
        self.apps = apps
        self.trackingSince = trackingSince
        self.terminator = terminator
        self.opener = opener
    }

    // MARK: scan

    public func scan(_ ctx: ScanContext) async -> [Item] {
        let running = await apps()
        let since = await trackingSince()
        var seen = Set<String>()
        var items: [Item] = []
        for app in running where Self.isOffered(app, ctx: ctx) && seen.insert(app.bundleID).inserted {
            items.append(Self.item(for: app, ctx: ctx, trackingSince: since))
        }
        return items.sorted { ($0.name.lowercased(), $0.id.rawValue) < ($1.name.lowercased(), $1.id.rawValue) }
    }

    private static func ownBundleIDs() -> Set<String> {
        var ids = neverOffered
        if let own = Bundle.main.bundleIdentifier { ids.insert(own) }
        return ids
    }

    private static func isOffered(_ app: RunningAppInfo, ctx: ScanContext) -> Bool {
        if ownBundleIDs().contains(app.bundleID) || app.bundleID == ctx.frontmostBundleID { return false }
        if app.pid == ctx.ownPID { return false }
        let executable = ctx.processes[app.pid]?.path ?? ""
        if ProcessSignaler.isProtected(path: app.bundlePath, name: app.name) { return false }
        if !executable.isEmpty, ProcessSignaler.isProtected(path: executable, name: app.name) { return false }
        return true
    }

    private static func item(for app: RunningAppInfo, ctx: ScanContext, trackingSince: Date) -> Item {
        let prefix = app.bundlePath.hasSuffix("/") ? app.bundlePath : app.bundlePath + "/"
        let owned = ctx.processes.values.filter { $0.path.hasPrefix(prefix) }.sorted { $0.pid < $1.pid }
        let launched = ctx.processes[app.pid]?.startTime

        // The later of last-in-front and launch: an activation recorded before a relaunch is stale.
        // Launched before tracking began and never seen in front → unknown.
        let lastUse: Date? = [app.lastActivated, launched.flatMap { $0 > trackingSince ? $0 : nil }]
            .compactMap { $0 }.max()
        let fact: String
        let age: Signal
        if let lastUse {
            let text = RelativeAge.short(ctx.now.timeIntervalSince(lastUse))
            fact = "not used \(text)"
            age = Signal(kind: .idle, text: "Not in front for \(text)")
        } else {
            fact = "not used since CleanUp started"
            age = Signal(kind: .idle, text: "Not seen in front since CleanUp started")
        }

        return Item(
            id: .app(bundleID: app.bundleID),
            category: .apps,
            name: app.name,
            symbol: "app",
            judgement: Judgement(
                verdict: .manual,
                fact: fact,
                signals: [age, Signal(kind: .neutral, text: "Only you can say whether you still need it")]
            ),
            cores: owned.reduce(0.0) { $0 + (ctx.cpu[$1.pid] ?? 0) } / 100,
            memoryBytes: owned.reduce(0) { $0 + $1.residentBytes },
            processes: owned.map(\.ref),
            detail: ["bundleID": app.bundleID, "bundlePath": app.bundlePath, "pid": String(app.pid)]
        )
    }

    // MARK: stop / undo

    public func stop(_ item: Item, ctx: ScanContext) async -> StopResult {
        guard let bundleID = item.detail["bundleID"], let bundlePath = item.detail["bundlePath"],
              let pid = item.detail["pid"].flatMap({ Int32($0) }) else {
            return .failed(reason: "Missing app details")
        }
        if Self.ownBundleIDs().contains(bundleID) || pid == ctx.ownPID
            || ProcessSignaler.isProtected(path: bundlePath, name: item.name) {
            return .skipped(reason: "\(item.name) can't be quit from here")
        }
        if ctx.frontmostBundleID == bundleID { return .skipped(reason: "\(item.name) is in front") }

        let launchedAt = item.processes.first { $0.pid == pid }?.startTime
        switch await terminator(AppTerminationRequest(pid: pid, bundleID: bundleID, launchedAt: launchedAt)) {
        case .quit:
            return .stopped(UndoToken(identity: item.id, action: "open", arguments: [bundlePath]))
        case .notRunning, .mismatch:
            return .skipped(reason: "already gone")
        case .didntQuit:
            return .failed(reason: "didn't quit")
        }
    }

    public func undo(_ token: UndoToken) async -> Bool {
        guard token.action == "open", token.arguments.count == 1, let path = token.arguments.first, !path.isEmpty else {
            return false
        }
        return await opener(URL(fileURLWithPath: path))
    }

    // MARK: system sources

    /// Regular (Dock-visible) apps from `NSWorkspace`, read on the main actor.
    public static func runningApps() async -> [RunningAppInfo] {
        let listed: [(bundleID: String, name: String, path: String, pid: Int32)] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { app in
                guard app.activationPolicy == .regular, !app.isTerminated,
                      let bundleID = app.bundleIdentifier, let path = app.bundleURL?.path else { return nil }
                return (bundleID, app.localizedName ?? (path as NSString).lastPathComponent, path, app.processIdentifier)
            }
        }
        var result: [RunningAppInfo] = []
        for app in listed {
            result.append(RunningAppInfo(
                bundleID: app.bundleID, name: app.name, bundlePath: app.path, pid: app.pid,
                lastActivated: await ActivationLog.shared.lastActivated(app.bundleID)
            ))
        }
        return result
    }

    /// Asks the app to quit (`terminate()`, so it can still prompt to save) after checking the pid
    /// still belongs to the listed app, then waits up to `timeout` for it to go.
    public static func nativeTerminator(timeout: Duration = .seconds(10)) -> AppTerminator {
        { request in
            let started: AppTerminationOutcome? = await MainActor.run {
                guard let app = NSRunningApplication(processIdentifier: request.pid), !app.isTerminated else {
                    return .notRunning
                }
                guard app.bundleIdentifier == request.bundleID else { return .mismatch }
                if let expected = request.launchedAt, let actual = app.launchDate,
                   abs(actual.timeIntervalSince(expected)) > launchDateTolerance {
                    return .mismatch
                }
                return app.terminate() ? nil : .didntQuit
            }
            if let started { return started }

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while clock.now < deadline {
                if await !stillRunning(request) { return .quit }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return await stillRunning(request) ? .didntQuit : .quit
        }
    }

    private static func stillRunning(_ request: AppTerminationRequest) async -> Bool {
        let registered = await MainActor.run {
            guard let app = NSRunningApplication(processIdentifier: request.pid) else { return false }
            return !app.isTerminated && app.bundleIdentifier == request.bundleID
        }
        guard registered else { return false }
        return kill(request.pid, 0) == 0 || errno != ESRCH
    }

    public static func nativeOpener(_ url: URL) async -> Bool {
        do {
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        } catch {
            return false
        }
    }
}
