import Foundation
import Testing
@testable import CleanUpCore

@Test func identityRawValues() {
    #expect(ItemIdentity.simulator(udid: "ABC").rawValue == "sim:ABC")
    #expect(ItemIdentity.devServer(cwd: "/p/evone", command: "expo start").rawValue == "dev:/p/evone|expo start")
}

@Test func identityFactoriesCoverAllKinds() {
    #expect(ItemIdentity.container(name: "db").rawValue == "container:db")
    #expect(ItemIdentity.engine(name: "colima").rawValue == "engine:colima")
    #expect(ItemIdentity.app(bundleID: "com.apple.Xcode").rawValue == "app:com.apple.Xcode")
    #expect(ItemIdentity.browserTab(pid: 4242).rawValue == "tab:4242")
    #expect(ItemIdentity.restart.rawValue == "restart")
}

@Test func moodLabels() {
    #expect(Mood.drainingFast.label == "🔥 Draining fast")
    #expect(Mood.allGood.label == "😌 All good")
    #expect(Mood.busy.label == "🟠 Busy")
}

@Test func snapshotRoundTripsJSON() throws {
    let s = Snapshot.empty
    #expect(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(s)) == s)
}

@Test func populatedSnapshotRoundTripsJSON() throws {
    let item = Item(
        id: .simulator(udid: "ABC"),
        category: .simulators,
        name: "iPhone 17",
        symbol: "iphone",
        judgement: Judgement(
            verdict: .idle,
            fact: "Not used for 5 h",
            signals: [Signal(kind: .idle, text: "No input for 5 h")]
        ),
        cores: 0.4,
        memoryBytes: 512_000_000,
        processes: [ProcessRef(pid: 123, startTime: Date(timeIntervalSince1970: 1_000))],
        detail: ["udid": "ABC"]
    )
    let s = Snapshot(
        date: Date(timeIntervalSince1970: 2_000),
        battery: BatteryReading(onBattery: true, percent: 80, drainWatts: 12.5, minutesLeft: nil, healthPercent: 93, cycleCount: 221),
        coresBusy: 3.5,
        swapUsedBytes: 1,
        swapTotalBytes: 2,
        uptime: 3_600,
        categories: [CategorySummary(id: .simulators, items: [item])],
        mood: .busy
    )
    #expect(try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(s)) == s)
}

@Test func categoryCoresSumsItems() {
    func item(_ n: String, cores: Double) -> Item {
        Item(id: .container(name: n), category: .containers, name: n, symbol: "shippingbox",
             judgement: Judgement(verdict: .idle, fact: "", signals: []),
             cores: cores, memoryBytes: 0, processes: [], detail: [:])
    }
    let summary = CategorySummary(id: .containers, items: [item("a", cores: 0.5), item("b", cores: 1.25)])
    #expect(summary.cores == 1.75)
}

@Test func itemIdentityEncodesAsPlainString() throws {
    let data = try JSONEncoder().encode([ItemIdentity.restart])
    #expect(String(decoding: data, as: UTF8.self) == "[\"restart\"]")
}

@Test func quickSummaryRoundTripsAndOldJSONReadsAsZero() throws {
    let s = Snapshot.empty.withQuickSummary(idleCount: 15, freedCores: 6.1)
    let decoded = try JSONDecoder().decode(Snapshot.self, from: JSONEncoder().encode(s))
    #expect(decoded.idleCount == 15)
    #expect(decoded.freedCores == 6.1)
    #expect(decoded == s)

    // JSON written before the two fields existed.
    var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
    object["idleCount"] = nil
    object["freedCores"] = nil
    let old = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(old.idleCount == 0)
    #expect(old.freedCores == 0)
}

@Test func enginesAreRecognisedByIdentity() {
    #expect(Item.fixtureEngine().isEngine)
    #expect(Item.fixture(.engine(name: "simulator-services"), category: .simulators).isEngine)
    #expect(!Item.fixtureContainer().isEngine)
}

@Test func batteryWithoutHealthRoundTrips() throws {
    let b = BatteryReading(onBattery: true, percent: 40, drainWatts: 9, minutesLeft: 50, healthPercent: nil, cycleCount: nil)
    #expect(try JSONDecoder().decode(BatteryReading.self, from: JSONEncoder().encode(b)) == b)
}
