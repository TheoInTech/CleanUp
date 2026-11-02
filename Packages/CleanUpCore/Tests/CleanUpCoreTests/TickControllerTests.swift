import Foundation
import Testing
@testable import CleanUpCore

private func snapshot(_ categories: [CategorySummary]) -> Snapshot {
    Snapshot(date: fixedNow, battery: nil, coresBusy: 0, swapUsedBytes: 0, swapTotalBytes: 0, uptime: 0, categories: categories, mood: .allGood)
}

/// What the window, the popover, the widget and the notification tick, refresh after refresh.
@Suite struct TickControllerTests {
    private let sim = Item.fixtureSimulator(udid: "U1", name: "A", verdict: .idle, cores: 1)
    private let sim2 = Item.fixtureSimulator(udid: "U2", name: "B", verdict: .idle, cores: 1)

    @Test func quickSelectTicksWhatIsNewlyIdleAndLeavesWhatYouUnticked() {
        var ticks = TickController()
        let first = snapshot([CategorySummary(id: .simulators, items: [sim])])
        ticks.apply(first, keep: .empty)
        #expect(ticks.selection.ticked == [sim.id])
        ticks.toggle(sim, in: first)                          // the user unticks it
        ticks.apply(first, keep: .empty)
        #expect(ticks.selection.ticked.isEmpty)               // stays unticked
        let second = snapshot([CategorySummary(id: .simulators, items: [sim, sim2])])
        ticks.apply(second, keep: .empty)
        #expect(ticks.selection.ticked == [sim2.id])          // only the newly idle one is ticked
    }

    @Test func chooseMyselfTicksNothingAndQuickSelectProposesAgain() {
        let s = Snapshot.incident()
        var ticks = TickController()
        ticks.apply(s, keep: .empty)
        #expect(ticks.selection.count == 11)
        ticks.setMode(.manual, in: s, keep: .empty)
        #expect(ticks.selection.ticked.isEmpty)
        ticks.apply(s, keep: .empty)
        #expect(ticks.selection.ticked.isEmpty)
        ticks.setMode(.quick, in: s, keep: .empty)
        #expect(ticks.selection.count == 11)
    }

    @Test func headerTickTicksContainersThenTheirEngine() {
        let s = Snapshot.incidentAllContainersIdle()
        var ticks = TickController(mode: .manual)
        ticks.toggleCategory(.containers, in: s, keep: .empty)
        #expect(ticks.selection.ticked.contains(.engine(name: "Docker Desktop")))
        #expect(ticks.selection.state(of: .containers, in: s) == .all)
        ticks.toggleCategory(.containers, in: s, keep: .empty)   // anything ticked → untick all
        #expect(ticks.selection.state(of: .containers, in: s) == .none)
    }

    @Test func headerTickNeverTicksAlwaysKeptItems() {
        let s = Snapshot.incidentAllContainersIdle()
        var keep = KeepList.empty
        keep.add(.container(name: "evone-routing"), name: "evone-routing")
        var ticks = TickController(mode: .manual)
        ticks.toggleCategory(.containers, in: s, keep: keep)
        #expect(!ticks.selection.ticked.contains(.container(name: "evone-routing")))
        #expect(ticks.selection.ticked.contains(.container(name: "evone-postgres")))
        // Its engine can't be ticked while a kept container of it stays unticked.
        #expect(!ticks.selection.ticked.contains(.engine(name: "Docker Desktop")))
    }

    @Test func headerTickNeverTicksApps() {
        let app = Item.fixture(.app(bundleID: "com.example.idle"), category: .apps, verdict: .idle, cores: 1)
        let s = snapshot([CategorySummary(id: .apps, items: [app])])
        var ticks = TickController(mode: .manual)
        #expect(!TickController.hasIdle(.apps, in: s, keep: .empty))
        ticks.toggleCategory(.apps, in: s, keep: .empty)
        #expect(ticks.selection.ticked.isEmpty)
    }

    @Test func aCategoryWithOnlyKeptIdleItemsHasNothingToTick() {
        let s = snapshot([CategorySummary(id: .simulators, items: [sim])])
        var keep = KeepList.empty
        keep.add(sim.id, name: sim.name)
        #expect(!TickController.hasIdle(.simulators, in: s, keep: keep))
        #expect(TickController.hasIdle(.simulators, in: s, keep: .empty))
    }

    @Test func keepingAnItemUnticksItForGood() {
        let s = snapshot([CategorySummary(id: .simulators, items: [sim])])
        var keep = KeepList.empty
        var ticks = TickController()
        ticks.apply(s, keep: keep)
        keep.add(sim.id, name: sim.name)
        ticks.kept(sim, in: s)
        #expect(ticks.selection.ticked.isEmpty)
        ticks.apply(s, keep: keep)
        #expect(ticks.selection.ticked.isEmpty)
    }

    @Test func cleanIdleSelectionNeverIncludesAppsOrKeptItems() {
        let app = Item.fixture(.app(bundleID: "com.example.idle"), category: .apps, verdict: .idle, cores: 1)
        let s = snapshot([CategorySummary(id: .simulators, items: [sim, sim2]), CategorySummary(id: .apps, items: [app])])
        var keep = KeepList.empty
        keep.add(sim2.id, name: sim2.name)
        var ticks = TickController(mode: .manual)
        ticks.toggle(app, in: s)                             // ticked by hand in the window
        #expect(ticks.selection.ticked.contains(app.id))
        #expect(TickController.cleanIdleSelection(s, keep: keep).ticked == [sim.id])
    }

    @Test func onlyItemsStillTickableInTheFreshSnapshotAreCleaned() {
        let old = snapshot([CategorySummary(id: .simulators, items: [sim, sim2])])
        var ticks = TickController()
        ticks.apply(old, keep: .empty)
        // Since then, sim became in use and sim2 is gone.
        let busy = Item.fixtureSimulator(udid: "U1", name: "A", verdict: .inUse, cores: 1)
        let fresh = snapshot([CategorySummary(id: .simulators, items: [busy])])
        #expect(TickController.itemsToClean(ticks.selection, in: fresh).isEmpty)
        #expect(TickController.itemsToClean(ticks.selection, in: old).map(\.id) == [sim.id, sim2.id])
    }

    @Test func stoppedItemsAreUnticked() {
        let s = snapshot([CategorySummary(id: .simulators, items: [sim, sim2])])
        var ticks = TickController()
        ticks.apply(s, keep: .empty)
        ticks.stopped([sim.id])
        #expect(ticks.selection.ticked == [sim2.id])
    }

    @Test func snapshotsOlderThanTenSecondsAreStale() {
        #expect(TickController.staleAfter == 10)
        let s = snapshot([])
        #expect(!TickController.isStale(s, now: fixedNow.addingTimeInterval(10)))
        #expect(TickController.isStale(s, now: fixedNow.addingTimeInterval(10.5)))
    }
}
