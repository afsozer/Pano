import Foundation

struct SystemMetricsSnapshot: Codable, Hashable {
    var updatedAt: Date
    var cpuUsedPercent: Double
    /// From IOAccelerator's PerformanceStatistics; nil if unreadable.
    var gpuUsedPercent: Double?
    var memoryUsedBytes: UInt64
    var memoryTotalBytes: UInt64
    var swapUsedBytes: UInt64
    /// nil when the SMC has no usable sensor (e.g. Intel Macs).
    var cpuTemperature: Double?
    var gpuTemperature: Double?
    /// One of the `Thermal` tokens; localized only at display time.
    var thermalState: String
    /// "M5"; nil on Intel.
    var chipName: String? = nil
    /// "MacBook Pro"; nil if the device tree has no product name.
    var modelName: String? = nil

    enum Thermal {
        static let nominal = "nominal"
        static let fair = "fair"
        static let serious = "serious"
        static let critical = "critical"
    }

    var isThermalNominal: Bool { thermalState == Thermal.nominal }

    var thermalLabel: String {
        switch thermalState {
        case Thermal.nominal: return String(localized: "Normal")
        case Thermal.fair: return String(localized: "Warm")
        case Thermal.serious: return String(localized: "High")
        case Thermal.critical: return String(localized: "Critical")
        default: return thermalState
        }
    }

    var memoryUsedPercent: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return min(100, Double(memoryUsedBytes) / Double(memoryTotalBytes) * 100)
    }

    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 15 * 60 }
}

enum SystemMetricsStore {
    static let fileURL = AppPaths.file("system.json")

    static let widgetContainerFileURL = AppPaths.widgetContainerFile("system.json")

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

    static func load() -> SystemMetricsSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(SystemMetricsSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: SystemMetricsSnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
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
