import WidgetKit
import SwiftUI

struct UsageEntry: TimelineEntry {
    let date: Date
    let providerKey: ProviderKey
    let usage: ProviderUsage?
}

struct UsageProvider: TimelineProvider {
    let providerKey: ProviderKey

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), providerKey: providerKey, usage: Self.sample(providerKey))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        let usage = SnapshotStore.load()?.providers[providerKey.rawValue]
        completion(UsageEntry(date: Date(), providerKey: providerKey,
                              usage: usage ?? (context.isPreview ? Self.sample(providerKey) : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let usage = SnapshotStore.load()?.providers[providerKey.rawValue]
        let now = Date()
        // The menu bar app calls reloadAllTimelines on every refresh; these
        // 5-minute steps only keep the countdown ticking and act as a fallback
        // while the app isn't running.
        let entries = (0..<6).map { i in
            UsageEntry(date: now.addingTimeInterval(Double(i) * 300),
                       providerKey: providerKey, usage: usage)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(300))))
    }

    static func sample(_ key: ProviderKey) -> ProviderUsage {
        ProviderUsage(key: key.rawValue, name: key.displayName, plan: "Max 5x",
                      buckets: [
                        UsageBucket(id: "a", label: windowLabel(hours: 5), usedPercent: 24,
                                    resetsAt: Date().addingTimeInterval(3600 * 2), note: nil,
                                    shortLabel: windowShortLabel(hours: 5)),
                        UsageBucket(id: "b", label: windowLabel(days: 7), usedPercent: 31,
                                    resetsAt: Date().addingTimeInterval(86_400 * 4), note: nil,
                                    shortLabel: windowShortLabel(days: 7)),
                      ], error: nil, fetchedAt: Date())
    }
}

struct SmallUsageView: View {
    let entry: UsageEntry

    var body: some View {
        let usage = entry.usage
        VStack(alignment: .leading, spacing: 5) {
            HeaderRow(key: entry.providerKey, usage: usage, compact: true)
            if let hero = usage?.hero, let buckets = usage?.buckets {
                // Fewer bars below → bigger ring: filling the space looks more
                // balanced than spreading it out (see the system card).
                let rest = Array(buckets.filter { $0.id != hero.id }.prefix(2))
                let ringSize: CGFloat = rest.count >= 2 ? 56 : 60
                // As on the system card: split spare space evenly above and
                // below the ring so it doesn't stick to the header.
                Spacer(minLength: 2)
                HStack(spacing: 9) {
                    // The ring is always the 5-hour window; its name goes to the
                    // right, not inside the narrow ring.
                    HeroGauge(bucket: hero, accent: entry.providerKey.accent,
                              diameter: ringSize, numberSize: rest.count >= 2 ? 18 : 20,
                              showsLabel: false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: hero.shortLabel ?? hero.label)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1).minimumScaleFactor(0.6)
                        if let reset = hero.resetsAt {
                            Text(verbatim: "↻ \(countdown(to: reset, from: entry.date))")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1).minimumScaleFactor(0.6)
                        }
                        Text("\(percentText(hero.usedPercent)) used")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 2)
                // The other windows run full width underneath.
                VStack(spacing: rest.count > 1 ? 6 : 8) {
                    ForEach(rest) { b in
                        BucketRow(bucket: b, accent: entry.providerKey.accent, now: entry.date,
                                  labelWidth: 44, barHeight: rest.count > 1 ? 7 : 9,
                                  fontSize: 11.5, showsReset: false, compactLabel: true)
                    }
                }
            } else {
                UsageEmptyState(key: entry.providerKey, usage: usage)
            }
        }
    }
}

struct MediumUsageView: View {
    let entry: UsageEntry

    var body: some View {
        let usage = entry.usage
        VStack(alignment: .leading, spacing: 6) {
            HeaderRow(key: entry.providerKey, usage: usage,
                      trailing: usage.map { $0.fetchedAt.formatted(date: .omitted, time: .shortened) })
            if let buckets = usage?.buckets, let hero = usage?.hero, !buckets.isEmpty {
                // Fewer rows → thicker bars, so neither case leaves dead space
                // at the bottom.
                let dense = buckets.count >= 3
                HStack(spacing: 12) {
                    HeroGauge(bucket: hero, accent: entry.providerKey.accent,
                              diameter: 78, numberSize: 22)
                        .padding(.leading, 2)
                    VStack(spacing: dense ? 11 : 18) {
                        ForEach(buckets) { b in
                            BucketRow(bucket: b, accent: entry.providerKey.accent, now: entry.date,
                                      labelWidth: 60, barHeight: dense ? 9 : 12,
                                      fontSize: dense ? 11.5 : 12.5, emphasized: b.id == hero.id)
                        }
                        if let err = usage?.error {
                            Text(inlineMarkdown(err)).font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(maxHeight: .infinity)
            } else {
                UsageEmptyState(key: entry.providerKey, usage: usage)
            }
        }
    }
}

/// No usable data: a setup hint when the provider isn't signed in on this Mac,
/// otherwise the fetch error, otherwise "is the app running?".
struct UsageEmptyState: View {
    let key: ProviderKey
    let usage: ProviderUsage?

    var body: some View {
        if let usage, usage.isSignedOut {
            EmptyStateView(message: key.signedOutMessage, systemImage: "person.crop.circle.badge.questionmark")
        } else {
            EmptyStateView(message: usage?.error ?? String(localized: "No data — is Pano running?"))
        }
    }
}

struct UsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UsageEntry

    var body: some View {
        Group {
            switch family {
            case .systemSmall: SmallUsageView(entry: entry)
            default: MediumUsageView(entry: entry)
            }
        }
        .containerBackground(for: .widget) {
            // A faint provider-colored gradient over a neutral base: cards
            // stay distinguishable without hurting legibility.
            ZStack {
                Rectangle().fill(.fill.tertiary)
                LinearGradient(colors: [entry.providerKey.accent.opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

// MARK: - Widgets

struct ClaudeUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ClaudeUsageWidget", provider: UsageProvider(providerKey: .claude)) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Claude Code quota")
        .description("Claude Code 5-hour and weekly limit usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct CodexUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CodexUsageWidget", provider: UsageProvider(providerKey: .codex)) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex quota")
        .description("Codex 5-hour and weekly limit usage.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
