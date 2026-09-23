import SwiftUI
import WidgetKit
import ServiceManagement

@MainActor
final class PanoAppDelegate: NSObject, NSApplicationDelegate {
    /// Darwin notifications from the widget extension: refresh, sleep guard
    /// on/off, local LLM start/stop/warm up.
    nonisolated private static let darwinNames: [CFNotificationName] = [
        RefreshRequest.darwinName, SleepGuardRequest.enableName, SleepGuardRequest.disableName,
        SleepGuardACIdleRequest.enableName, SleepGuardACIdleRequest.disableName,
        LocalLLMRequest.startName, LocalLLMRequest.stopName, LocalLLMRequest.warmName,
    ]

    private static let darwinCallback: CFNotificationCallback = { _, observer, name, _, _ in
        guard let observer, let name else { return }
        let delegate = Unmanaged<PanoAppDelegate>.fromOpaque(observer).takeUnretainedValue()
        let raw = name.rawValue as String
        DispatchQueue.main.async {
            delegate.deliver(darwinName: raw)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for name in Self.darwinNames {
            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                Self.darwinCallback,
                name.rawValue,
                nil,
                .deliverImmediately
            )
        }
    }

    /// A click on the calendar card arrives here as `pano://calendar?…`.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { CalendarOpener.open($0) }
    }

    private func deliver(darwinName raw: String) {
        if raw == (RefreshRequest.darwinName.rawValue as String) {
            NotificationCenter.default.post(name: .refreshAllWidgets, object: nil)
        } else if raw == (SleepGuardRequest.enableName.rawValue as String) {
            NotificationCenter.default.post(name: .sleepGuardRequested, object: nil, userInfo: ["enable": true])
        } else if raw == (SleepGuardRequest.disableName.rawValue as String) {
            NotificationCenter.default.post(name: .sleepGuardRequested, object: nil, userInfo: ["enable": false])
        } else if raw == (SleepGuardACIdleRequest.enableName.rawValue as String) {
            NotificationCenter.default.post(name: .sleepGuardACIdleRequested, object: nil, userInfo: ["enable": true])
        } else if raw == (SleepGuardACIdleRequest.disableName.rawValue as String) {
            NotificationCenter.default.post(name: .sleepGuardACIdleRequested, object: nil, userInfo: ["enable": false])
        } else if let action = ["start", "stop", "warm"].first(where: {
            raw == (LocalLLMRequest.name(for: $0)?.rawValue as String?)
        }) {
            NotificationCenter.default.post(name: .localLLMActionRequested, object: nil,
                                            userInfo: ["action": action])
        }
    }

    deinit {
        for name in Self.darwinNames {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                name,
                nil
            )
        }
    }
}

extension Notification.Name {
    static let refreshAllWidgets = Notification.Name("Pano.refreshAllWidgets")
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var snapshot: UsageSnapshot = SnapshotStore.load() ?? .empty
    @Published var refreshing = false

    private var timer: Timer?
    private var refreshObserver: NSObjectProtocol?
    /// Claude's /usage endpoint is aggressively rate limited; poll every 5 minutes.
    private let interval: TimeInterval = 300

    init() {
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .refreshAllWidgets, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    deinit {
        if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        var fresh = await UsageFetcher.fetchAll()
        // If a provider failed, don't blank the card: keep the last good values
        // and the old fetchedAt so the widget shows its own "stale" badge.
        // A provider that is now signed out is shown as such, not as stale.
        for (key, old) in snapshot.providers where !old.buckets.isEmpty {
            if var new = fresh.providers[key], new.buckets.isEmpty, new.error != nil,
               new.signedOut != true {
                new.buckets = old.buckets
                new.plan = new.plan ?? old.plan
                new.fetchedAt = old.fetchedAt
                fresh.providers[key] = new
            }
        }
        snapshot = fresh
        SnapshotStore.save(fresh, mirrorToWidgetContainer: true)
        WidgetCenter.shared.reloadAllTimelines()
    }
}

@main
struct PanoApp: App {
    @NSApplicationDelegateAdaptor(PanoAppDelegate.self) private var appDelegate
    @StateObject private var store = UsageStore()
    private let systemMetricsAgent = SystemMetricsAgent()
    private let storageAgent = StorageAgent()
    // Nano-GPT prepaid balance: feeds both the card and the menu panel row.
    @StateObject private var nanoGPT = NanoGPTAgent()
    // Apple Calendar → calendar card; asks for access on first launch.
    private let calendarAgent = CalendarAgent()
    @StateObject private var sleepGuard = SleepGuardAgent()
    // Battery temperature and power data for the system card.
    @StateObject private var battery = BatteryAgent()
    @StateObject private var localLLM = LocalLLMAgent()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store, sleepGuard: sleepGuard, nanoGPT: nanoGPT)
        } label: {
            // One symbol in the menu bar: the needle tracks the fullest quota,
            // details live in the panel. Color is pointless here — the label
            // is drawn as a template image and foregroundStyle is swallowed
            // (measured), so the needle position carries the state.
            Image(systemName: gaugeSymbol)
                .help(tooltip)
        }
        .menuBarExtraStyle(.window)
    }

    /// The fullest window across providers — the menu bar needle follows it.
    private var worstUsage: Double? {
        ProviderKey.allCases.compactMap { store.snapshot.providers[$0.rawValue]?.primary?.usedPercent }.max()
    }

    private var gaugeSymbol: String {
        guard let worst = worstUsage else { return "gauge.with.dots.needle.0percent" }
        switch worst {
        case ..<15: return "gauge.with.dots.needle.0percent"
        case ..<50: return "gauge.with.dots.needle.33percent"
        case ..<85: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    private var tooltip: String {
        let parts = ProviderKey.allCases.compactMap { key -> String? in
            guard let p = store.snapshot.providers[key.rawValue], let b = p.primary else { return nil }
            let name = key.displayName, left = percentText(100 - b.usedPercent), window = b.label
            return String(localized: "\(name): \(left) left (\(window))")
        }
        var lines = parts
        if let usd = nanoGPT.snapshot.usdBalance {
            let amount = usdLabel(usd)
            lines.append(String(localized: "Nano-GPT: \(amount) balance"))
        }
        return lines.isEmpty ? String(localized: "No quota data") : lines.joined(separator: "\n")
    }
}

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var sleepGuard: SleepGuardAgent
    @ObservedObject var nanoGPT: NanoGPTAgent
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Same language as the widgets: REMAINING everywhere.
            Text("quota left")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            ForEach(ProviderKey.allCases, id: \.self) { key in
                if let usage = store.snapshot.providers[key.rawValue] {
                    ProviderBlock(key: key, usage: usage)
                }
            }
            // Nano-GPT is a wallet, not a quota: it gets its own heading so it
            // doesn't blend in with the percentage blocks.
            Text("prepaid balance")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            NanoGPTBlock(balance: nanoGPT.snapshot)
            Divider()
            SleepGuardMenuRow(agent: sleepGuard)
            SleepGuardACIdleMenuRow(agent: sleepGuard)
            Divider()
            // Three controls in one row: refresh, launch at login (on/off), quit.
            HStack(spacing: 4) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.refreshing {
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise").frame(width: 16, height: 16)
                    }
                }
                .disabled(store.refreshing)
                .help(Text("Refresh now"))

                Button {
                    launchAtLogin.toggle()
                    try? launchAtLogin ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                } label: {
                    Image(systemName: launchAtLogin ? "power.circle.fill" : "power.circle")
                        .foregroundStyle(launchAtLogin ? Color.accentColor : Color.secondary)
                        .frame(width: 16, height: 16)
                }
                .help(launchAtLogin ? Text("Launch at login: on") : Text("Launch at login: off"))

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "xmark").frame(width: 16, height: 16)
                }
                .help(Text("Quit"))

                Spacer()
                Text(verbatim: store.snapshot.updatedAt == .distantPast
                     ? "—"
                     : store.snapshot.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .imageScale(.medium)
        }
        .padding(16)
        .frame(width: 320)
    }
}

struct ProviderBlock: View {
    let key: ProviderKey
    let usage: ProviderUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(key.accent).frame(width: 8, height: 8)
                Text(verbatim: usage.name).font(.system(size: 13, weight: .semibold))
                if let plan = usage.plan {
                    Text(verbatim: plan).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if usage.isStale && !usage.isSignedOut {
                    Text("stale").font(.caption2).foregroundStyle(.orange)
                }
            }
            if usage.isSignedOut {
                Text(inlineMarkdown(key.signedOutMessage))
                    .font(.caption).foregroundStyle(.secondary)
            } else if usage.buckets.isEmpty {
                Text(inlineMarkdown(usage.error ?? String(localized: "no data")))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(usage.buckets) { bucket in
                    let remaining = max(0, 100 - bucket.usedPercent)
                    HStack(spacing: 8) {
                        Text(verbatim: bucket.label).font(.caption)
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(width: 84, alignment: .leading)
                        ProgressView(value: min(remaining, 100), total: 100)
                            .tint(remaining < 10 ? .red : (remaining < 25 ? .orange : key.accent))
                        Text(verbatim: percentText(remaining))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .frame(width: 34, alignment: .trailing)
                        Text(verbatim: bucket.resetsAt?.shortCountdown ?? bucket.note ?? "")
                            .font(.caption2).foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                if let err = usage.error {
                    Text(inlineMarkdown(err)).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
    }
}

/// Balance block in the panel: sibling of the quota blocks, but the bar is
/// drawn against the dollar scale, with the balance and today's spend on the right.
struct NanoGPTBlock: View {
    let balance: NanoGPTSnapshot

    /// Footer: today's request count and the most used model; if the usage
    /// endpoint is silent, what the scale is.
    private var detailLine: String {
        var parts: [String] = []
        if let requests = balance.todayRequests {
            let count = requests.formatted()
            parts.append(String(localized: "\(count) requests today"))
        }
        if let top = balance.topModelLine { parts.append(top) }
        return parts.isEmpty ? balance.scaleText : parts.joined(separator: " · ")
    }

    var body: some View {
        let color = balanceColor(balance)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(nanoAccent).frame(width: 8, height: 8)
                Text(verbatim: "Nano-GPT").font(.system(size: 13, weight: .semibold))
                if balance.isOverflow {
                    Text(verbatim: balance.overflowChip).font(.caption2).foregroundStyle(nanoOverflowAccent)
                }
                Spacer()
                if balance.isStale { Text("stale").font(.caption2).foregroundStyle(.orange) }
            }
            if let usd = balance.usdBalance {
                HStack(spacing: 8) {
                    Text("\(balance.scaleLabel) scale").font(.caption).frame(width: 84, alignment: .leading)
                    ProgressView(value: balance.fillPercent, total: 100).tint(color)
                    Text(verbatim: usdLabel(usd))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .frame(width: 46, alignment: .trailing)
                    Text(verbatim: balance.todaySpendUsd.map { "−" + usdLabel($0) } ?? "")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                // Today's spend is already in the column above; this line only
                // carries what isn't there. Model names are long and the panel is
                // 320 pt: repeating the dollar amount would truncate the name.
                Text(verbatim: detailLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            } else {
                Text(verbatim: balance.emptyMessage)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = balance.error, balance.usdBalance != nil {
                Text(verbatim: error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }
        }
    }
}

/// Sleep guard row in the panel: same as the widget's toggle, as a system switch.
struct SleepGuardMenuRow: View {
    @ObservedObject var agent: SleepGuardAgent

    var body: some View {
        let s = agent.snapshot
        HStack(spacing: 8) {
            Image(systemName: s.enabled ? "sun.max.fill" : "moon.zzz.fill")
                .foregroundStyle(s.enabled ? Color.yellow : Color.secondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sleep guard").font(.system(size: 13, weight: .semibold))
                Text(verbatim: s.error ?? (s.enabled ? String(localized: "stays awake with the lid closed")
                                                     : String(localized: "sleeps when the lid closes")))
                    .font(.caption2)
                    .foregroundStyle(s.error == nil ? Color.secondary : Color.orange)
                    .lineLimit(1)
            }
            Spacer()
            if agent.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Toggle("Sleep guard", isOn: Binding(
                get: { s.enabled },
                set: { v in Task { await agent.set(enabled: v) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(agent.busy)
        }
    }
}

/// Second, milder guard: idle sleep on the power-adapter profile only
/// (`pmset -c sleep`). While the switch above is on this has no practical
/// effect — the row says so, but the switch stays usable (the value persists).
struct SleepGuardACIdleMenuRow: View {
    @ObservedObject var agent: SleepGuardAgent

    var body: some View {
        let s = agent.snapshot
        HStack(spacing: 8) {
            Image(systemName: s.acIdleAwake ? "powerplug.fill" : "powerplug")
                .foregroundStyle(s.acIdleAwake ? Color.yellow : Color.secondary)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Stay awake on power").font(.system(size: 13, weight: .semibold))
                Text(verbatim: s.enabled ? String(localized: "the switch above already keeps it awake")
                     : (s.acIdleAwake ? String(localized: "no idle sleep, display still turns off")
                                      : String(localized: "sleeps when idle")))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Toggle("Stay awake on power", isOn: Binding(
                get: { s.acIdleAwake },
                set: { v in Task { await agent.set(acIdleAwake: v) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(agent.busy)
        }
        .opacity(s.enabled ? 0.6 : 1)
    }
}
