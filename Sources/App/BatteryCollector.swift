import Foundation
import WidgetKit

/// Reads battery data from `ioreg -r -c AppleSmartBattery`.
///
/// Why ioreg: one call takes ~30 ms and needs no root. `system_profiler
/// SPPowerDataType` has the same fields but takes seconds; spending a second
/// every 60 s tick makes no sense.
///
/// The output has two layers that use DIFFERENT separators (measured):
/// - top-level lines: `      "CurrentCapacity" = 85`  (spaces around `=`)
/// - nested dictionaries are printed on one line: `"Watts"=68,"Name"="…"`
///   (no spaces). That difference helps: `"CycleCount"=4` inside
///   `BatteryData` never collides with the top-level `"CycleCount" = 4`.
enum BatteryCollector {
    static func collect() -> BatterySnapshot? {
        let result = Shell.run("/usr/sbin/ioreg", ["-r", "-c", "AppleSmartBattery"])
        guard result.status == 0, !result.out.isEmpty else { return nil }
        let top = topLevelFields(result.out)
        guard !top.isEmpty else { return nil }

        let design = int(top["DesignCapacity"])
        let rawMax = int(top["AppleRawMaxCapacity"])
        // On a new battery the raw ratio exceeds 100 (6303/6249 = 100.9%,
        // measured); Apple clamps it, so do we, to avoid "101% health".
        let health: Double = {
            guard let design, design > 0, let rawMax else { return 0 }
            return min(100, Double(rawMax) / Double(design) * 100)
        }()

        // `AdapterDetails` and `AppleRawAdapterDetails` share a suffix; the
        // exact-key match keeps them apart (the latter is an array: `= ({…})`).
        let adapter = top["AdapterDetails"]
        let telemetry = top["PowerTelemetryData"]

        // ioreg may report e.g. "Watts"=68 for an adapter named "70W USB-C Power
        // Adapter". The number people know is the nominal one in the name;
        // prefer it, fall back to Watts.
        let adapterName = inner(adapter, "Name")?.trimmingCharacters(in: .whitespaces)
        let nominalWatts = adapterName.flatMap { name -> Int? in
            guard let range = name.range(of: #"^\d+"#, options: .regularExpression) else { return nil }
            return Int(name[range])
        }

        let permanentFailure = (int(top["PermanentFailureStatus"]) ?? 0) != 0
        let rawTimeRemaining = int(top["TimeRemaining"])

        return BatterySnapshot(
            updatedAt: Date(),
            chargePercent: int(top["CurrentCapacity"]) ?? 0,
            healthPercent: health,
            maxCapacityMAh: rawMax,
            designCapacityMAh: design,
            cycleCount: int(top["CycleCount"]),
            designCycleCount: int(top["DesignCycleCount9C"]),
            // 3047 → 30.47 °C (hundredths of a degree Celsius).
            temperatureC: int(top["Temperature"]).map { Double($0) / 100 },
            voltageV: int(top["Voltage"]).map { Double($0) / 1000 },
            amperageMA: int(top["InstantAmperage"]) ?? int(top["Amperage"]),
            isCharging: bool(top["IsCharging"]),
            externalConnected: bool(top["ExternalConnected"]),
            fullyCharged: bool(top["FullyCharged"]),
            // 65535 = "unknown"; always the case on the adapter.
            timeRemainingMin: (rawTimeRemaining == 65535 || rawTimeRemaining == 0) ? nil : rawTimeRemaining,
            adapterWatts: nominalWatts ?? inner(adapter, "Watts").flatMap { Int($0) },
            adapterName: adapterName,
            // Telemetry uses the same unsigned encoding; parsed with a plain
            // `Double()`, the 2^64 wraparound lands straight on the card.
            systemPowerW: int(inner(telemetry, "SystemPowerIn")).map { Double($0) / 1000 },
            batteryPowerW: int(inner(telemetry, "BatteryPower")).map { Double($0) / 1000 },
            lowPowerMode: readLowPowerMode() ?? false,
            condition: permanentFailure ? "Service Recommended" : "Normal",
            permanentFailure: permanentFailure
        )
    }

    /// `pmset -g` → ` lowpowermode         0`.
    static func readLowPowerMode() -> Bool? {
        let out = Shell.run("/usr/bin/pmset", ["-g"]).out
        for line in out.split(separator: "\n") where line.contains("lowpowermode") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return nil
    }

    // MARK: - Parsing

    /// Only top-level `"Key" = value` lines. Nested dictionaries are on one
    /// line, so they come through whole as the value.
    private static func topLevelFields(_ text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let eq = line.range(of: "\" = ") else { continue }
            let namePart = line[line.startIndex..<eq.lowerBound]
            guard let quote = namePart.lastIndex(of: "\"") else { continue }
            let key = String(namePart[namePart.index(after: quote)...])
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            fields[key] = String(line[eq.upperBound...])
        }
        return fields
    }

    /// One field from a nested dictionary (the space-less `"Key"=value` form).
    private static func inner(_ dict: String?, _ key: String) -> String? {
        guard let dict, let range = dict.range(of: "\"\(key)\"=") else { return nil }
        let rest = dict[range.upperBound...]
        let value = rest.prefix { $0 != "," && $0 != "}" && $0 != ")" }
        return unquote(String(value))
    }

    private static func unquote(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        if t.hasPrefix("\"") && t.hasSuffix("\"") && t.count >= 2 {
            return String(t.dropFirst().dropLast())
        }
        return t
    }

    /// ioreg prints negative numbers as UNSIGNED 64-bit: −615 mA comes out as
    /// `18446744073709551001`, −7568 mW as `18446744073709544048` (measured;
    /// `"SystemLoad"=7568` in the same dictionary confirms it exactly).
    /// Dropping the overflowing value wasn't enough: the current field stayed
    /// empty, and telemetry parsed with `Double()` put −1.8×10¹⁶ W on the card.
    /// Convert back via two's complement.
    private static func int(_ s: String?) -> Int? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let value = Int(s) { return value }
        guard let unsigned = UInt64(s) else { return nil }
        return Int(Int64(bitPattern: unsigned))
    }

    private static func bool(_ s: String?) -> Bool {
        s?.trimmingCharacters(in: .whitespaces) == "Yes"
    }
}

/// Menu bar agent: measures the battery once a minute and writes the file the
/// system widget's battery row reads.
@MainActor
final class BatteryAgent: ObservableObject {
    @Published var snapshot: BatterySnapshot = BatteryStore.load() ?? .empty

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .refreshAllWidgets, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        refresh()
        // Charge moves about a point a minute; measuring more often buys nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refresh() {
        Task.detached(priority: .utility) {
            let fresh = BatteryCollector.collect()
            await MainActor.run {
                guard let s = fresh else {
                    var old = self.snapshot
                    old.updatedAt = Date()
                    old.error = String(localized: "battery unreadable")
                    self.publish(old)
                    return
                }
                self.publish(s)
            }
        }
    }

    private func publish(_ s: BatterySnapshot) {
        snapshot = s
        BatteryStore.save(s, mirrorToWidgetContainer: true)
        WidgetCenter.shared.reloadTimelines(ofKind: "SystemMetricsWidget")
    }
}

