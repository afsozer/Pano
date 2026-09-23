import WidgetKit
import SwiftUI

// MARK: - Local LLM widget (oMLX)
//
// Server state at a glance: a filled, glowing pink orb means a model is in
// memory and ready, amber means it's generating, a thin ring means the server
// is up with no model loaded, a grey ring means the server is off. The switch
// starts/stops the service; "warm" loads the selected model into memory.
//
// Pink-magenta is unique in the family: quota cards are orange/green/blue,
// system purple, storage cyan, sleep guard gold.

struct LocalLLMEntry: TimelineEntry {
    let date: Date
    let llm: LocalLLMSnapshot?
}

struct LocalLLMProvider: TimelineProvider {
    func placeholder(in context: Context) -> LocalLLMEntry {
        LocalLLMEntry(date: Date(), llm: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (LocalLLMEntry) -> Void) {
        completion(LocalLLMEntry(date: Date(), llm: LocalLLMStore.load() ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LocalLLMEntry>) -> Void) {
        let now = Date()
        let state = LocalLLMStore.load()
        // The app reloads timelines after every poll. With a pending request
        // redraw after 20 s so "changing…" can't get stuck; 30 s while a
        // model loads; otherwise a 5 min fallback.
        let next: TimeInterval
        if state?.activeAction != nil { next = 20 }
        else if state?.state == .loading || state?.state == .busy { next = 30 }
        else { next = 300 }
        completion(Timeline(entries: [LocalLLMEntry(date: now, llm: state)],
                            policy: .after(now.addingTimeInterval(next))))
    }

    static var sample: LocalLLMSnapshot {
        var s = LocalLLMSnapshot(updatedAt: Date())
        s.serviceRegistered = true
        s.reachable = true
        s.version = "0.6.4"
        s.uptimeSec = 65_390
        s.modelsDiscovered = 1
        s.loadedModels = ["qwen3-27b-omlx"]
        s.defaultModel = "qwen3-27b-omlx"
        s.lifetimeGenerationTps = 6.9
        s.lifetimePrefillTps = 234
        s.availableModels = ["qwen3-27b-omlx"]
        s.modelDisplayNames = ["qwen3-27b-omlx": "Qwen3 27B"]
        s.contextWindow = 42_496
        s.modelMemoryBytes = 14 * 1_073_741_824
        s.promptTokens = 395_806
        s.completionTokens = 2_040
        s.cachedTokens = 176_128
        s.lifetimeRequests = 21
        s.lifetimePromptTokens = 395_806
        s.lifetimeCachedTokens = 176_128
        s.avgPrefillTps = 210
        s.avgGenerationTps = 7.8
        s.ssdCacheBytes = 23 * 1_073_741_824
        return s
    }
}

/// Card accent: pink-magenta, unique in the family so it stands out in the gallery.
private let llmAccent = Color(red: 0.93, green: 0.38, blue: 0.62)
/// Amber while generating — the same "load" colour as the system card.
private let llmBusyAccent = Color(red: 1.00, green: 0.72, blue: 0.25)

private extension LocalLLMSnapshot {
    /// Header dot and switch colour: off grey, idle faded pink, loading/ready
    /// full pink, busy amber.
    var accent: Color {
        switch state {
        case .off: return .secondary
        case .idle: return llmAccent.opacity(0.5)
        case .loading, .ready: return llmAccent
        case .busy: return llmBusyAccent
        }
    }
}

/// Locale-aware decimal: "7.8" / "7,8".
private func decimal(_ value: Double, digits: Int = 1) -> String {
    value.formatted(.number.precision(.fractionLength(digits)))
}

private func gbNumber(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    return gb.formatted(.number.precision(.fractionLength(gb < 10 ? 1 : 0)))
}

private func gbLabel(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb < 1 {
        return (Double(bytes) / 1_048_576).formatted(.number.precision(.fractionLength(0))) + " MB"
    }
    return gbNumber(bytes) + " GB"
}

/// Total machine memory — denominator of the memory bar. Measured rather
/// than hard-coded; readable from inside the extension too.
private let machineMemoryBytes = ProcessInfo.processInfo.physicalMemory

/// Status orb. Sibling of the sleep guard's GuardOrb, but with five states:
/// off / idle / loading / ready / busy.
///
/// The view tree is IDENTICAL in all five states: glows, fills, rings and the
/// icon are always present, only their opacity changes. Adding/removing views
/// with `if …` or swapping a gradient fill for a flat colour makes WidgetKit's
/// transition flash white and draw black squares (observed on the sleep guard).
///
/// Widgets can't animate, so "loading" is a static 3/4 ring, not a spinner.
struct LLMOrb: View {
    let state: LocalLLMSnapshot.State
    let diameter: CGFloat
    var iconScale: CGFloat = 0.42
    var tileWidth: CGFloat? = nil

    private var width: CGFloat { tileWidth ?? diameter }
    private var silhouette: RoundedRectangle {
        RoundedRectangle(cornerRadius: tileWidth == nil ? diameter / 2 : 14,
                         style: tileWidth == nil ? .circular : .continuous)
    }

    private var isReady: Bool { state == .ready }
    private var isBusy: Bool { state == .busy }
    private var isLoading: Bool { state == .loading }
    private var isOff: Bool { state == .off }

    var body: some View {
        ZStack {
            // Outer glow: pink when ready, amber when busy.
            Circle()
                .fill(RadialGradient(colors: [llmAccent.opacity(0.50), llmAccent.opacity(0.0)],
                                     center: .center, startRadius: diameter * 0.2,
                                     endRadius: diameter * 0.85))
                .frame(width: diameter * 1.7, height: diameter * 1.7)
                .opacity(isReady ? 1 : 0)
            Circle()
                .fill(RadialGradient(colors: [llmBusyAccent.opacity(0.55), llmBusyAccent.opacity(0.0)],
                                     center: .center, startRadius: diameter * 0.2,
                                     endRadius: diameter * 0.85))
                .frame(width: diameter * 1.7, height: diameter * 1.7)
                .opacity(isBusy ? 1 : 0)
            // Empty body (off / idle / loading).
            silhouette
                .fill(Color.primary.opacity(0.08))
                .frame(width: width, height: diameter)
                .opacity(isReady || isBusy ? 0 : 1)
            // Filled body.
            silhouette
                .fill(LinearGradient(colors: [llmAccent, llmAccent.opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: width, height: diameter)
                .shadow(color: llmAccent.opacity(0.6), radius: diameter * 0.18)
                .opacity(isReady ? 1 : 0)
            silhouette
                .fill(LinearGradient(colors: [llmBusyAccent, llmBusyAccent.opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: width, height: diameter)
                .shadow(color: llmBusyAccent.opacity(0.6), radius: diameter * 0.18)
                .opacity(isBusy ? 1 : 0)
            // Thin ring: pink when idle, grey when off.
            silhouette
                .strokeBorder(llmAccent.opacity(0.55), lineWidth: 1.6)
                .frame(width: width, height: diameter)
                .opacity(state == .idle ? 1 : 0)
            silhouette
                .strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1.6)
                .frame(width: width, height: diameter)
                .opacity(isOff ? 1 : 0)
            // Bright rim for the filled states.
            silhouette
                .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                .frame(width: width, height: diameter)
                .opacity(isReady || isBusy ? 1 : 0)
            // Loading: 3/4 of the ring drawn (no animation in widgets, so a
            // static arc plus the "loading" text instead of a spinner).
            silhouette
                .trim(from: 0, to: 0.75)
                .stroke(llmAccent, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(tileWidth == nil ? -90 : 0))
                .frame(width: width - 2, height: diameter - 2)
                .opacity(isLoading ? 1 : 0)
            // Same symbol in every state; only colour/opacity change.
            Image(systemName: "cpu")
                .font(.system(size: diameter * iconScale, weight: .semibold))
                .foregroundStyle(Color.white)
                .opacity(isReady || isBusy ? 1 : 0)
            Image(systemName: "cpu")
                .font(.system(size: diameter * iconScale, weight: .semibold))
                .foregroundStyle(llmAccent)
                .opacity(isLoading || state == .idle ? 0.85 : 0)
            Image(systemName: "cpu")
                .font(.system(size: diameter * iconScale, weight: .semibold))
                .foregroundStyle(Color.secondary)
                .opacity(isOff ? 0.55 : 0)
        }
        .frame(width: width, height: diameter)
    }
}

struct SmallLocalLLMView: View {
    let llm: LocalLLMSnapshot

    var body: some View {
        let state = llm.state
        let pending = llm.activeAction != nil
        let running = llm.shownRunning
        let tps = (state == .ready || state == .busy) ? llm.generationTps : nil
        VStack(alignment: .leading, spacing: 4) {
            // Title + "LOADING" chip don't fit in 123 pt; the orb and the big
            // word carry the state, the chip lives on the medium card.
            HeaderRow(accent: llm.accent, title: String(localized: "Local LLM"), stale: llm.isStale)
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                LLMOrb(state: state, diameter: 44)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        // Number large, word a notch smaller: the ~67 pt left
                        // after the orb can't fit a long word at 17 pt, and
                        // SwiftUI truncates instead of scaling (measured).
                        Text(headline(state: state, tps: tps))
                            .font(.system(size: tps == nil ? 13.5 : 17,
                                          weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.55)
                        // The unit is always in the tree; without a number
                        // it's just invisible.
                        Text("tok/s")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            // An invisible unit still took space and truncated
                            // the state word (measured): without a number its
                            // width drops to zero while the tree stays the
                            // same. lineLimit is REQUIRED: at zero width the
                            // text wraps letter by letter and breaks the layout.
                            .lineLimit(1)
                            .frame(width: tps == nil ? 0 : nil)
                            .opacity(tps == nil ? 0 : 1)
                    }
                    Text(subline)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                GlassSwitch(enabled: running, pending: pending, height: 22, accent: llmAccent,
                            intent: LocalLLMActionIntent(action: running ? "stop" : "start"),
                            accessibility: running ? String(localized: "Stop the local LLM service")
                                                   : String(localized: "Start the local LLM service"))
                    .padding(.leading, 1)
                Text(trailingText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(llm.error != nil ? Color.orange : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .invalidatableContent(pending)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func headline(state: LocalLLMSnapshot.State, tps: Double?) -> String {
        if let tps, tps > 0 { return decimal(tps) }
        switch state {
        case .off: return String(localized: "off")
        case .idle: return String(localized: "idle")
        case .loading: return String(localized: "loading")
        case .ready: return String(localized: "ready")
        case .busy: return String(localized: "busy")
        }
    }

    /// Model name; while the server is off the model means little and the
    /// lifetime counter says more.
    private var subline: String {
        if llm.state == .off {
            if let requests = llm.lifetimeRequests {
                let count = String(requests)
                return String(localized: "\(count) requests total")
            }
            return String(localized: "server off")
        }
        return llm.shortModelName ?? String(localized: "no model")
    }

    private var trailingText: String {
        if let error = llm.error { return error }
        if let action = llm.activeAction {
            return action == "warm" ? String(localized: "warming…") : String(localized: "changing…")
        }
        if llm.state == .off { return String(localized: "stopped") }
        if let memory = llm.modelMemoryBytes, memory > 0 { return gbLabel(memory) }
        // "no model" while loading contradicts itself; an expected wait says
        // more.
        return llm.state == .loading ? String(localized: "a few sec") : String(localized: "no model")
    }
}

/// Model label/picker under the orb. The dot is in the accent colour for a
/// loaded model and faded for a selected one not in memory; the chevron
/// advances to the next model.
struct ModelPicker: View {
    let name: String
    let selectable: Bool
    let loaded: Bool

    var body: some View {
        Button(intent: LocalLLMActionIntent(action: "select")) {
            HStack(spacing: 3) {
                Circle()
                    .fill(llmAccent)
                    .frame(width: 5, height: 5)
                    .opacity(loaded ? 1 : 0.3)
                Text(name)
                    .font(.system(size: name.count > 18 ? 9 : 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(name.count > 18 ? 2 : 1).minimumScaleFactor(0.6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .opacity(selectable ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .frame(maxWidth: 100)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsule(tint: nil))
        .disabled(!selectable)
        .accessibilityLabel("Next model")
    }
}

struct MediumLocalLLMView: View {
    let llm: LocalLLMSnapshot

    var body: some View {
        let state = llm.state
        let pending = llm.activeAction != nil
        let running = llm.shownRunning
        let memory = llm.modelMemoryBytes ?? 0
        let memoryFill = machineMemoryBytes > 0
            ? Double(memory) / Double(machineMemoryBytes) * 100 : 0
        let cacheHit = llm.cacheHitPercent ?? 0
        let rowColor = state == .busy ? llmBusyAccent : llmAccent
        // Same skeleton as the battery card: orb + picker on the left, four
        // bars on the right, a control row spanning both columns at the
        // bottom. With the controls inside the right column, long status
        // text overflowed it (measured).
        VStack(alignment: .leading, spacing: 5) {
            HeaderRow(accent: llm.accent, title: String(localized: "Local LLM"),
                      chip: llm.badge, chipColor: llm.accent,
                      trailing: llm.updatedAt == .distantPast ? nil
                                : llm.updatedAt.formatted(date: .omitted, time: .shortened),
                      stale: llm.isStale)
            HStack(spacing: 12) {
                VStack(spacing: 4) {
                    LLMOrb(state: state, diameter: 48, iconScale: 0.30, tileWidth: 100)
                    // Model picker: a tap advances to the next alias, which
                    // becomes the warm-up target. With one model: plain label.
                    ModelPicker(name: llm.shortModelName ?? String(localized: "no model"),
                                selectable: llm.availableModels.count > 1,
                                loaded: llm.shownModel.map { llm.loadedModels.contains($0) } ?? false)
                }
                .padding(.leading, 2)
                VStack(alignment: .leading, spacing: 5) {
                    MeterRow(label: String(localized: "memory"), fill: memoryFill,
                             valueText: (memory > 0 ? gbNumber(memory) : "0") + "/" + gbNumber(machineMemoryBytes),
                             trailingText: "GB",
                             color: rowColor, trackColor: llmAccent.opacity(0.12),
                             labelWidth: 40, barHeight: 7, fontSize: 10, trailingWidth: 34,
                             valueWidth: 46)
                    MeterRow(label: String(localized: "context"),
                             fill: Double(llm.contextWindow ?? 0) / 65_536 * 100,
                             valueText: llm.contextWindow.map { "\($0 / 1024)" } ?? "—",
                             trailingText: "k tok",
                             color: llmAccent, trackColor: llmAccent.opacity(0.12),
                             labelWidth: 40, barHeight: 7, fontSize: 10, trailingWidth: 34,
                             valueWidth: 46)
                    MeterRow(label: String(localized: "cache"), fill: cacheHit,
                             valueText: llm.cacheHitPercent == nil ? "—" : "\(Int(cacheHit.rounded()))",
                             trailingText: "%",
                             color: llmAccent, trackColor: llmAccent.opacity(0.12),
                             labelWidth: 40, barHeight: 7, fontSize: 10, trailingWidth: 34,
                             valueWidth: 46)
                    MeterRow(label: state == .busy ? String(localized: "busy") : String(localized: "speed"),
                             // 0–12 tok/s scale: roughly the ceiling of a 27B
                             // 4-bit model on an M-series laptop.
                             fill: min(100, (llm.generationTps ?? 0) / 12 * 100),
                             valueText: llm.generationTps.map { decimal($0) } ?? "—",
                             trailingText: "tok/s",
                             color: rowColor, trackColor: llmAccent.opacity(0.12),
                             labelWidth: 40, barHeight: 7, fontSize: 10, trailingWidth: 34,
                             valueWidth: 46,
                             emphasized: state == .busy,
                             trailingColor: state == .busy ? llmBusyAccent : nil)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 8) {
                GlassSwitch(enabled: running, pending: pending, height: 22, accent: llmAccent,
                            intent: LocalLLMActionIntent(action: running ? "stop" : "start"),
                            accessibility: running ? String(localized: "Stop the local LLM service")
                                                   : String(localized: "Start the local LLM service"))
                    .padding(.leading, 1)
                // "Warm" only makes sense while the target isn't in memory; it
                // isn't hidden (tree stays the same), just faded and disabled.
                GlassButton(symbol: "flame.fill", title: String(localized: "warm"), accent: llmAccent,
                            intent: LocalLLMActionIntent(action: "warm"), height: 22)
                    .opacity(llm.canWarm ? 1 : 0.35)
                    .disabled(!llm.canWarm)
                Text(footLine)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(llm.error != nil ? Color.orange : Color.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .invalidatableContent(pending)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    /// Single line right of the controls: error > pending action > status.
    private var footLine: String {
        if let error = llm.error { return error }
        if let action = llm.activeAction {
            switch action {
            case "warm": return String(localized: "loading into memory…")
            case "start": return String(localized: "starting…")
            default: return String(localized: "stopping…")
            }
        }
        var parts: [String] = []
        if let requests = llm.lifetimeRequests {
            let count = String(requests)
            parts.append(String(localized: "\(count) req"))
        }
        if let cache = llm.ssdCacheBytes, cache > 0 { parts.append("SSD " + gbLabel(cache)) }
        switch llm.state {
        case .off: return String(localized: "server off")
        case .loading: return String(localized: "loading model")
        case .busy:
            let active = String(llm.activeRequests), waiting = String(llm.waitingRequests)
            return String(localized: "\(active) active · \(waiting) waiting")
        default:
            if let up = llm.uptimeText { parts.append(up) }
            return parts.joined(separator: " · ")
        }
    }
}

struct LocalLLMWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: LocalLLMEntry

    var body: some View {
        let llm = entry.llm
        Group {
            if let llm {
                if family == .systemSmall {
                    SmallLocalLLMView(llm: llm)
                } else {
                    MediumLocalLLMView(llm: llm)
                }
            } else {
                EmptyStateView(message: String(localized: "No local LLM status yet — start Pano"))
            }
        }
        .containerBackground(for: .widget) {
            let state = llm?.state ?? .off
            ZStack {
                Rectangle().fill(.fill.tertiary)
                // Both gradients always in the tree; transitions via opacity only.
                RadialGradient(colors: [llmAccent.opacity(0.26), llmAccent.opacity(0.05), llmAccent.opacity(0)],
                               center: .topLeading, startRadius: 0, endRadius: 260)
                    .opacity(state == .off ? 0.25 : 1)
                RadialGradient(colors: [llmBusyAccent.opacity(0.26), llmBusyAccent.opacity(0.05), llmBusyAccent.opacity(0)],
                               center: .topLeading, startRadius: 0, endRadius: 260)
                    .opacity(state == .busy ? 1 : 0)
            }
        }
    }
}

struct LocalLLMWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "LocalLLMWidget", provider: LocalLLMProvider()) { entry in
            LocalLLMWidgetView(entry: entry)
        }
        .configurationDisplayName("Local LLM")
        .description("oMLX server status: loaded model, generation speed, cache hits. Start, stop and warm up from the card.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
