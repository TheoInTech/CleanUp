import Foundation

/// Plain-words explanations used when the on-device model is off, slow or unavailable.
/// Never says whether something is safe to stop; that is decided elsewhere.
public enum FallbackTexts {
    public static func explanation(for item: Item) -> Explanation {
        let (whatIsIt, whatYouLose) = texts(for: item)
        return Explanation(whatIsIt: whatIsIt, whatYouLose: whatYouLose, byAI: false)
    }

    private static func texts(for item: Item) -> (String, String) {
        switch item.category {
        case .simulators: return simulator(item)
        case .containers: return container(item)
        case .devServers: return devServer(item)
        case .apps:
            return (
                "\(item.name) is open and using power in the background.",
                "Its windows close, and anything you haven't saved in it can be lost."
            )
        case .browserTabs:
            let browser = item.detail["browser"] ?? "your browser"
            return (
                "A web page open in \(browser) that is working hard.",
                "The page reloads when you open it again, and anything typed into it can be lost."
            )
        case .worktrees:
            return (
                "A second checkout of your project that an agent made for one task.",
                "Nothing in git. Files git ignores, like `.env`, go to the Trash with it."
            )
        case .restart:
            return (
                "Your Mac has been on for a while and is using swap, a slow overflow for memory. A restart clears it.",
                "Every open app closes, so save your work first."
            )
        }
    }

    // MARK: simulators

    private static func simulator(_ item: Item) -> (String, String) {
        if item.detail["udid"] == nil {
            return (
                "Background helpers for the iOS Simulator. They start again by themselves when needed.",
                "Nothing you would notice; they come back when you next open a simulator."
            )
        }
        return (
            "A pretend iPhone from Xcode. It keeps running in the background even with its window closed.",
            "Anything open in it closes, and you can start it again from Xcode."
        )
    }

    // MARK: containers

    private static func container(_ item: Item) -> (String, String) {
        if item.id.rawValue.hasPrefix("engine:") {
            return (
                "\(item.name) runs your containers. If it quits, every container on it stops too.",
                "All its containers stop, along with anything that uses them."
            )
        }
        let image = item.detail["image"] ?? ""
        let lose = "Anything that talks to it stops working until it is started again."
        if let known = knownContainer(image) ?? knownContainer(item.name) {
            return (known, lose)
        }
        let host = item.detail["engine"].map { "inside \($0)" } ?? "in the background"
        let what = image.isEmpty ? "" : " (\(image))"
        return ("A small server\(what) running \(host). It keeps running until it is stopped.", lose)
    }

    private static func knownContainer(_ text: String) -> String? {
        let text = text.lowercased()
        if text.contains("postgres") {
            return "A local PostgreSQL database. Apps use it to store their data while you build them."
        }
        if text.contains("redis") {
            return "A local Redis store, a fast scratchpad that apps use to remember things."
        }
        if text.contains("mailpit") {
            return "A pretend email inbox for testing. Emails your app sends while you build it land here."
        }
        return nil
    }

    // MARK: dev servers

    private static func devServer(_ item: Item) -> (String, String) {
        let project = item.detail["project"].flatMap { $0.isEmpty ? nil : $0 } ?? item.name
        let haystack = "\(item.detail["command"] ?? "") \(item.name)".lowercased()
        let what: String
        if hasWord("expo", in: haystack) {
            what = "The Expo server for \(project). It lets a phone or simulator load the app while you work on it."
        } else if hasWord("next", in: haystack) {
            what = "The Next.js server for \(project). It shows the website in your browser while you work on it."
        } else if hasWord("vite", in: haystack) {
            what = "The Vite server for \(project). It shows the app in your browser while you work on it."
        } else {
            what = "A development server for \(project). It serves the app while you work on it."
        }
        return (what, "The app stops loading in your browser or on devices until you start it again.")
    }

    private static func hasWord(_ word: String, in text: String) -> Bool {
        text.range(of: "\\b\(word)\\b", options: .regularExpression) != nil
    }
}
