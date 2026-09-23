import Darwin
import Foundation
import IOKit
import WidgetKit

/// Mutable (CPU tick history), but only ever used from `SystemMetricsAgent`'s
/// serial queue.
final class SystemMetricsCollector: @unchecked Sendable {
    private var previousCPUTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    /// Neither changes while the app runs; read once.
    private let chipName = SystemMetricsCollector.readChipName()
    private let modelName = SystemMetricsCollector.readModelName()

    func collect() -> SystemMetricsSnapshot {
        let cpu = cpuUsage()
        let memory = memoryUsage()
        let cpuTemperature = validTemperature(SMCReadAverageCPUTemperature())
        let gpuTemperature = validTemperature(SMCReadAverageGPUTemperature())
        return SystemMetricsSnapshot(
            updatedAt: Date(),
            cpuUsedPercent: cpu,
            gpuUsedPercent: gpuUsage(),
            memoryUsedBytes: memory.used,
            memoryTotalBytes: memory.total,
            swapUsedBytes: swapUsage(),
            cpuTemperature: cpuTemperature,
            gpuTemperature: gpuTemperature,
            thermalState: thermalStateToken,
            chipName: chipName,
            modelName: modelName
        )
    }

    /// GPU load: "Device Utilization %" from the IOAccelerator service's
    /// PerformanceStatistics dictionary. No root needed; if there are several
    /// accelerators the highest value wins.
    private func gpuUsage() -> Double? {
        guard let matching = IOServiceMatching("IOAccelerator") else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                             kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
                  let value = stats["Device Utilization %"] as? NSNumber else { continue }
            let percent = value.doubleValue
            if percent >= 0, percent <= 100 { best = max(best ?? 0, percent) }
        }
        return best
    }

    /// The SMC bridge returns NaN when no sensor is available (e.g. Intel Macs);
    /// NaN fails the range check and becomes nil, which the widget shows as "—".
    private func validTemperature(_ value: Double) -> Double? {
        (10...120).contains(value) ? value : nil
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let current = (
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return 0 }
        let user = current.user &- previous.user
        let system = current.system &- previous.system
        let idle = current.idle &- previous.idle
        let nice = current.nice &- previous.nice
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return min(100, Double(user + system + nice) / Double(total) * 100)
    }

    private func memoryUsage() -> (used: UInt64, total: UInt64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard result == KERN_SUCCESS else { return (0, total) }
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        // Close to Activity Monitor's "Memory Used": active + wired + compressed.
        let pages = UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return (min(total, pages * UInt64(pageSize)), total)
    }

    private func swapUsage() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = sysctlbyname("vm.swapusage", &usage, &size, nil, 0)
        return result == 0 ? usage.xsu_used : 0
    }

    /// Stored as a locale-neutral token; the widget turns it into a label.
    private var thermalStateToken: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return SystemMetricsSnapshot.Thermal.nominal
        case .fair: return SystemMetricsSnapshot.Thermal.fair
        case .serious: return SystemMetricsSnapshot.Thermal.serious
        case .critical: return SystemMetricsSnapshot.Thermal.critical
        @unknown default: return "—"
        }
    }

    /// "Apple M5" → "M5". Intel brand strings are too long for the header chip,
    /// so they yield nil.
    private static func readChipName() -> String? {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else { return nil }
        let brand = String(cString: buffer)
        guard brand.hasPrefix("Apple ") else { return nil }
        return String(brand.dropFirst("Apple ".count))
    }

    /// Marketing name without the size/chip suffix: "MacBook Pro (14-inch, M5)"
    /// → "MacBook Pro". Apple Silicon publishes it in the device tree under
    /// /product; `hw.model` ("Mac17,2") is not human-readable on newer models.
    private static func readModelName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString,
                                                        kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let raw = String(decoding: data, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        let name = raw.components(separatedBy: " (").first?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }
}

@MainActor
final class SystemMetricsAgent {
    private let collector = SystemMetricsCollector()
    /// Collection runs off the main thread: the first SMC read enumerates the
    /// whole key table (~0.5 s). Serial, because the collector keeps CPU tick state.
    private let queue = DispatchQueue(label: "SystemMetricsAgent", qos: .utility)
    private var timer: Timer?
    private var refreshObserver: NSObjectProtocol?

    init() {
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .refreshAllWidgets, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        // CPU load needs two tick samples; take the first real reading shortly after launch.
        Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
    }

    private func refresh() {
        let collector = collector
        queue.async {
            let snapshot = collector.collect()
            _ = SystemMetricsStore.save(snapshot, mirrorToWidgetContainer: true)
            WidgetCenter.shared.reloadTimelines(ofKind: "SystemMetricsWidget")
        }
    }
}
