import AppKit
import SwiftUI

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

// PANO_PREVIEW_SAMPLE=1: never touch a live store (used to render README
// screenshots without leaking personal data). Every `.load()` below is
// guarded by this flag, and "live" variants are skipped entirely.
let sampleMode = ProcessInfo.processInfo.environment["PANO_PREVIEW_SAMPLE"] == "1"

let snap = sampleMode ? nil : SnapshotStore.load()
@MainActor func render<V: View>(_ view: V, size: CGSize, to path: String) {
    let renderer = ImageRenderer(content:
        view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark))
    renderer.scale = 2
    guard let img = renderer.nsImage,
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("render fail \(path)"); return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

MainActor.assumeIsolated {
render(HStack(spacing: 12) {
    ForEach([0, 25, 50, 75, 100], id: \.self) { percent in
        GaugeDial(value: Double(percent), label: "USED", color: .teal,
                  diameter: 78, numberSize: 22)
    }
}, size: CGSize(width: 454, height: 94), to: "out-gauge-levels.png")
render(HStack(spacing: 12) {
    ForEach([1, 4, 70, 96, 100], id: \.self) { percent in
        GaugeDial(value: Double(percent), label: "USED", color: .teal,
                  diameter: 78, numberSize: 22)
    }
}, size: CGSize(width: 454, height: 94), to: "out-gauge-seam.png")
var claudeEntry: UsageEntry!
var codexEntry: UsageEntry!
for key in ProviderKey.allCases {
    let entry = UsageEntry(date: Date(), providerKey: key,
                           usage: sampleMode ? UsageProvider.sample(key) : snap?.providers[key.rawValue])
    if key == .claude { claudeEntry = entry }
    if key == .codex { codexEntry = entry }
    // macOS medium ~329x155, small ~155x155; the system adds ~16pt inner padding.
    render(MediumUsageView(entry: entry), size: CGSize(width: 297, height: 123), to: "out-medium-\(key.rawValue).png")
    render(SmallUsageView(entry: entry), size: CGSize(width: 123, height: 123), to: "out-small-\(key.rawValue).png")
}
let system = sampleMode ? SystemMetricsProvider.sample : (SystemMetricsStore.load() ?? SystemMetricsProvider.sample)
let systemBattery = sampleMode ? SystemMetricsProvider.sampleBattery : (BatteryStore.load() ?? SystemMetricsProvider.sampleBattery)
render(MediumSystemMetricsView(metrics: system, battery: systemBattery), size: CGSize(width: 297, height: 123), to: "out-medium-system.png")
render(SmallSystemMetricsView(metrics: system), size: CGSize(width: 123, height: 123), to: "out-small-system.png")
var adapterBattery = SystemMetricsProvider.sampleBattery
adapterBattery.externalConnected = true
adapterBattery.systemPowerW = 37.5
var staleBattery = SystemMetricsProvider.sampleBattery
staleBattery.updatedAt = Date().addingTimeInterval(-600)
var hotBattery = SystemMetricsProvider.sampleBattery
hotBattery.temperatureC = 46
hotBattery.batteryPowerW = -123.4
var invalidBattery = SystemMetricsProvider.sampleBattery
invalidBattery.batteryPowerW = 18_446_744_073_709_544
invalidBattery.amperageMA = nil
var failedBattery = SystemMetricsProvider.sampleBattery
failedBattery.error = "battery unreadable"
let systemBatteryStates: [(String, BatterySnapshot?)] = [
    ("battery", SystemMetricsProvider.sampleBattery), ("adapter", adapterBattery),
    ("missing", nil), ("stale", staleBattery), ("hot", hotBattery),
    ("invalid", invalidBattery), ("failed", failedBattery),
]
for (tag, snapshot) in systemBatteryStates {
    render(MediumSystemMetricsView(metrics: system, battery: snapshot),
           size: CGSize(width: 297, height: 123), to: "out-medium-system-\(tag).png")
}
let storage = sampleMode ? StorageProvider.sample : (StorageStore.load() ?? StorageProvider.sample)
render(MediumStorageView(storage: storage), size: CGSize(width: 297, height: 123), to: "out-medium-storage.png")
render(SmallStorageView(storage: storage), size: CGSize(width: 123, height: 123), to: "out-small-storage.png")
for (tag, on) in [("on", true), ("off", false)] {
    var g = sampleMode ? SleepGuardProvider.sample : (SleepGuardStore.load() ?? SleepGuardProvider.sample)
    g.enabled = on; g.pendingEnabled = nil; g.pendingSince = nil
    render(MediumSleepGuardView(state: g), size: CGSize(width: 297, height: 123), to: "out-medium-sleepguard-\(tag).png")
    render(SmallSleepGuardView(state: g), size: CGSize(width: 123, height: 123), to: "out-small-sleepguard-\(tag).png")
}
// Second toggle (`pmset -c sleep`) has three states: lid guard only, both
// guards, and the AC toggle pending. The on/off pair above cycles
// disablesleep; these cycle the AC profile — only here can we see whether
// both toggles fit on the small card.
for (tag, lid, acOn, acPending) in [("ac", false, true, false),
                                    ("both", true, true, false),
                                    ("ac-pending", false, false, true)] {
    var g = sampleMode ? SleepGuardProvider.sample : (SleepGuardStore.load() ?? SleepGuardProvider.sample)
    g.enabled = lid; g.acIdleAwake = acOn
    g.pendingEnabled = nil; g.pendingSince = nil
    g.pendingACIdleAwake = acPending ? true : nil
    g.pendingACIdleSince = acPending ? Date() : nil
    render(MediumSleepGuardView(state: g), size: CGSize(width: 297, height: 123), to: "out-medium-sleepguard-\(tag).png")
    render(SmallSleepGuardView(state: g), size: CGSize(width: 123, height: 123), to: "out-small-sleepguard-\(tag).png")
}

// Nano-GPT balance: the real nanogpt.json if present, plus every threshold
// with a fake snapshot. The bar's colour and the truncation of the breakdown
// lines can only be seen this way — the live balance is only ever at one
// threshold at a time.
func nanoSample(_ usd: Double?, usage: Bool = true, model: String? = nil,
                error: String? = nil, usageError: String? = nil) -> NanoGPTSnapshot {
    var s = NanoGPTProvider.sample
    s.usdBalance = usd
    s.error = error
    s.usageError = usageError
    if let model { s.topModel = model }
    if !usage {
        s.todaySpendUsd = nil; s.todayRequests = nil
        s.windowSpendUsd = nil; s.windowRequests = nil
        s.topModel = nil; s.topModelRequests = nil; s.topModelSpendUsd = nil
    }
    return s
}
var nanoStates: [(String, NanoGPTSnapshot)] = sampleMode ? [] : [
    ("live", NanoGPTStore.load() ?? NanoGPTProvider.sample),
]
nanoStates += [
    ("empty", nanoSample(0.42)),
    ("low", nanoSample(1.84)),
    ("normal", NanoGPTProvider.sample),
    ("full", nanoSample(9.95)),
    ("overflow", nanoSample(42.60)),
    ("longmodel", nanoSample(3.42, model: "Qwen 3.8 27B Uncensored Thinking (oMLX)")),
    ("nousage", nanoSample(3.42, usage: false, usageError: "HTTP 429")),
    ("error", nanoSample(3.42, error: "HTTP 401")),
]
var noKeyState = nanoSample(nil)
noKeyState.missingKey = true
nanoStates.append(("nodata", noKeyState))
for (tag, nano) in nanoStates {
    if nano.usdBalance == nil {
        render(EmptyStateView(message: nano.emptyMessage),
               size: CGSize(width: 297, height: 123), to: "out-medium-nanogpt-\(tag).png")
    } else {
        render(MediumNanoGPTView(balance: nano), size: CGSize(width: 297, height: 123),
               to: "out-medium-nanogpt-\(tag).png")
        render(SmallNanoGPTView(balance: nano), size: CGSize(width: 123, height: 123),
               to: "out-small-nanogpt-\(tag).png")
    }
}

// Bridge card header at small-card width (123 pt): does the dot + name +
// badge + refresh button fit on one line? Three candidates side by side, at
// their real width.

// Local LLM: every state drawn. The live server is only ever in one state at
// a time, so these are fake snapshots — otherwise we'd never see clipped text.
func llmSample(_ mutate: (inout LocalLLMSnapshot) -> Void) -> LocalLLMSnapshot {
    var s = LocalLLMProvider.sample
    mutate(&s)
    return s
}
let llmOff = llmSample { s in
    s.reachable = false; s.serviceRegistered = false
    s.loadedModels = []; s.modelMemoryBytes = 0
    s.uptimeSec = nil; s.contextWindow = nil
    s.avgPrefillTps = nil; s.avgGenerationTps = nil
    s.promptTokens = nil; s.cachedTokens = nil; s.completionTokens = nil
}
let llmIdle = llmSample { s in
    s.loadedModels = []; s.modelMemoryBytes = 0
    s.avgPrefillTps = 0; s.avgGenerationTps = 0
    s.promptTokens = 0; s.cachedTokens = 0; s.completionTokens = 0
    s.uptimeSec = 2_520
}
let llmLoading = llmSample { s in
    s.loadedModels = []; s.loadingCount = 1; s.modelMemoryBytes = 0
    s.avgPrefillTps = 0; s.avgGenerationTps = 0
    s.promptTokens = 0; s.cachedTokens = 0; s.completionTokens = 0
}
let llmReady = LocalLLMProvider.sample
let llmAltModel = llmSample { snapshot in
    let model = "mistral-small-24b-omlx"
    snapshot.selectedModel = model
    snapshot.loadedModels = [model]
    snapshot.availableModels.append(model)
}
let llmGenerating = llmSample { s in
    s.activeRequests = 1; s.waitingRequests = 1
    s.recentGenerationTps = 9.4
}
let llmStates: [(String, LocalLLMSnapshot)] = [
    ("off", llmOff),
    ("idle", llmIdle),
    ("loading", llmLoading),
    ("ready", llmReady),
    ("alt-model", llmAltModel),
    ("generating", llmGenerating),
]
for (tag, llm) in llmStates {
    render(MediumLocalLLMView(llm: llm), size: CGSize(width: 297, height: 123), to: "out-medium-llm-\(tag).png")
    render(SmallLocalLLMView(llm: llm), size: CGSize(width: 123, height: 123), to: "out-small-llm-\(tag).png")
}
calendarLinksDisabled = true
var calStates: [(String, CalendarSnapshot?)] = sampleMode ? [] : [
    ("live", CalendarStore.load()),
]
calStates += [
    ("sample", CalendarProvider.sample),
    ("denied", CalendarSnapshot(updatedAt: Date(), access: .denied, dayCounts: [:], dayColors: [:], upcoming: [], error: nil)),
    ("empty", CalendarSnapshot(updatedAt: Date(), access: .granted, dayCounts: [:], dayColors: [:], upcoming: [], error: nil)),
]
for (tag, cal) in calStates {
    render(MediumCalendarView(snapshot: cal, date: Date()), size: CGSize(width: 297, height: 123), to: "out-medium-calendar-\(tag).png")
    render(SmallCalendarView(snapshot: cal, date: Date()), size: CGSize(width: 123, height: 123), to: "out-small-calendar-\(tag).png")
}
// Does a six-row month (November 2026: the 1st is a Sunday) fit?
let sixRows = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 12))!
render(SmallCalendarView(snapshot: CalendarProvider.sample, date: sixRows), size: CGSize(width: 123, height: 123), to: "out-small-calendar-6rows.png")
render(MediumCalendarView(snapshot: CalendarProvider.sample, date: sixRows), size: CGSize(width: 297, height: 123), to: "out-medium-calendar-6rows.png")

// README gallery: a single composite PNG with every card family laid out on
// a dark background, sample data only. Only rendered in sample mode so no
// personal data (real usage figures, local model names, balances) ever ends
// up in a screenshot meant for the public repo.
if sampleMode {
    struct GalleryTile<Content: View>: View {
        let width: CGFloat
        let height: CGFloat
        let content: Content
        init(width: CGFloat, height: CGFloat, @ViewBuilder content: () -> Content) {
            self.width = width; self.height = height; self.content = content()
        }
        var body: some View {
            content
                .frame(width: width, height: height)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.12)))
        }
    }
    let mediumW: CGFloat = 297, mediumH: CGFloat = 123
    let smallW: CGFloat = 123, smallH: CGFloat = 123
    let gallerySampleCalendar = CalendarProvider.sample
    let galleryView = VStack(spacing: 12) {
        HStack(spacing: 12) {
            GalleryTile(width: mediumW, height: mediumH) { MediumUsageView(entry: claudeEntry) }
            GalleryTile(width: smallW, height: smallH) { SmallUsageView(entry: codexEntry) }
            GalleryTile(width: smallW, height: smallH) { SmallSystemMetricsView(metrics: system) }
        }
        HStack(spacing: 12) {
            GalleryTile(width: mediumW, height: mediumH) { MediumSystemMetricsView(metrics: system, battery: systemBattery) }
            GalleryTile(width: smallW, height: smallH) { SmallStorageView(storage: storage) }
            GalleryTile(width: smallW, height: smallH) { SmallCalendarView(snapshot: gallerySampleCalendar, date: Date()) }
        }
        HStack(spacing: 12) {
            GalleryTile(width: mediumW, height: mediumH) { MediumLocalLLMView(llm: llmGenerating) }
            GalleryTile(width: smallW, height: smallH) { SmallNanoGPTView(balance: NanoGPTProvider.sample) }
            GalleryTile(width: smallW, height: smallH) { SmallSleepGuardView(state: SleepGuardProvider.sample) }
        }
        HStack(spacing: 12) {
            GalleryTile(width: mediumW, height: mediumH) { MediumCalendarView(snapshot: gallerySampleCalendar, date: Date()) }
            GalleryTile(width: mediumW, height: mediumH) { MediumStorageView(storage: storage) }
        }
    }
    .padding(20)
    .background(Color(white: 0.05))
    // Two medium tiles (329 each + 12pt gap) are the widest row; every
    // narrower row is centered under it by the VStack's default alignment.
    let galleryWidth: CGFloat = 2 * (mediumW + 32) + 12 + 40
    let galleryHeight: CGFloat = 4 * (smallH + 32) + 3 * 12 + 40
    render(galleryView, size: CGSize(width: galleryWidth, height: galleryHeight), to: "gallery.png")
}
}
