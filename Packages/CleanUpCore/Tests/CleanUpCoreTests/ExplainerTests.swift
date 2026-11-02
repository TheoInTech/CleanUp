import Foundation
import FoundationModels
import os
import Testing
@testable import CleanUpCore

private func sentenceCount(_ text: String) -> Int {
    text.filter { ".!?".contains($0) }.count
}

private func devServer(project: String, command: String) -> Item {
    .fixtureDevServer(project: project, command: command, name: command)
}

struct FallbackTextsTests {
    @Test func fallbackForSimulator() {
        let e = FallbackTexts.explanation(for: .fixtureSimulator())
        #expect(e.whatIsIt == "A pretend iPhone from Xcode. It keeps running in the background even with its window closed.")
        #expect(e.byAI == false)
        #expect(!e.whatYouLose.isEmpty)
    }

    @Test func fallbackNamesProjectForDevServer() {
        #expect(FallbackTexts.explanation(for: .fixtureDevServer(project: "evone/apps/mobile")).whatIsIt.contains("evone/apps/mobile"))
    }

    @Test func knownDevServersGetSpecificLines() {
        let expo = FallbackTexts.explanation(for: devServer(project: "evone/apps/mobile", command: "node expo start"))
        let next = FallbackTexts.explanation(for: devServer(project: "site", command: "node next dev"))
        let vite = FallbackTexts.explanation(for: devServer(project: "dash", command: "node vite"))
        let other = FallbackTexts.explanation(for: devServer(project: "api", command: "node server.js"))
        #expect(expo.whatIsIt.contains("Expo") && expo.whatIsIt.contains("evone/apps/mobile"))
        #expect(next.whatIsIt.contains("Next.js") && next.whatIsIt.contains("site"))
        #expect(vite.whatIsIt.contains("Vite") && vite.whatIsIt.contains("dash"))
        #expect(other.whatIsIt.contains("api"))
        #expect(Set([expo.whatIsIt, next.whatIsIt, vite.whatIsIt, other.whatIsIt]).count == 4)
    }

    @Test func devServerWithoutProjectFallsBackToName() {
        let item = Item.fixture(.devServer(cwd: "/x", command: "c"), category: .devServers, name: "vite :5173", detail: ["command": "vite"])
        #expect(FallbackTexts.explanation(for: item).whatIsIt.contains("vite :5173"))
    }

    @Test func knownContainersGetSpecificLines() {
        func container(_ name: String, image: String) -> Item {
            .fixture(.container(name: name), category: .containers, name: name, detail: ["image": image])
        }
        let pg = FallbackTexts.explanation(for: container("evone-postgres", image: "postgres:16"))
        let redis = FallbackTexts.explanation(for: container("cache", image: "redis:7"))
        let mail = FallbackTexts.explanation(for: container("savio-finance-app-mailpit-1", image: "axllent/mailpit"))
        let plain = FallbackTexts.explanation(for: container("paorder-shop-s3-1", image: "minio/minio"))
        #expect(pg.whatIsIt.contains("PostgreSQL"))
        #expect(redis.whatIsIt.contains("Redis"))
        #expect(mail.whatIsIt.contains("email"))
        #expect(!plain.whatIsIt.contains("PostgreSQL"))
        #expect(plain.whatIsIt.contains("minio/minio"))
    }

    @Test func engineIsExplainedAsTheContainerApp() {
        let e = FallbackTexts.explanation(for: .fixtureEngine())
        #expect(e.whatIsIt.contains("Docker Desktop"))
        #expect(e.whatYouLose.lowercased().contains("container"))
    }

    @Test func everyCategoryHasShortPlainText() {
        let items: [Item] = [
            .fixtureSimulator(),
            .fixture(.simulator(udid: "services"), category: .simulators, name: "Simulator services"),
            .fixtureContainer(),
            .fixtureEngine(),
            .fixtureDevServer(project: "evone/apps/mobile"),
            .fixture(.app(bundleID: "com.valvesoftware.steam"), category: .apps, name: "Steam"),
            .fixtureTab(),
            .fixture(.restart, category: .restart, name: "Restart your Mac"),
        ]
        for item in items {
            let e = FallbackTexts.explanation(for: item)
            #expect(!e.whatIsIt.isEmpty && !e.whatYouLose.isEmpty, "\(item.id.rawValue)")
            #expect(sentenceCount(e.whatIsIt) <= 2, "\(item.id.rawValue): \(e.whatIsIt)")
            #expect(sentenceCount(e.whatYouLose) <= 2, "\(item.id.rawValue): \(e.whatYouLose)")
            #expect(!e.byAI)
            for text in [e.whatIsIt, e.whatYouLose] {
                #expect(text.range(of: #"\bsafe\b"#, options: [.regularExpression, .caseInsensitive]) == nil, "\(text)")
            }
        }
    }

    @Test func appAndTabMentionTheirName() {
        let steam = FallbackTexts.explanation(for: .fixture(.app(bundleID: "x"), category: .apps, name: "Steam"))
        #expect(steam.whatIsIt.contains("Steam"))
        #expect(FallbackTexts.explanation(for: .fixtureTab(browser: "Brave")).whatIsIt.contains("Brave"))
    }
}

struct ExplainerTests {
    @Test func aiDisabledUsesFallback() async {
        #expect(await Explainer(useAI: false).explain(.fixtureContainer()).byAI == false)
    }

    @Test func aiDisabledNeverCallsGenerator() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let explainer = Explainer(useAI: false) { _ in calls.withLock { $0 += 1 }; return ("a", "b") }
        _ = await explainer.explain(.fixtureContainer())
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func aiResultIsUsedAndCachedByIdentity() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let explainer = Explainer(useAI: true) { _ in
            calls.withLock { $0 += 1 }
            return (" A database. ", "Apps lose their data.")
        }
        let first = await explainer.explain(.fixtureContainer())
        let again = await explainer.explain(.fixtureContainer(cores: 2)) // same identity, different numbers
        #expect(first == Explanation(whatIsIt: "A database.", whatYouLose: "Apps lose their data.", byAI: true))
        #expect(again == first)
        #expect(calls.withLock { $0 } == 1)
        _ = await explainer.explain(.fixtureContainer(name: "other"))
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func generatorErrorFallsBackAndIsNotCached() async {
        struct Boom: Error {}
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let explainer = Explainer(useAI: true) { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { throw Boom() }
            return ("ok", "fine")
        }
        let item = Item.fixtureContainer()
        #expect(await explainer.explain(item) == FallbackTexts.explanation(for: item))
        #expect(await explainer.explain(item).byAI == true)
    }

    @Test func emptyOrVerdictAnswersFallBack() async {
        let item = Item.fixtureContainer()
        for answer in [("", "x"), ("x", "  "), ("It is safe to stop.", "Nothing."), ("A thing.", "Nothing, it's SAFE.")] {
            let explainer = Explainer(useAI: true) { _ in answer }
            #expect(await explainer.explain(item) == FallbackTexts.explanation(for: item), "\(answer)")
        }
    }

    @Test func timeoutFallsBackEvenWhenGeneratorIgnoresCancellation() async {
        let explainer = Explainer(useAI: true, timeout: .milliseconds(100)) { _ in
            await withCheckedContinuation { c in
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { c.resume() }
            }
            return ("late", "late")
        }
        let item = Item.fixtureContainer()
        let started = ContinuousClock.now
        let e = await explainer.explain(item)
        #expect(e == FallbackTexts.explanation(for: item))
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func defaultTimeoutIsEightSeconds() {
        #expect(Explainer.defaultTimeout == .seconds(8))
    }

    @Test func promptCarriesNameCategoryAndDetail() {
        let prompt = Explainer.prompt(for: .fixtureContainer(name: "evone-postgres"))
        #expect(prompt.contains("evone-postgres"))
        #expect(prompt.contains("containers"))
        #expect(prompt.contains("image: postgres:16"))
        #expect(prompt.contains("engine: Docker Desktop"))
    }

    @Test func instructionsAreVerbatim() {
        #expect(Explainer.instructions == "You explain Mac background processes to non-technical people in plain words. At most 2 short sentences. Never say whether it is safe; that is decided elsewhere.")
    }

    /// Runs only where Apple Intelligence is on; elsewhere it records nothing and passes.
    @Test func liveModelWhenAvailable() async {
        guard case .available = SystemLanguageModel.default.availability else { return }
        let e = await Explainer(useAI: true).explain(.fixtureContainer())
        #expect(e.byAI)
        #expect(!e.whatIsIt.isEmpty && !e.whatYouLose.isEmpty)
    }
}
