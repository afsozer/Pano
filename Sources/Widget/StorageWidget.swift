import WidgetKit
import SwiftUI

// MARK: - Storage widget
//
// Why a separate card: CPU/GPU/memory change by the second and answer "what's
// happening right now". Disk usage barely moves for weeks and answers "how much
// room do I have left". On the same card it was a dead row next to live ones.

struct StorageEntry: TimelineEntry {
    let date: Date
    let storage: StorageSnapshot?
}

struct StorageProvider: TimelineProvider {
    func placeholder(in context: Context) -> StorageEntry {
        StorageEntry(date: Date(), storage: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (StorageEntry) -> Void) {
        completion(StorageEntry(date: Date(), storage: StorageStore.load() ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StorageEntry>) -> Void) {
        let now = Date()
        let entry = StorageEntry(date: now, storage: StorageStore.load())
        // While the app runs it calls reloadTimelines every 5 minutes; these
        // 15 minutes are the fallback when it doesn't.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900))))
    }

    static let sample = StorageSnapshot(
        updatedAt: Date(), volumeName: "Macintosh HD", format: "APFS",
        totalBytes: 994_611_000_000, availableBytes: 598_780_000_000,
        freeBytes: 595_300_000_000
    )
}

// Each card has its own color so they don't blend in the gallery: quota cards
// orange/green, system purple, storage teal.
private let storageAccent = Color(red: 0.16, green: 0.70, blue: 0.78)

/// Disks are measured in decimal GB (as Finder and "About This Mac" show them);
/// memory's `byteLabel` uses GiB. When both shared one function the card said
/// "926 GB" while Finder said "994.61 GB".
private func diskLabel(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_000_000_000
    func number(_ value: Double, _ digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }
    if gb >= 1000 { return "\(number(gb / 1000, 2)) TB" }
    if gb < 1 { return "\(number(Double(bytes) / 1_000_000, 0)) MB" }
    return "\(number(gb, gb < 10 ? 1 : 0)) GB"
}

/// Shows the disk's three parts in one bar: used (solid), purgeable (faded),
/// free (track). Unlike the load bars, because this is not a load but a
/// capacity split — the visual language of the "About This Mac" storage bar.
struct CapacityBar: View {
    let usedPercent: Double
    let purgeablePercent: Double
    let color: Color
    var height: CGFloat = 10

    var body: some View {
        Capsule().fill(color.opacity(0.12))
            .frame(height: height)
            .overlay(alignment: .leading) {
                GeometryReader { geo in
                    HStack(spacing: 1.5) {
                        Capsule().fill(color)
                            .frame(width: max(height, geo.size.width * min(1, max(0, usedPercent / 100))))
                        // A tiny slice took a pen stroke's width and overstated
                        // itself: below a visible size, don't draw it at all.
                        if purgeablePercent >= 0.4 {
                            Capsule().fill(color.opacity(0.38))
                                .frame(width: max(3, geo.size.width * min(1, purgeablePercent / 100)))
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: height)
                }
            }
    }
}

/// Legend row below the bar: color dot, name, value on the right. Shared by the
/// storage card and the NanoGPT balance card. `label` and `value` are drawn
/// verbatim: pass already localized Strings.
struct LegendRow: View {
    let swatch: Color
    let label: String
    let value: String
    var emphasized: Bool = false
    var fontSize: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(swatch).frame(width: 7, height: 7)
            Text(verbatim: label)
                .font(.system(size: fontSize, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(.system(size: fontSize + 1, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
        }
    }
}

struct SmallStorageView: View {
    let storage: StorageSnapshot

    var body: some View {
        // The dial is the fill ratio; the big number next to it is what people
        // actually want to know: how much room is left. Below: capacity bar and
        // purgeable space.
        VStack(alignment: .leading, spacing: 4) {
            HeaderRow(accent: storageAccent, title: String(localized: "Storage"),
                      chip: storage.format, stale: storage.isStale)
            Spacer(minLength: 2)
            HStack(spacing: 9) {
                GaugeDial(value: storage.usedPercent, label: String(localized: "USED"),
                          color: loadColor(storage.usedPercent, accent: storageAccent),
                          diameter: 56, numberSize: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: diskLabel(storage.availableBytes))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("available")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 2)
            VStack(alignment: .leading, spacing: 5) {
                CapacityBar(usedPercent: storage.usedPercent,
                            purgeablePercent: storage.purgeablePercent,
                            color: loadColor(storage.usedPercent, accent: storageAccent),
                            height: 7)
                // Used space is already in the dial and the bar; both didn't fit
                // in 123 pt (the purgeable label got clipped). This line only
                // carries the number shown nowhere else.
                HStack(spacing: 4) {
                    Text("\(diskLabel(storage.purgeableBytes)) purgeable")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.55)
            }
        }
    }
}

struct MediumStorageView: View {
    let storage: StorageSnapshot

    var body: some View {
        // Same skeleton as the medium system card: dial on the left, breakdown
        // on the right. One capacity bar instead of several, because the three
        // parts are shares of one whole — separate bars would lose the total.
        VStack(alignment: .leading, spacing: 6) {
            HeaderRow(accent: storageAccent, title: storage.volumeName,
                      chip: storage.format,
                      trailing: storage.updatedAt.formatted(date: .omitted, time: .shortened),
                      stale: storage.isStale)
            HStack(spacing: 12) {
                GaugeDial(value: storage.usedPercent, label: String(localized: "USED"),
                          color: loadColor(storage.usedPercent, accent: storageAccent),
                          diameter: 78, numberSize: 22)
                    .padding(.leading, 2)
                VStack(alignment: .leading, spacing: 8) {
                    CapacityBar(usedPercent: storage.usedPercent,
                                purgeablePercent: storage.purgeablePercent,
                                color: loadColor(storage.usedPercent, accent: storageAccent),
                                height: 10)
                    VStack(spacing: 5) {
                        LegendRow(swatch: loadColor(storage.usedPercent, accent: storageAccent),
                                         label: String(localized: "Used"), value: diskLabel(storage.usedBytes),
                                         emphasized: true)
                        LegendRow(swatch: loadColor(storage.usedPercent, accent: storageAccent).opacity(0.38),
                                         label: String(localized: "Purgeable"), value: diskLabel(storage.purgeableBytes))
                        LegendRow(swatch: storageAccent.opacity(0.18),
                                         label: String(localized: "Free"), value: diskLabel(storage.freeBytes))
                    }
                    HStack(spacing: 4) {
                        Text("\(diskLabel(storage.totalBytes)) total")
                        // Finder's "available" includes purgeable space; spelled
                        // out so the card's number matches Finder's.
                        Text("· \(diskLabel(storage.availableBytes)) available")
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

struct StorageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StorageEntry

    var body: some View {
        Group {
            if let storage = entry.storage {
                if family == .systemSmall {
                    SmallStorageView(storage: storage)
                } else {
                    MediumStorageView(storage: storage)
                }
            } else {
                EmptyStateView(message: String(localized: "Waiting for disk data — launch Pano"))
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                LinearGradient(colors: [storageAccent.opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

struct StorageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "StorageWidget", provider: StorageProvider()) { entry in
            StorageWidgetView(entry: entry)
        }
        .configurationDisplayName("Storage")
        .description("Startup disk usage, free and purgeable space.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
