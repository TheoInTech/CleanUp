import Foundation
import FoundationModels
import os

public struct Explanation: Codable, Hashable, Sendable {
    public let whatIsIt: String
    public let whatYouLose: String
    /// True when the on-device model wrote it, false for the built-in text.
    public let byAI: Bool

    public init(whatIsIt: String, whatYouLose: String, byAI: Bool) {
        self.whatIsIt = whatIsIt
        self.whatYouLose = whatYouLose
        self.byAI = byAI
    }
}

@Generable
struct GeneratedExplanation {
    @Guide(description: "What this is, max 2 short sentences")
    var whatIsIt: String
    @Guide(description: "What stops working if it is stopped, one short sentence")
    var whatYouLose: String
}

/// Writes the "What is this?" / "what you'd lose" text for an item. Uses the on-device model when it is
/// available; any error, odd answer or timeout gives the built-in text instead. Nothing leaves the Mac.
public actor Explainer {
    typealias Generate = @Sendable (Item) async throws -> (whatIsIt: String, whatYouLose: String)

    static let defaultTimeout: Duration = .seconds(8)
    static let instructions = "You explain Mac background processes to non-technical people in plain words. At most 2 short sentences. Never say whether it is safe; that is decided elsewhere."

    private let useAI: Bool
    private let timeout: Duration
    private let generate: Generate
    /// Only model answers are cached, so a fallback never sticks once the model works again.
    private var cache: [ItemIdentity: Explanation] = [:]

    public init(useAI: Bool = true) {
        self.init(useAI: useAI, timeout: Self.defaultTimeout, generate: Self.generateWithModel)
    }

    init(useAI: Bool, timeout: Duration = Explainer.defaultTimeout, generate: @escaping Generate) {
        self.useAI = useAI
        self.timeout = timeout
        self.generate = generate
    }

    public func explain(_ item: Item) async -> Explanation {
        guard useAI else { return FallbackTexts.explanation(for: item) }
        if let cached = cache[item.id] { return cached }
        if let answer = await Self.race(item, timeout: timeout, generate: generate),
           let clean = Self.validated(answer) {
            let explanation = Explanation(whatIsIt: clean.whatIsIt, whatYouLose: clean.whatYouLose, byAI: true)
            cache[item.id] = explanation
            return explanation
        }
        return FallbackTexts.explanation(for: item)
    }

    // MARK: model

    private struct ModelUnavailable: Error {}

    @Sendable
    private static func generateWithModel(_ item: Item) async throws -> (whatIsIt: String, whatYouLose: String) {
        guard case .available = SystemLanguageModel.default.availability else { throw ModelUnavailable() }
        // A fresh session per item: no transcript is shared between explanations.
        let session = LanguageModelSession(instructions: instructions)
        let result = try await session.respond(to: prompt(for: item), generating: GeneratedExplanation.self).content
        return (result.whatIsIt, result.whatYouLose)
    }

    /// Detail keys the model may see. Never paths, working directories or command lines.
    static let promptDetailKeys: Set<String> = ["project", "image", "engine", "browser", "bundleID", "lastApp", "usedBy", "ports"]
    static let promptValueLimit = 200

    static func prompt(for item: Item) -> String {
        var lines = ["Name: \(item.name)", "Kind: \(item.category.rawValue)", "Context: \(context(for: item))"]
        let details = item.detail
            .filter { promptDetailKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
        if !details.isEmpty {
            lines.append("Details:")
            lines += details.map { "- \($0.key): \(String($0.value.prefix(promptValueLimit)))" }
        }
        let signals = item.judgement.signals.map(\.text).filter { !$0.isEmpty }
        if !signals.isEmpty {
            lines.append("What CleanUp sees:")
            lines += signals.map { "- \(String($0.prefix(promptValueLimit)))" }
        }
        return lines.joined(separator: "\n")
    }

    /// One plain line saying what kind of thing this is, so the model doesn't guess from the name.
    static func context(for item: Item) -> String {
        let isEngine = item.id.rawValue.hasPrefix("engine:")
        switch item.category {
        case .simulators:
            return isEngine
                ? "background services of the iPhone/iPad Simulator, started by Xcode"
                : "an iPhone/iPad Simulator device started by Xcode, used to test apps"
        case .containers:
            return isEngine
                ? "the app that runs Docker containers"
                : "a Docker container running a service like a database"
        case .devServers: return "a local web/app development server started from a terminal"
        case .apps: return "a Mac app"
        case .browserTabs: return "a web page in a browser"
        case .restart: return "advice to restart the Mac"
        }
    }

    /// Trimmed text, or nil for an empty answer or one that gives a safety verdict.
    private static func validated(_ answer: (whatIsIt: String, whatYouLose: String)) -> (whatIsIt: String, whatYouLose: String)? {
        let what = answer.whatIsIt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lose = answer.whatYouLose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !what.isEmpty, !lose.isEmpty else { return nil }
        for text in [what, lose] where text.range(of: #"\bsafe\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return nil
        }
        return (what, lose)
    }

    // MARK: timeout race

    /// The answer, or nil on error or when `timeout` passes first. Does not wait for a generator that
    /// ignores cancellation.
    private static func race(
        _ item: Item, timeout: Duration, generate: @escaping Generate
    ) async -> (whatIsIt: String, whatYouLose: String)? {
        await withCheckedContinuation { (continuation: CheckedContinuation<(whatIsIt: String, whatYouLose: String)?, Never>) in
            let gate = Gate(continuation)
            let work = Task { gate.finish(try? await generate(item)) }
            let timer = Task {
                try? await Task.sleep(for: timeout)
                gate.finish(nil)
            }
            gate.track([work, timer])
        }
    }

    /// Resumes the continuation once, with whichever result comes first, then cancels the other task.
    private final class Gate: Sendable {
        typealias Answer = (whatIsIt: String, whatYouLose: String)?
        private struct State {
            var continuation: CheckedContinuation<Answer, Never>?
            var tasks: [Task<Void, Never>] = []
            var done = false
        }
        private let state: OSAllocatedUnfairLock<State>

        init(_ continuation: CheckedContinuation<Answer, Never>) {
            state = OSAllocatedUnfairLock(initialState: State(continuation: continuation))
        }

        func track(_ tasks: [Task<Void, Never>]) {
            let cancelNow = state.withLock { s -> Bool in
                s.tasks = tasks
                return s.done
            }
            if cancelNow { tasks.forEach { $0.cancel() } }
        }

        func finish(_ answer: Answer) {
            let (continuation, tasks) = state.withLock { s -> (CheckedContinuation<Answer, Never>?, [Task<Void, Never>]) in
                defer { s.continuation = nil; s.done = true }
                return (s.continuation, s.tasks)
            }
            continuation?.resume(returning: answer)
            tasks.forEach { $0.cancel() }
        }
    }
}
