import Foundation

/// Runaway browser tabs. CleanUp can see which renderer process is burning CPU but not which page it
/// is, and killing a renderer would lose that page's state, so these are listed for the user to
/// close from the browser's own task manager. Never stoppable from here.
public struct BrowserTabsModule: CategoryModule {
    public var id: CategoryID { .browserTabs }

    /// A renderer above this much CPU (percent of one core) is worth a look.
    static let busyThreshold = 50.0
    static let chromiumSuffix = " Helper (Renderer)"
    static let webKitContent = "com.apple.WebKit.WebContent"
    /// The WebKit XPC service is shared by Safari and every app with a web view; the host isn't visible.
    static let webKitName = "Web page (WebKit)"
    static let firefoxNames: Set<String> = ["plugin-container", "Web Content"]

    public init() {}

    /// The process is listed as a tab item of its own: one of our renderers above the threshold.
    static func isListed(_ process: ProcessInfoRecord, cpu: [Int32: Double]) -> Bool {
        guard process.uid == getuid(), let usage = cpu[process.pid], usage > busyThreshold else { return false }
        return browserName(for: process) != nil
    }

    public func scan(_ ctx: ScanContext) async -> [Item] {
        var items: [Item] = []
        for process in ctx.processes.values.sorted(by: { $0.pid < $1.pid }) where Self.isListed(process, cpu: ctx.cpu) {
            guard let cpu = ctx.cpu[process.pid], let browser = Self.browserName(for: process) else { continue }
            let cores = cpu / 100
            let usage = String(format: "%.1f", cores)
            let isWebKit = browser == Self.webKitName
            items.append(Item(
                id: .browserTab(pid: process.pid),
                category: .browserTabs,
                name: isWebKit ? browser : "\(browser) tab",
                symbol: "globe",
                judgement: Judgement(
                    verdict: .check,
                    fact: "using \(usage) cores",
                    signals: [
                        Signal(kind: .neutral, text: isWebKit
                            ? "A WebKit page, possibly from another app"
                            : "A page in \(browser) is using \(usage) cores"),
                        Signal(kind: .neutral, text: "CleanUp can't tell which tab it is"),
                    ]
                ),
                cores: cores,
                memoryBytes: process.residentBytes,
                processes: [process.ref],
                detail: ["browser": browser, "process": process.name]
            ))
        }
        return items
    }

    /// Chromium-family browsers we recognise: helper product name -> (display name, app bundle name).
    /// Anything else with a "Helper (Renderer)" (Slack, VS Code, Discord, ...) is an Electron app, not a browser.
    private static let chromiumBrowsers: [String: (display: String, bundle: String)] = [
        "Brave Browser": ("Brave", "Brave Browser"),
        "Google Chrome": ("Chrome", "Google Chrome"),
        "Chromium": ("Chromium", "Chromium"),
        "Microsoft Edge": ("Edge", "Microsoft Edge"),
        "Arc": ("Arc", "Arc"),
        "Vivaldi": ("Vivaldi", "Vivaldi"),
        "Opera": ("Opera", "Opera"),
    ]

    /// The browser a renderer process belongs to, or nil if it isn't a page renderer of a known browser.
    /// Matched on both the kernel name (can be truncated) and the executable's file name; Chromium
    /// renderers must also sit inside their browser's own `.app`.
    static func browserName(for process: ProcessInfoRecord) -> String? {
        let leaf = (process.path as NSString).lastPathComponent
        let names = [leaf, process.name]

        if let match = names.first(where: { $0.hasSuffix(chromiumSuffix) }) {
            let product = String(match.dropLast(chromiumSuffix.count))
            guard let browser = chromiumBrowsers[product],
                  process.path.contains("/\(browser.bundle).app/") else { return nil }
            return browser.display
        }
        if names.contains(webKitContent) { return webKitName }
        if names.contains(where: { firefoxNames.contains($0) }), process.path.contains("irefox") {
            return firefoxDisplayName(path: process.path)
        }
        return nil
    }

    /// "Firefox", "Firefox Nightly", ...: the outermost `.app` in the path.
    private static func firefoxDisplayName(path: String) -> String {
        if let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(".app".count))
        }
        return "Firefox"
    }

    public func stop(_ item: Item, ctx: ScanContext, force: Bool) async -> StopResult {
        .skipped(reason: "open the browser's task manager")
    }

    public func undo(_ token: UndoToken) async -> Bool { false }
}
