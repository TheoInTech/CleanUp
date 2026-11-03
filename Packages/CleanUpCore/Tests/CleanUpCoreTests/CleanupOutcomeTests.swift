import Foundation
import Testing
@testable import CleanUpCore

private func item(_ id: String, _ name: String, cores: Double = 0.5) -> Item {
    Item(
        id: ItemIdentity(rawValue: id), category: .apps, name: name, symbol: "app",
        judgement: Judgement(verdict: .manual, fact: "", signals: []),
        cores: cores, memoryBytes: 0, processes: [], detail: [:]
    )
}

@Test func outcomeNamesEachItemStoppedFirst() {
    let items = [item("app:a", "Steam"), item("app:b", "Acrobat"), item("app:c", "Xcode")]
    let report = CleanupReport(
        stopped: [ItemIdentity(rawValue: "app:c"), ItemIdentity(rawValue: "app:a")],
        failed: [(ItemIdentity(rawValue: "app:b"), "Acrobat asked to save first")],
        skipped: [], undo: [UndoToken(identity: ItemIdentity(rawValue: "app:a"), action: "open", arguments: [])],
        freedCores: 1.0
    )
    let outcome = CleanupOutcome(items: items, report: report)
    #expect(outcome.entries.map(\.name) == ["Steam", "Xcode", "Acrobat"])
    #expect(outcome.entries.map(\.result) == [.stopped, .stopped, .notStopped("Acrobat asked to save first")])
    #expect(outcome.stoppedCount == 2)
    #expect(outcome.title == "Stopped 2")
    #expect(outcome.subtitle == "1 left running · freed 1.0 cores")
    #expect(outcome.canUndo)
    #expect(!outcome.allStopped)
}

@Test func outcomeWhenNothingCouldBeStopped() {
    let items = [item("sim:x", "iPhone 18 Pro")]
    let report = CleanupReport(
        stopped: [], failed: [], skipped: [(ItemIdentity(rawValue: "sim:x"), "iPhone 18 Pro is in use now")],
        undo: [], freedCores: 0
    )
    let outcome = CleanupOutcome(items: items, report: report)
    #expect(outcome.title == "Nothing stopped")
    #expect(outcome.subtitle == "1 left running")
    #expect(outcome.entries.map(\.result) == [.notStopped("iPhone 18 Pro is in use now")])
    #expect(!outcome.canUndo)
}

@Test func outcomeAllStoppedAndUnreportedItems() {
    let items = [item("app:a", "Steam"), item("app:z", "Ghost")]
    let report = CleanupReport(stopped: [ItemIdentity(rawValue: "app:a")], failed: [], skipped: [], undo: [], freedCores: 0.01)
    let outcome = CleanupOutcome(items: items, report: report)
    // An item the report doesn't mention wasn't stopped; tiny savings aren't worth a number.
    #expect(outcome.entries.last?.result == .notStopped("Not stopped"))
    #expect(outcome.subtitle == "1 left running")
    let clean = CleanupOutcome(items: [items[0]], report: report)
    #expect(clean.allStopped); #expect(clean.subtitle == nil)
}
