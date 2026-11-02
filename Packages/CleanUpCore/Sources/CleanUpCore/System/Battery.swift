import Foundation
import IOKit

public enum Battery {
    /// Current battery state, or `nil` on a Mac without one (or if IOKit won't answer).
    public static func read() -> BatteryReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return reading(from: properties)
    }

    /// Builds a reading from `AppleSmartBattery` registry properties; `nil` only without a charge
    /// level. Health (design / raw capacity, cycles) is optional: drain and time left don't need it.
    static func reading(from p: [String: Any]) -> BatteryReading? {
        guard let current = int(p["CurrentCapacity"]), let maxCapacity = int(p["MaxCapacity"]), maxCapacity > 0 else { return nil }
        var health: Int?
        if let design = capacity("DesignCapacity", in: p), design > 0,
           let rawMax = capacity("AppleRawMaxCapacity", in: p) ?? capacity("NominalChargeCapacity", in: p)
            ?? capacity("FullChargeCapacity", in: p) {
            health = rawMax * 100 / design
        }

        let external = bool(p["ExternalConnected"]) ?? bool(p["IsCharging"]) ?? false
        let onBattery = !external

        var drainWatts: Double?
        if onBattery, let amperage = p["InstantAmperage"].flatMap(uint64), let millivolts = int(p["Voltage"]) {
            let milliamps = signedMilliamps(amperage)
            if milliamps < 0 {
                drainWatts = Double(abs(milliamps)) * Double(millivolts) / 1e6
            }
        }

        var minutesLeft: Int?
        if onBattery, let minutes = int(p["AvgTimeToEmpty"]), minutes < 65535 {
            minutesLeft = minutes
        }

        return BatteryReading(
            onBattery: onBattery,
            percent: min(100, max(0, current * 100 / maxCapacity)),
            drainWatts: drainWatts,
            minutesLeft: minutesLeft,
            healthPercent: health,
            cycleCount: int(p["CycleCount"])
        )
    }

    /// Capacity keys live at the top level on older macOS; newer releases only expose them inside the
    /// nested `BatteryData` dictionary (and drop `AppleRawMaxCapacity` in favour of
    /// `NominalChargeCapacity`). Look in both places.
    private static func capacity(_ key: String, in p: [String: Any]) -> Int? {
        if let top = int(p[key]) { return top }
        return int((p["BatteryData"] as? [String: Any])?[key])
    }

    /// IOKit reports negative currents as a huge unsigned number (18446744073709549186 == -2430 mA;
    /// some firmware wraps at 32 bits instead). Real battery currents fit comfortably in an Int16
    /// (+/-32 A), so taking the low 16 bits as signed decodes every wrap width correctly.
    static func signedMilliamps(_ raw: UInt64) -> Int {
        Int(Int16(truncatingIfNeeded: raw))
    }

    // MARK: - Property coercion

    private static func uint64(_ value: Any) -> UInt64? {
        // NSNumber.uint64Value keeps the two's-complement bit pattern of negative values.
        (value as? NSNumber)?.uint64Value
    }

    private static func int(_ value: Any?) -> Int? {
        guard let value, let n = value as? NSNumber else { return nil }
        return n.intValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        return (value as? NSNumber)?.boolValue
    }
}
