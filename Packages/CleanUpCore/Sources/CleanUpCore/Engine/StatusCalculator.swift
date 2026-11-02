/// Turns the battery, the CPU load and the recent drain into the one-word mood the menu bar shows.
public enum StatusCalculator {
    /// Drain at or above this, sustained, counts as heavy.
    public static let heavyDrainWatts = 20.0
    /// "Draining fast" only below this much time left.
    public static let lowMinutesLeft = 120
    /// "Sustained" is about time coverage, which the caller guarantees (the samples reach back about
    /// five minutes); this only rules out judging from a single reading.
    public static let minimumDrainSamples = 2
    /// `.busy` from this many cores of load.
    public static let busyCores = 4.0

    /// `drainHistory` is the drain (W) sampled over the last five minutes, oldest first; the caller
    /// passes it only when the samples actually span that window.
    public static func mood(battery: BatteryReading?, coresBusy: Double, drainHistory: [Double]) -> Mood {
        if let battery, battery.onBattery,
           let minutes = battery.minutesLeft, minutes < lowMinutesLeft,
           drainHistory.count >= minimumDrainSamples,
           drainHistory.allSatisfy({ $0 >= heavyDrainWatts }) {
            return .drainingFast
        }
        return coresBusy >= busyCores ? .busy : .allGood
    }
}
