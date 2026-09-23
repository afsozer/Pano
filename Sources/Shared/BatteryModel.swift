import Foundation

/// Battery health and live power flow. Source is a single `ioreg -r -c
/// AppleSmartBattery` call (no root, ~30 ms); `system_profiler
/// SPPowerDataType` has the same data but takes seconds — unacceptable at the
/// agent's 60 s pace.
///
/// The menu bar app writes the snapshot, the widget only reads it. Low Power
/// Mode changes come from the widget via an intent (the same Darwin
/// notification path as the sleep guard).
struct BatterySnapshot: Codable, Hashable {
    var updatedAt: Date

    // MARK: Live
    /// `CurrentCapacity` (percent).
    var chargePercent: Int
    /// `AppleRawMaxCapacity` / `DesignCapacity` × 100. Exceeds 100 on a new
    /// battery (6303/6249 = 100.9%, measured); Apple clamps to 100, so do we.
    var healthPercent: Double
    var maxCapacityMAh: Int?
    var designCapacityMAh: Int?
    var cycleCount: Int?
    /// `DesignCycleCount9C` — 1000 on Apple Silicon laptops.
    var designCycleCount: Int?
    /// `Temperature` is in hundredths of a degree Celsius, not Kelvin: 3047 → 30.47 °C.
    var temperatureC: Double?
    var voltageV: Double?
    /// `InstantAmperage`; negative = drawing from the battery (discharging).
    var amperageMA: Int?

    var isCharging: Bool
    var externalConnected: Bool
    var fullyCharged: Bool
    /// `TimeRemaining`; 65535 means "unknown" (always the case on the adapter).
    var timeRemainingMin: Int?

    // MARK: Adapter and power
    var adapterWatts: Int?
    var adapterName: String?
    /// `PowerTelemetryData.SystemPowerIn` mW → W: total power drawn from the wall.
    var systemPowerW: Double?
    /// `PowerTelemetryData.BatteryPower` mW → W. 0 on the adapter.
    var batteryPowerW: Double?

    // MARK: State
    var lowPowerMode: Bool
    /// "Normal" when `PermanentFailureStatus` is 0. Not shown in the UI.
    var condition: String?
    var permanentFailure: Bool

    var error: String?

    static let empty = BatterySnapshot(
        updatedAt: .distantPast, chargePercent: 0, healthPercent: 0,
        isCharging: false, externalConnected: false, fullyCharged: false,
        lowPowerMode: false, permanentFailure: false)

    /// On the adapter but not charging: optimized charging may be holding it at
    /// 80–85%. Showing that as "charging" would be a lie (measured: 85%,
    /// IsCharging No).
    var onBattery: Bool { !externalConnected }

    /// Laptop power draw peaks around 100 W, well below this ceiling. Anything
    /// above is a parsing error, not a reading: ioreg printing negatives as
    /// unsigned once put −1.8×10¹⁶ W on the card. Better an empty field than
    /// an absurd number.
    static let plausibleWattCeiling: Double = 200

    /// Power drawn from the battery (W, positive). Falls back to current × voltage.
    var dischargeW: Double? {
        guard onBattery else { return nil }
        if let batteryPowerW, batteryPowerW != 0 {
            let watts = abs(batteryPowerW)
            if watts <= Self.plausibleWattCeiling { return watts }
        }
        guard let amperageMA, let voltageV, amperageMA != 0 else { return nil }
        let watts = abs(Double(amperageMA) * voltageV / 1000)
        return watts <= Self.plausibleWattCeiling ? watts : nil
    }

    /// How much of the rated cycle life is used up (for the bar).
    var cyclePercent: Double {
        guard let cycleCount, let designCycleCount, designCycleCount > 0 else { return 0 }
        return min(100, Double(cycleCount) / Double(designCycleCount) * 100)
    }

    /// The agent writes every 60 s; 5 min of silence = app closed or stuck.
    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 5 * 60 }
}

enum BatteryStore {
    static let fileURL = AppPaths.file("battery.json")

    /// The App Group entitlement doesn't work with ad-hoc signing, so the
    /// snapshot is also written into the extension's container; inside the
    /// extension `~` resolves there, so the reading code stays shared.
    static let widgetContainerFileURL = AppPaths.widgetContainerFile("battery.json")

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load() -> BatterySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(BatterySnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: BatterySnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            if mirrorToWidgetContainer {
                let widgetDirectory = widgetContainerFileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
                try? data.write(to: widgetContainerFileURL, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }
}
