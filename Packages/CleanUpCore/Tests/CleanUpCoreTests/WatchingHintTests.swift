import Foundation
import Testing
@testable import CleanUpCore

@Test func simulatorJudgeSaysWhenItsWatchEnds() {
    let watching = SimulatorJudge.judge(.fixture(bootedAgo: .days(2), trackedFor: .minutes(5)), now: now)
    #expect(watching.watchingUntil == now.addingTimeInterval(.minutes(25)))
    #expect(SimulatorJudge.judge(.fixture(bootedAgo: .days(2), trackedFor: .minutes(30)), now: now).watchingUntil == nil)
}

@Test func devServerJudgeSaysWhenItsWatchEnds() {
    #expect(DevServerJudge.judge(.fixture(observedFor: .minutes(10)), now: now).watchingUntil == now.addingTimeInterval(.minutes(20)))
    #expect(DevServerJudge.judge(.fixture(observedFor: .minutes(30)), now: now).watchingUntil == nil)
}

private func item(_ id: String, verdict: Verdict, until: Date?) -> Item {
    Item(
        id: ItemIdentity(rawValue: id), category: .devServers, name: id, symbol: "server.rack",
        judgement: Judgement(verdict: verdict, fact: "", signals: [], watchingUntil: until),
        cores: 0, memoryBytes: 0, processes: [], detail: [:]
    )
}

private func snapshot(_ items: [Item]) -> Snapshot {
    Snapshot(date: now, battery: nil, coresBusy: 0, swapUsedBytes: 0, swapTotalBytes: 0, uptime: 0,
             categories: [CategorySummary(id: .devServers, items: items)], mood: .allGood)
}

@Test func snapshotWatchEndsWithTheLastItemInUse() {
    let s = snapshot([
        item("a", verdict: .inUse, until: now.addingTimeInterval(.minutes(4))),
        item("b", verdict: .inUse, until: now.addingTimeInterval(.minutes(22))),
        item("c", verdict: .idle, until: now.addingTimeInterval(.minutes(40))),   // not in use: ignored
        item("d", verdict: .inUse, until: now.addingTimeInterval(-60)),           // already over
    ])
    #expect(s.watchingUntil(now: now) == now.addingTimeInterval(.minutes(22)))
    #expect(snapshot([item("e", verdict: .inUse, until: nil)]).watchingUntil(now: now) == nil)
}

@Test func watchingHintRoundsUpToWholeMinutes() {
    #expect(WatchingHint.text(until: now.addingTimeInterval(.minutes(24) + 12), now: now) == "Still watching · ready in 25 min")
    #expect(WatchingHint.text(until: now.addingTimeInterval(20), now: now) == "Still watching · ready in 1 min")
    #expect(WatchingHint.text(until: now.addingTimeInterval(-1), now: now) == nil)
}

@Test func judgementsWithoutAWatchStillDecode() throws {
    let old = #"{"verdict":"idle","fact":"idle 2 h","signals":[]}"#
    let j = try JSONDecoder().decode(Judgement.self, from: Data(old.utf8))
    #expect(j.watchingUntil == nil)
}
