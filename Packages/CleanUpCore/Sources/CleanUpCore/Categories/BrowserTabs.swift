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
    static let firefoxNames: Set<String> = ["plugin-container", "Web Content"]

    public init() {}

    public func scan(_ ctx: ScanContext) async -> [Item] {
        var items: [Item] = []
        for process in ctx.processes.values.sorted(by: { $0.pid < $1.pid }) where process.uid == getuid() {
            guard let cpu = ctx.cpu[process.pid], cpu > Self.busyThreshold,
                  let browser = Self.browserName(for: process) else { continue }
            let cores = cpu / 100
            let usage = String(format: "%.1f", cores)
            items.append(Item(
                id: .browserTab(pid: process.pid),
                category: .browserTabs,
                name: "\(browser) tab",
                symbol: "globe",
                judgement: Judgement(
                    verdict: .check,
                    fact: "using \(usage) cores",
                    signals: [
                        Signal(kind: .neutral, text: "A page in \(browser) is using \(usage) cores"),
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

    /// The browser a renderer process belongs to, or nil if it isn't a page renderer.
    /// Matched on both the kernel name (can be truncated) and the executable's file name.
    static func browserName(for process: ProcessInfoRecord) -> String? {
        let leaf = (process.path as NSString).lastPathComponent
        let names = [leaf, process.name]

        if let match = names.first(where: { $0.hasSuffix(chromiumSuffix) }) {
            return chromiumDisplayName(String(match.dropLast(chromiumSuffix.count)))
        }
        if names.contains(webKitContent) { return "Safari" }
        if names.contains(where: { firefoxNames.contains($0) }) { return firefoxDisplayName(path: process.path) }
        return nil
    }

    private static func chromiumDisplayName(_ product: String) -> String {
        switch product {
        case "Brave Browser": return "Brave"
        case "Google Chrome": return "Chrome"
        case "Microsoft Edge": return "Edge"
        default: return product.hasSuffix(" Browser") ? String(product.dropLast(" Browser".count)) : product
        }
    }

    /// "Firefox", "Firefox Nightly", …: the outermost `.app` in the path.
    private static func firefoxDisplayName(path: String) -> String {
        if let bundle = path.split(separator: "/").first(where: { $0.hasSuffix(".app") }) {
            return String(bundle.dropLast(".app".count))
        }
        return "Firefox"
    }

    public func stop(_ item: Item, ctx: ScanContext) async -> StopResult {
        .skipped(reason: "open the browser's task manager")
    }

    public func undo(_ token: UndoToken) async -> Bool { false }
}
