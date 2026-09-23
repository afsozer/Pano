import WidgetKit
import SwiftUI

// MARK: - Nano-GPT balance widget
//
// Quota cards come with a ready-made percentage for the dial. Nano-GPT is
// prepaid: all we have is dollars. To draw a graph we pick a fixed scale
// ($10 = full bar by default, configurable). The bar drops with the balance;
// above the scale it stays full and changes COLOUR, otherwise a $40 account
// and a $10 account would look the same.
//
// Layout mirrors the storage card: dial on the left, capacity bar and
// breakdown rows on the right. Like disk space, a balance is a capacity, not
// a load.
//
// The breakdown rows (today's spend, 30-day total, most used model) come from
// the `api/v1/usage` endpoint: real counted figures, not estimated from
// balance deltas.

struct NanoGPTEntry: TimelineEntry {
    let date: Date
    let balance: NanoGPTSnapshot?
}

struct NanoGPTProvider: TimelineProvider {
    func placeholder(in context: Context) -> NanoGPTEntry {
        NanoGPTEntry(date: Date(), balance: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (NanoGPTEntry) -> Void) {
        completion(NanoGPTEntry(date: Date(),
                                balance: NanoGPTStore.load() ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NanoGPTEntry>) -> Void) {
        let now = Date()
        let entry = NanoGPTEntry(date: now, balance: NanoGPTStore.load())
        // The app reloads timelines after every fetch; 15 minutes is only a
        // fallback while the app isn't running.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900))))
    }

    static var sample: NanoGPTSnapshot {
        var snapshot = NanoGPTSnapshot(updatedAt: Date(), usdBalance: 3.42,
                                       pendingUsd: nil, nanoBalance: 0, error: nil)
        snapshot.todaySpendUsd = 0.93
        snapshot.todayRequests = 57
        snapshot.windowSpendUsd = 2.38
        snapshot.windowRequests = 236
        snapshot.windowDays = 30
        snapshot.topModel = "GLM 5 Flash"
        snapshot.topModelRequests = 220
        snapshot.topModelSpendUsd = 2.31
        return snapshot
    }
}

struct SmallNanoGPTView: View {
    let balance: NanoGPTSnapshot

    var body: some View {
        // Storage card's small layout: the dial shows the ratio, the big
        // number next to it answers the real question — how many dollars left.
        let color = balanceColor(balance)
        VStack(alignment: .leading, spacing: 4) {
            HeaderRow(accent: nanoAccent, title: "Nano-GPT",
                      chip: balance.isOverflow ? balance.overflowChip : nil,
                      chipColor: nanoOverflowAccent,
                      stale: balance.isStale)
            Spacer(minLength: 2)
            HStack(spacing: 9) {
                GaugeDial(value: balance.fillPercent, label: balance.scaleLabel, color: color,
                          diameter: 56, numberSize: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(usdLabel(balance.usdBalance ?? 0))
                        .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.6)
                    Text("balance")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 2)
            VStack(alignment: .leading, spacing: 5) {
                CapacityBar(usedPercent: balance.fillPercent, purgeablePercent: 0,
                            color: color, height: 7)
                // Don't repeat what dial and bar already show: this line only
                // carries what is visible nowhere else — today's spend, or
                // failing that, what the scale is.
                HStack(spacing: 4) {
                    Text(balance.todayLine ?? balance.scaleText)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.55)
            }
        }
    }
}

struct MediumNanoGPTView: View {
    let balance: NanoGPTSnapshot

    var body: some View {
        let color = balanceColor(balance)
        VStack(alignment: .leading, spacing: 6) {
            HeaderRow(accent: nanoAccent, title: "Nano-GPT",
                      chip: balance.isOverflow ? balance.overflowChip : nil,
                      chipColor: nanoOverflowAccent,
                      trailing: balance.updatedAt.formatted(date: .omitted, time: .shortened),
                      stale: balance.isStale)
            HStack(spacing: 12) {
                GaugeDial(value: balance.fillPercent, label: balance.scaleLabel, color: color,
                          diameter: 78, numberSize: 22)
                    .padding(.leading, 2)
                VStack(alignment: .leading, spacing: 8) {
                    CapacityBar(usedPercent: balance.fillPercent, purgeablePercent: 0,
                                color: color, height: 10)
                    VStack(spacing: 5) {
                        LegendRow(swatch: color, label: String(localized: "Balance left"),
                                  value: usdLabel(balance.usdBalance ?? 0), emphasized: true)
                        // Spend rows come from the usage endpoint; if it fails
                        // they show a dash and the balance is still visible.
                        LegendRow(swatch: color.opacity(0.38), label: balance.todayLabel,
                                  value: balance.todayValue)
                        LegendRow(swatch: nanoAccent.opacity(0.18), label: balance.windowLabel,
                                  value: balance.windowValue)
                    }
                    HStack(spacing: 4) {
                        Text(balance.topModelLine ?? balance.scaleText)
                        if let pending = balance.pendingUsd, pending > 0 {
                            Text("· \(usdLabel(pending)) pending")
                        }
                        if let error = balance.error {
                            Text("· \(error)").foregroundStyle(.orange)
                        } else if balance.usageError != nil, balance.topModel == nil {
                            Text("· usage unavailable").foregroundStyle(.orange)
                        }
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

struct NanoGPTWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NanoGPTEntry

    var body: some View {
        Group {
            // No balance ever read → empty state. Drawing an empty bar would
            // claim "zero dollars" when we simply don't know.
            if let balance = entry.balance, balance.usdBalance != nil {
                if family == .systemSmall {
                    SmallNanoGPTView(balance: balance)
                } else {
                    MediumNanoGPTView(balance: balance)
                }
            } else {
                EmptyStateView(message: entry.balance?.emptyMessage ?? NanoGPTSnapshot.empty.emptyMessage)
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                LinearGradient(colors: [nanoAccent.opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

struct NanoGPTWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NanoGPTWidget", provider: NanoGPTProvider()) { entry in
            NanoGPTWidgetView(entry: entry)
        }
        .configurationDisplayName("Nano-GPT balance")
        .description("Prepaid balance left, today's spend and your most used model.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
