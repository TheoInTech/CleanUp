import Foundation
import Testing
@testable import CleanUpCore

@Test func processTableContainsSelf() {
    let me = ProcessTable.snapshot()[getpid()]
    #expect(me != nil)
    #expect(me!.path.hasSuffix("xctest") || me!.path.contains("swiftpm-testing-helper") || me!.path.contains("CleanUpCorePackageTests"))
    #expect(me!.startTime < Date())
}

@Test func cpuSamplerFirstCallEmptySecondHasSelf() async {
    let s = CPUSampler(); let t1 = ProcessTable.snapshot()
    #expect(await s.sample(t1, at: .now).isEmpty)
    var x = 0.0; for i in 0..<3_000_000 { x += Double(i) }; _ = x
    let t2 = ProcessTable.snapshot()
    #expect((await s.sample(t2, at: .now.addingTimeInterval(0.5))[getpid()] ?? 0) > 0)
}

@Test func parsesSwapUsage() {
    let r = SystemMemory.parseSwapUsage("total = 23552.00M  used = 22424.62M  free = 1127.38M  (encrypted)")
    #expect(r?.total == 23552 * 1_048_576)
    #expect(r?.used == UInt64(22424.62 * 1_048_576))
}

@Test func commandRunnerTimesOut() async {
    let r = await CommandRunner.run("/bin/sleep", ["5"], timeout: .milliseconds(300))
    #expect(r.timedOut)
}

@Test func batteryValuesInRangeWhenPresent() {
    guard let b = Battery.read() else { return }
    #expect((0...100).contains(b.percent))
    if let health = b.healthPercent { #expect((1...150).contains(health)) }
}

// MARK: - Additional behaviour checks

@Test func commandRunnerTimeoutReturnsPromptly() async {
    let clock = ContinuousClock()
    let start = clock.now
    let r = await CommandRunner.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
    #expect(r.timedOut)
    #expect(clock.now - start < .seconds(3))
}

@Test func commandRunnerCapturesOutputAndStatus() async {
    let ok = await CommandRunner.run("/bin/echo", ["hello"])
    #expect(ok.status == 0 && ok.stdout == "hello\n" && !ok.timedOut)
    let bad = await CommandRunner.run("/bin/sh", ["-c", "echo err >&2; exit 3"])
    #expect(bad.status == 3 && bad.stderr == "err\n")
}

@Test func commandRunnerDoesNotDeadlockOnLargeOutput() async {
    let r = await CommandRunner.run("/usr/bin/yes", ["abcdefghij"], timeout: .milliseconds(500))
    #expect(r.timedOut)
    #expect(r.stdout.count > 65_536)
}

@Test func commandRunnerMissingExecutableDoesNotCrash() async {
    let r = await CommandRunner.run("definitely-not-a-real-binary-xyz", [])
    #expect(r.status != 0)
    #expect(!r.timedOut)
}

@Test func commandRunnerResolvesBareNamesViaSearchPath() async {
    let r = await CommandRunner.run("uname", [])
    #expect(r.status == 0)
    #expect(CommandRunner.searchPath.contains("/opt/homebrew/bin"))
    #expect(CommandRunner.searchPath.contains("/usr/local/bin"))
    #expect(CommandRunner.searchPath.contains { $0.hasSuffix("/.orbstack/bin") })
}

@Test func batteryAmperageWrapDecoding() {
    #expect(Battery.signedMilliamps(18446744073709549186) == -2430)
    #expect(Battery.signedMilliamps(2430) == 2430)
    #expect(Battery.signedMilliamps(0) == 0)
}

@Test func batteryReadingFromProperties() {
    let props: [String: Any] = [
        "InstantAmperage": UInt64(18446744073709549186),
        "Voltage": 10651,
        "AvgTimeToEmpty": 65535,
        "DesignCapacity": 6249,
        "AppleRawMaxCapacity": 5800,
        "CycleCount": 221,
        "CurrentCapacity": 55,
        "MaxCapacity": 100,
        "IsCharging": false,
        "ExternalConnected": false,
    ]
    let b = Battery.reading(from: props)
    #expect(b?.onBattery == true)
    #expect(b?.percent == 55)
    #expect(b?.healthPercent == 5800 * 100 / 6249)
    #expect(b?.cycleCount == 221)
    #expect(b?.minutesLeft == nil)
    #expect(abs((b?.drainWatts ?? 0) - 2430.0 * 10651.0 / 1e6) < 1e-9)
}

@Test func batteryOnACHasNoDrainOrTime() {
    let props: [String: Any] = [
        "InstantAmperage": 1500, "Voltage": 12000, "AvgTimeToEmpty": 90,
        "DesignCapacity": 6249, "AppleRawMaxCapacity": 5800, "CycleCount": 3,
        "CurrentCapacity": 80, "MaxCapacity": 100,
        "IsCharging": true, "ExternalConnected": true,
    ]
    let b = Battery.reading(from: props)
    #expect(b?.onBattery == false)
    #expect(b?.drainWatts == nil)
    #expect(b?.minutesLeft == nil)
}

@Test func batteryMinutesLeftWhenKnown() {
    let props: [String: Any] = [
        "InstantAmperage": UInt64(18446744073709549186), "Voltage": 10651, "AvgTimeToEmpty": 125,
        "DesignCapacity": 6249, "AppleRawMaxCapacity": 5800, "CycleCount": 3,
        "CurrentCapacity": 55, "MaxCapacity": 100,
        "IsCharging": false, "ExternalConnected": false,
    ]
    #expect(Battery.reading(from: props)?.minutesLeft == 125)
}

@Test func batteryCapacitiesFallBackToBatteryData() {
    // Shape reported by recent macOS: capacities only inside BatteryData, no AppleRawMaxCapacity.
    let props: [String: Any] = [
        "InstantAmperage": UInt64(18446744073709549597), "Voltage": 11935, "AvgTimeToEmpty": 125,
        "CycleCount": 223, "CurrentCapacity": 74, "MaxCapacity": 100,
        "ExternalConnected": false, "IsCharging": false,
        "BatteryData": ["DesignCapacity": 6249, "NominalChargeCapacity": 5539, "FullChargeCapacity": 5387],
    ]
    let b = Battery.reading(from: props)
    #expect(b?.healthPercent == 5539 * 100 / 6249)
    #expect(b?.minutesLeft == 125)
    #expect(b?.drainWatts != nil)
}

@Test func batteryWithoutCapacityKeysStillReadsDrainAndMinutes() {
    // Some batteries don't publish their design capacity: health is unknown, nothing else is.
    let props: [String: Any] = [
        "InstantAmperage": UInt64(18446744073709549597), "Voltage": 11935, "AvgTimeToEmpty": 42,
        "CurrentCapacity": 50, "MaxCapacity": 100, "ExternalConnected": false,
    ]
    let b = Battery.reading(from: props)
    #expect(b != nil)
    #expect(b?.percent == 50)
    #expect(b?.minutesLeft == 42)
    #expect(b?.drainWatts != nil)
    #expect(b?.healthPercent == nil)
    #expect(b?.cycleCount == nil)
    #expect(Battery.reading(from: ["MaxCapacity": 100]) == nil)   // no charge level: no reading
}

@Test func processTableRecordsAreSane() {
    let me = ProcessTable.snapshot()[getpid()]!
    #expect(me.pid == getpid() && me.ppid == getppid())
    #expect(me.uid == getuid())
    #expect(me.residentBytes > 0)
    #expect(me.cpuTimeNanos > 0)
    #expect(!me.name.isEmpty)
    #expect(me.cwd != nil)
    #expect(!me.arguments.isEmpty)
    #expect(me.ref == ProcessRef(pid: me.pid, startTime: me.startTime))
}

@Test func socketsFindOwnListener() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    try #require(fd >= 0)
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    try #require(bound == 0)
    try #require(listen(fd, 1) == 0)
    var out = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &out) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    let port = Int(UInt16(bigEndian: out.sin_port))
    let found = Sockets.tcp(for: [getpid()])
    #expect(found.contains { $0.pid == getpid() && $0.state == .listen && $0.localPort == port })
}

@Test func socketsIgnoreUnreadablePids() {
    #expect(Sockets.tcp(for: [0, 1, 99_999_999]).allSatisfy { _ in true })
}

@Test func systemMemoryReadings() {
    #expect(SystemMemory.uptime() > 0)
    let swap = SystemMemory.swap()
    #expect(swap.used <= swap.total || swap.total == 0)
    #expect(SystemMemory.parseSwapUsage("garbage") == nil)
}

@Test func searchPathFindsDockerDesktopsOwnCLI() {
    // Docker Desktop can put its CLI in ~/.docker/bin (the "User" option) or only inside the app.
    #expect(CommandRunner.searchPath.contains(NSHomeDirectory() + "/.docker/bin"))
    #expect(CommandRunner.searchPath.contains("/Applications/Docker.app/Contents/Resources/bin"))
}
