import WidgetKit
import SwiftUI

// MARK: - System widget

struct SystemMetricsEntry: TimelineEntry {
    let date: Date
    let metrics: SystemMetricsSnapshot?
    var battery: BatterySnapshot? = nil
}

struct SystemMetricsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SystemMetricsEntry {
        SystemMetricsEntry(date: Date(), metrics: Self.sample, battery: Self.sampleBattery)
    }

    func getSnapshot(in context: Context, completion: @escaping (SystemMetricsEntry) -> Void) {
        completion(SystemMetricsEntry(date: Date(),
                                      metrics: SystemMetricsStore.load() ?? (context.isPreview ? Self.sample : nil),
                                      battery: BatteryStore.load() ?? (context.isPreview ? Self.sampleBattery : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SystemMetricsEntry>) -> Void) {
        let now = Date()
        let entry = SystemMetricsEntry(date: now, metrics: SystemMetricsStore.load(), battery: BatteryStore.load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(60))))
    }

    static let sample = SystemMetricsSnapshot(
        updatedAt: Date(), cpuUsedPercent: 38, gpuUsedPercent: 24,
        memoryUsedBytes: 14_800_000_000, memoryTotalBytes: 32_000_000_000,
        swapUsedBytes: 320_000_000, cpuTemperature: 46, gpuTemperature: 42,
        thermalState: SystemMetricsSnapshot.Thermal.nominal,
        modelName: "MacBook Pro"
    )

    static let sampleBattery = BatterySnapshot(
        updatedAt: Date(), chargePercent: 85, healthPercent: 100,
        temperatureC: 31, voltageV: 12.4, amperageMA: -1000,
        isCharging: false, externalConnected: false, fullyCharged: false,
        batteryPowerW: -12.4, lowPowerMode: false, permanentFailure: false
    )
}

// Quota cards are orange and green; the system card is purple so they don't
// blend together in the widget gallery.
private let systemAccent = Color(red: 0.58, green: 0.44, blue: 0.93)

/// Load color runs OPPOSITE to quota color: little quota left is bad, high load is bad.
func loadColor(_ used: Double, accent: Color) -> Color {
    switch used {
    case 90...: return .red
    case 75..<90: return .orange
    default: return accent
    }
}

private func tempColor(_ celsius: Double?) -> Color {
    guard let celsius else { return .secondary }
    switch celsius {
    case 90...: return .red
    case 75..<90: return .orange
    default: return .primary
    }
}

/// Unitless number: "17 GB/32 GB" didn't fit the small card, "17/32 GB" does.
/// Memory uses binary GiB (as Activity Monitor does) but the familiar "GB" label.
private func byteNumber(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb.formatted(.number.precision(.fractionLength(gb < 10 ? 1 : 0)))
}

private func byteLabel(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb < 1 {
        return "\((Double(bytes) / 1_048_576).formatted(.number.precision(.fractionLength(0)))) MB"
    }
    return "\(byteNumber(bytes)) GB"
}

/// "37°"; "—" when the sensor is unavailable.
private func degrees(_ celsius: Double?) -> String {
    celsius.map { "\(Int($0.rounded()).formatted())°" } ?? "—"
}

struct SmallSystemMetricsView: View {
    let metrics: SystemMetricsSnapshot

    var body: some View {
        // Dial = CPU load, next to it both temperatures, below GPU load and
        // memory. When the thermal state leaves nominal, the header chip turns
        // into a warning.
        VStack(alignment: .leading, spacing: 4) {
            HeaderRow(accent: systemAccent, title: "Mac",
                      chip: metrics.isThermalNominal ? metrics.chipName : metrics.thermalLabel,
                      chipColor: metrics.isThermalNominal ? nil : .orange,
                      stale: metrics.isStale)
            Spacer(minLength: 2)
            HStack(spacing: 9) {
                GaugeDial(value: metrics.cpuUsedPercent, label: "CPU",
                          color: loadColor(metrics.cpuUsedPercent, accent: systemAccent),
                          diameter: 56, numberSize: 18)
                VStack(alignment: .leading, spacing: 5) {
                    TempLine(unit: "CPU", celsius: metrics.cpuTemperature, fontSize: 11.5)
                    TempLine(unit: "GPU", celsius: metrics.gpuTemperature, fontSize: 11.5)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 2)
            VStack(spacing: 6) {
                MeterRow(label: "GPU",
                         fill: metrics.gpuUsedPercent ?? 0,
                         valueText: metrics.gpuUsedPercent.map(percentText) ?? "—",
                         color: loadColor(metrics.gpuUsedPercent ?? 0, accent: systemAccent),
                         trackColor: systemAccent.opacity(0.12),
                         labelWidth: 44, barHeight: 7, fontSize: 11.5)
                // A bare memory number didn't read at a glance: a mini dial now
                // draws the fill, and moving the number onto a full-width row
                // stopped it from being clipped.
                HStack(spacing: 5) {
                    MiniDial(value: metrics.memoryUsedPercent,
                             color: loadColor(metrics.memoryUsedPercent, accent: systemAccent),
                             diameter: 15)
                    Text("Memory")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Text(verbatim: "\(byteNumber(metrics.memoryUsedBytes))/\(byteLabel(metrics.memoryTotalBytes))")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
            }
        }
    }
}

/// "🌡 CPU 37°" — temperatures look the same everywhere: thermometer + unit + value.
struct TempLine: View {
    let unit: String
    let celsius: Double?
    var fontSize: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "thermometer.medium")
                .font(.system(size: fontSize - 1))
            Text(verbatim: unit)
                .font(.system(size: fontSize))
            Text(verbatim: degrees(celsius))
                .font(.system(size: fontSize + 1, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(tempColor(celsius) == .primary ? AnyShapeStyle(.secondary)
                                                        : AnyShapeStyle(tempColor(celsius)))
        .lineLimit(1).minimumScaleFactor(0.6)
    }
}

struct SystemBatteryRow: View {
    let battery: BatterySnapshot?

    private var freshBattery: BatterySnapshot? {
        guard let battery, !battery.isStale, battery.error == nil else { return nil }
        return battery
    }

    private var power: Double? {
        guard let battery = freshBattery,
              let value = battery.externalConnected ? battery.systemPowerW : battery.dischargeW,
              value.isFinite, (0...BatterySnapshot.plausibleWattCeiling).contains(value) else { return nil }
        return value
    }

    private var temperature: Double? {
        guard let value = freshBattery?.temperatureC, value.isFinite else { return nil }
        return value
    }

    /// What the wattage means: wall input on the adapter, drain on battery.
    private var sourceLabel: String {
        guard let battery = freshBattery else { return String(localized: "power") }
        return battery.externalConnected ? String(localized: "adapter") : String(localized: "drain")
    }

    private var temperatureColor: Color {
        guard let temperature else { return .secondary }
        if temperature >= 45 { return .red }
        if temperature >= 40 { return .orange }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 4) {
            Text("Battery")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(verbatim: sourceLabel)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(verbatim: power.map { "\($0.formatted(.number.precision(.fractionLength(1)))) W" } ?? "— W")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 2) {
                Image(systemName: "thermometer.medium")
                    .font(.system(size: 10.5))
                Text(verbatim: degrees(temperature))
                    .font(.system(size: 11.5).monospacedDigit())
            }
            .foregroundStyle(temperatureColor)
            .frame(width: 42, alignment: .trailing)
        }
        .lineLimit(1).minimumScaleFactor(0.8)
    }
}

struct MediumSystemMetricsView: View {
    let metrics: SystemMetricsSnapshot
    var battery: BatterySnapshot? = nil

    var body: some View {
        // Same layout as the medium quota cards. One row per unit: load in the
        // bar, temperature in the tail, with the same thermometer for CPU and GPU.
        VStack(alignment: .leading, spacing: 6) {
            HeaderRow(accent: systemAccent, title: metrics.modelName ?? "Mac", chip: metrics.chipName,
                      trailing: metrics.updatedAt.formatted(date: .omitted, time: .shortened),
                      stale: metrics.isStale)
            HStack(spacing: 12) {
                GaugeDial(value: metrics.cpuUsedPercent, label: "CPU",
                          color: loadColor(metrics.cpuUsedPercent, accent: systemAccent),
                          diameter: 78, numberSize: 22)
                    .padding(.leading, 2)
                VStack(spacing: 6) {
                    MeterRow(label: "CPU",
                             fill: metrics.cpuUsedPercent,
                             valueText: percentText(metrics.cpuUsedPercent),
                             trailingText: degrees(metrics.cpuTemperature),
                             color: loadColor(metrics.cpuUsedPercent, accent: systemAccent),
                             trackColor: systemAccent.opacity(0.12),
                             labelWidth: 46, barHeight: 10, fontSize: 12,
                             trailingWidth: 42,
                             emphasized: true,
                             trailingColor: tempColor(metrics.cpuTemperature) == .primary
                                ? .secondary : tempColor(metrics.cpuTemperature),
                             trailingIcon: "thermometer.medium")
                    MeterRow(label: "GPU",
                             fill: metrics.gpuUsedPercent ?? 0,
                             valueText: metrics.gpuUsedPercent.map(percentText) ?? "—",
                             trailingText: degrees(metrics.gpuTemperature),
                             color: loadColor(metrics.gpuUsedPercent ?? 0, accent: systemAccent),
                             trackColor: systemAccent.opacity(0.12),
                             labelWidth: 46, barHeight: 10, fontSize: 12,
                             trailingWidth: 42,
                             trailingColor: tempColor(metrics.gpuTemperature) == .primary
                                ? .secondary : tempColor(metrics.gpuTemperature),
                             trailingIcon: "thermometer.medium")
                    SystemBatteryRow(battery: battery)
                    // Memory as on the small card: the mini dial draws the fill,
                    // the number is used/total. CPU/GPU are loads (bars), memory
                    // is a capacity (dial + absolute value).
                    HStack(spacing: 6) {
                        MiniDial(value: metrics.memoryUsedPercent,
                                 color: loadColor(metrics.memoryUsedPercent, accent: systemAccent),
                                 diameter: 18)
                        Text("Memory")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        // Same order as the rows above: main value first, the
                        // secondary number at the right edge (where temperature sits).
                        Text(verbatim: "\(byteNumber(metrics.memoryUsedBytes))/\(byteLabel(metrics.memoryTotalBytes))")
                            .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text(verbatim: percentText(metrics.memoryUsedPercent))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .trailing)
                    }
                    // Right-align with the temperature column of the rows above.
                    .padding(.trailing, 6)
                    HStack(spacing: 4) {
                        Text("swap \(byteLabel(metrics.swapUsedBytes))")
                        Text("· thermal")
                        Text(verbatim: metrics.thermalLabel)
                            .fontWeight(.medium)
                            .foregroundStyle(metrics.isThermalNominal ? Color.secondary : Color.orange)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct SystemMetricsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SystemMetricsEntry

    var body: some View {
        Group {
            if let metrics = entry.metrics {
                if family == .systemSmall {
                    SmallSystemMetricsView(metrics: metrics)
                } else {
                    MediumSystemMetricsView(metrics: metrics, battery: entry.battery)
                }
            } else {
                EmptyStateView(message: String(localized: "Waiting for system data — launch Pano"))
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                LinearGradient(colors: [systemAccent.opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

struct SystemMetricsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SystemMetricsWidget", provider: SystemMetricsProvider()) { entry in
            SystemMetricsWidgetView(entry: entry)
        }
        .configurationDisplayName("Mac System Usage")
        .description("CPU, GPU, memory and temperatures; battery temperature and power on the medium size.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
