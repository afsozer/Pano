import AppIntents
import WidgetKit
import SwiftUI

// MARK: - Sleep guard widget
//
// An on/off card for two separate guards. The card should convey its state
// at a glance: when on, a warm glowing "awake" orb; when off, a cold dim
// moon. The toggles are the family's shared GlassSwitch (GlassControls.swift).
//
// The switches are NOT the same thing:
//   • "lid closed" = `pmset -a disablesleep 1` — never sleeps, in every
//     profile, on battery, even with the lid closed. Blunt and risky; it
//     overrides everything.
//   • "on AC"      = `pmset -c sleep 0` — idle system sleep off in the AC
//     profile only; the display still sleeps, the battery profile is untouched.
// While the first is on the second has no practical effect: the card then
// draws the second row dimmed, but it stays tappable (the value persists).

struct SleepGuardEntry: TimelineEntry {
    let date: Date
    let guardState: SleepGuardSnapshot?
}

struct SleepGuardProvider: TimelineProvider {
    func placeholder(in context: Context) -> SleepGuardEntry {
        SleepGuardEntry(date: Date(), guardState: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SleepGuardEntry) -> Void) {
        completion(SleepGuardEntry(date: Date(), guardState: SleepGuardStore.load() ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SleepGuardEntry>) -> Void) {
        let now = Date()
        let state = SleepGuardStore.load()
        // The app reloads timelines on every change and once a minute. With a
        // pending request redraw after 20 s so "changing…" can't get stuck;
        // otherwise a 5 min fallback.
        let next: TimeInterval = (state?.activePending ?? state?.activeACIdlePending) != nil ? 20 : 300
        completion(Timeline(entries: [SleepGuardEntry(date: now, guardState: state)],
                            policy: .after(now.addingTimeInterval(next))))
    }

    static let sample = SleepGuardSnapshot(updatedAt: Date(), enabled: true, acIdleAwake: true,
                                           powerSource: "AC", batteryPercent: 100)
}

/// Warm gold when on (awake, light), night blue when off (sleep).
private let awakeAccent = Color(red: 1.00, green: 0.74, blue: 0.22)
private let asleepAccent = Color(red: 0.52, green: 0.58, blue: 0.80)

private extension SleepGuardSnapshot {
    /// State to draw: the target state while a request is pending (instant
    /// feedback on tap), otherwise the real state.
    var shownEnabled: Bool { activePending ?? enabled }
    var shownACIdleAwake: Bool { activeACIdlePending ?? acIdleAwake }
    /// The AC switch only matters on AC: on battery the Mac follows the
    /// battery profile, so the orb mustn't claim "awake".
    var acEffective: Bool { shownACIdleAwake && !onBattery }
    /// The orb lights up for either guard: the hard one or AC-only.
    var awake: Bool { shownEnabled || acEffective }
    /// AC profile only: the orb is lit but dimmer — closing the lid still
    /// puts the Mac to sleep.
    var partialAwake: Bool { !shownEnabled && acEffective }
    var anyPending: Bool { activePending != nil || activeACIdlePending != nil }
    var accent: Color { awake ? awakeAccent : asleepAccent }
    var chip: String {
        if shownEnabled { return String(localized: "ON") }
        return acEffective ? String(localized: "AC") : String(localized: "OFF")
    }
    var headline: String {
        if shownEnabled { return String(localized: "Mac stays awake") }
        return acEffective ? String(localized: "Awake on AC") : String(localized: "Mac may sleep")
    }
    var statusLine: String {
        if let error { return error }
        if anyPending { return String(localized: "changing…") }
        if shownEnabled { return String(localized: "Stays awake with the lid closed") }
        if acEffective { return String(localized: "No idle sleep on AC, display sleeps") }
        if shownACIdleAwake { return String(localized: "Sleeps on battery, not on AC") }
        return String(localized: "Sleeps when the lid closes")
    }
    /// The two lines next to the orb on the small card.
    var shortTitle: String { awake ? String(localized: "Awake") : String(localized: "Sleeps") }
    var shortDetail: String {
        if let error { return error }
        if anyPending { return String(localized: "changing…") }
        if shownEnabled { return String(localized: "even lid closed") }
        if acEffective { return String(localized: "on AC, when idle") }
        return shownACIdleAwake ? String(localized: "sleeps on battery") : String(localized: "when lid closes")
    }
    private var percentText: String? {
        batteryPercent.map { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0))) }
    }
    var powerLine: String? {
        guard let powerSource else { return nil }
        let source = powerSource == "AC" ? String(localized: "on AC") : String(localized: "on battery")
        return percentText.map { source + " · " + $0 } ?? source
    }
    /// Short form for the small card: "battery 51%" / "AC".
    var powerShort: String? {
        guard let powerSource else { return nil }
        if powerSource == "AC" { return String(localized: "AC power") }
        guard let percent = percentText else { return String(localized: "battery") }
        return String(localized: "battery \(percent)")
    }
    /// Staying awake on battery drains it; the card says so in orange.
    var warnsBattery: Bool { shownEnabled && onBattery }
}

/// Glowing orb: a sun with a gold halo when on, a moon and a faint ring when
/// off. Scales with the card.
///
/// The view tree is IDENTICAL in both states: glow, both fills and both icons
/// are always present, only their opacity changes. `if enabled { … }` or a
/// gradient↔colour fill swap produced white-yellow flashes and black glitches
/// in WidgetKit's transition frames (observed); opacity interpolates cleanly.
///
/// `partial` = only the AC guard is on: same tree, dimmer glow — lit, but not
/// "fully awake".
struct GuardOrb: View {
    let enabled: Bool
    var partial: Bool = false
    let pending: Bool
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [awakeAccent.opacity(0.55), awakeAccent.opacity(0.0)],
                                     center: .center, startRadius: diameter * 0.2,
                                     endRadius: diameter * 0.85))
                .frame(width: diameter * 1.7, height: diameter * 1.7)
                .opacity(enabled ? (partial ? 0.35 : 1) : 0)
            Circle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: diameter, height: diameter)
                .opacity(enabled ? 0 : 1)
            Circle()
                .fill(LinearGradient(colors: [awakeAccent, awakeAccent.opacity(0.7)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: diameter, height: diameter)
                .shadow(color: awakeAccent.opacity(0.6), radius: diameter * 0.18)
                .opacity(enabled ? (partial ? 0.82 : 1) : 0)
            Circle()
                .strokeBorder(.white.opacity(enabled ? 0.55 : 0.18), lineWidth: 1)
                .frame(width: diameter, height: diameter)
            Image(systemName: "sun.max.fill")
                .font(.system(size: diameter * 0.46, weight: .semibold))
                .foregroundStyle(Color.white)
                .opacity(enabled ? 1 : 0)
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: diameter * 0.46, weight: .semibold))
                .foregroundStyle(asleepAccent)
                .symbolRenderingMode(.hierarchical)
                .opacity(enabled ? 0 : 1)
        }
        .frame(width: diameter, height: diameter)
        .opacity(pending ? 0.8 : 1)
    }
}

/// Labelled glass switch, horizontal (small card): switch + short name. The
/// label's colour also shows the state, so no separate "on/off" text is
/// needed — that's what made two switches fit.
private struct GuardToggleRow<I: AppIntent>: View {
    let label: String
    let on: Bool
    let pending: Bool
    let intent: I
    let accessibility: String
    var height: CGFloat = 21
    var labelSize: CGFloat = 10.5
    /// While the hard guard is on this switch has no effect: draw it dimmed
    /// but keep it tappable (opacity doesn't block taps).
    var shadowed = false

    var body: some View {
        HStack(spacing: 6) {
            GlassSwitch(enabled: on, pending: pending, height: height, accent: awakeAccent,
                        intent: intent, accessibility: accessibility)
            Text(label)
                .font(.system(size: labelSize, weight: .medium))
                .foregroundStyle(on ? awakeAccent : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .invalidatableContent(pending)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(shadowed ? 0.55 : 1)
    }
}

/// Same switch with the label on top (medium card): with two switches side
/// by side, labels above instead of beside halve the row width.
private struct GuardToggleColumn<I: AppIntent>: View {
    let label: String
    let on: Bool
    let pending: Bool
    let intent: I
    let accessibility: String
    var shadowed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(on ? awakeAccent : Color.secondary)
                .lineLimit(1).minimumScaleFactor(0.6)
                .invalidatableContent(pending)
            GlassSwitch(enabled: on, pending: pending, height: 24, accent: awakeAccent,
                        intent: intent, accessibility: accessibility)
        }
        .opacity(shadowed ? 0.55 : 1)
    }
}

struct SmallSleepGuardView: View {
    let state: SleepGuardSnapshot

    var body: some View {
        let on = state.shownEnabled
        let ac = state.shownACIdleAwake
        let pending = state.activePending != nil
        let acPending = state.activeACIdlePending != nil
        // The second switch only fit the 123 pt card once the orb shrank
        // (52 → 42) and the bottom block split into two rows; the state now
        // lives in the switch label colours and the text next to the orb.
        VStack(alignment: .leading, spacing: 0) {
            // Title + chip don't fit in 123 pt; the orb carries the state.
            HeaderRow(accent: state.accent, title: String(localized: "Sleep guard"), stale: state.isStale)
            HStack(spacing: 8) {
                GuardOrb(enabled: state.awake, partial: state.partialAwake,
                         pending: pending || acPending, diameter: 42)
                VStack(alignment: .leading, spacing: 1) {
                    Text(state.shortTitle)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(state.shortDetail)
                        .font(.system(size: 9))
                        .foregroundStyle(state.error == nil ? Color.secondary : Color.orange)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .invalidatableContent(pending || acPending)
                    Text(state.powerShort ?? " ")
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(state.warnsBattery ? Color.orange : Color.secondary)
                        .lineLimit(1).minimumScaleFactor(0.6)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 2)
            .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 4) {
                GuardToggleRow(label: String(localized: "lid closed"), on: on, pending: pending,
                               intent: SetSleepGuardIntent(enable: !on),
                               accessibility: on ? String(localized: "Turn off sleep guard")
                                                 : String(localized: "Turn on sleep guard"))
                GuardToggleRow(label: String(localized: "on AC"), on: ac, pending: acPending,
                               intent: SetSleepGuardACIdleIntent(enable: !ac),
                               accessibility: ac ? String(localized: "Allow idle sleep on AC")
                                                 : String(localized: "Prevent idle sleep on AC"),
                               shadowed: on)
            }
            .padding(.leading, 1)
        }
    }
}

struct MediumSleepGuardView: View {
    let state: SleepGuardSnapshot

    var body: some View {
        let on = state.shownEnabled
        let ac = state.shownACIdleAwake
        let pending = state.activePending != nil
        let acPending = state.activeACIdlePending != nil
        VStack(alignment: .leading, spacing: 6) {
            HeaderRow(accent: state.accent, title: String(localized: "Sleep guard"),
                      chip: state.chip, chipColor: state.accent,
                      trailing: state.updatedAt == .distantPast ? nil
                                : state.updatedAt.formatted(date: .omitted, time: .shortened),
                      stale: state.isStale)
            HStack(spacing: 14) {
                GuardOrb(enabled: state.awake, partial: state.partialAwake,
                         pending: pending || acPending, diameter: 66)
                    .padding(.leading, 6)
                // The power line moved up here: the bottom row is full with
                // two switches plus the raw pmset values.
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.headline)
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(state.statusLine)
                        .font(.system(size: 10.5))
                        .foregroundStyle(state.error == nil ? Color.secondary : Color.orange)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .invalidatableContent(pending || acPending)
                    if let power = state.powerLine {
                        Text(state.warnsBattery ? String(localized: "\(power) — drains battery") : power)
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(state.warnsBattery ? Color.orange : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.6)
                    }
                    Spacer(minLength: 2)
                    HStack(spacing: 12) {
                        GuardToggleColumn(label: String(localized: "lid closed"), on: on, pending: pending,
                                          intent: SetSleepGuardIntent(enable: !on),
                                          accessibility: on ? String(localized: "Turn off sleep guard")
                                                            : String(localized: "Turn on sleep guard"))
                        GuardToggleColumn(label: String(localized: "on AC"), on: ac, pending: acPending,
                                          intent: SetSleepGuardACIdleIntent(enable: !ac),
                                          accessibility: ac ? String(localized: "Allow idle sleep on AC")
                                                            : String(localized: "Prevent idle sleep on AC"),
                                          shadowed: on)
                        // Two separate Texts: a single Text with "\n" plus
                        // minimumScaleFactor clipped the second line entirely
                        // (measured: only "disablesleep 1…" rendered). No
                        // Spacer; the block takes the remaining width and
                        // scales down within it. Raw pmset values: verbatim.
                        VStack(alignment: .leading, spacing: 0) {
                            Text(verbatim: "disablesleep \(on ? 1 : 0)")
                            Text(verbatim: ac ? "-c sleep 0" : "-c sleep ≠0")
                        }
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .padding(.top, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct SleepGuardWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SleepGuardEntry

    var body: some View {
        let state = entry.guardState
        Group {
            if let state {
                if family == .systemSmall {
                    SmallSleepGuardView(state: state)
                } else {
                    MediumSleepGuardView(state: state)
                }
            } else {
                EmptyStateView(message: String(localized: "No sleep status yet — start Pano"))
            }
        }
        .containerBackground(for: .widget) {
            let on = state?.awake ?? false
            ZStack {
                Rectangle().fill(.fill.tertiary)
                // Both gradients always in the tree; transitions via opacity
                // only (the orb's animation artefact showed up here too).
                RadialGradient(colors: [awakeAccent.opacity(0.30), awakeAccent.opacity(0.06), awakeAccent.opacity(0)],
                               center: .topLeading, startRadius: 0, endRadius: 260)
                    .opacity(on ? 1 : 0)
                LinearGradient(colors: [asleepAccent.opacity(0.14), asleepAccent.opacity(0)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(on ? 0 : 1)
            }
        }
    }
}

struct SleepGuardWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SleepGuardWidget", provider: SleepGuardProvider()) { entry in
            SleepGuardWidgetView(entry: entry)
        }
        .configurationDisplayName("Sleep guard")
        .description("Two switches to keep the Mac awake: even with the lid closed (pmset disablesleep), or only idle on AC power (pmset -c sleep).")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
