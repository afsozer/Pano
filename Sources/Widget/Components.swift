import WidgetKit
import SwiftUI

// MARK: - Shared components
//
// One visual language: quota cards show what is LEFT everywhere. The ring and
// the bars fill to the remaining share and the numbers are remaining percent.
// Showing the used share (a filling bar next to a big "left" number) confused.

func remainingColor(_ remaining: Double, accent: Color) -> Color {
    switch remaining {
    case ..<10: return .red
    case ..<25: return .orange
    default: return accent
    }
}

/// Time until a window resets ("2h 14m"); "reset" once it has passed.
func countdown(to date: Date, from now: Date) -> String {
    shortDuration(until: date, from: now)
        ?? String(localized: "reset", comment: "A quota window has already reset")
}

private struct GaugeOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) * 0.23
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius),
                    radius: radius, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                    radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius),
                    radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.minX + radius, y: rect.minY + radius),
                    radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// Rounded square that traces the fill share. The stroke is centered on the
/// path, so half of it would spill outside the frame; the padding pulls it in.
struct GaugeTrack: View {
    /// Filled share (0-100). REMAINING on quota cards, USED on the system card;
    /// either way the ring fills as far as the number in the middle says.
    let fill: Double
    let color: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            GaugeOutline().stroke(color.opacity(0.14), lineWidth: lineWidth)
            GaugeOutline()
                .trim(from: 0, to: max(0.004, min(1, fill / 100)))
                .stroke(
                    AngularGradient(colors: [color, color.opacity(0.65), color],
                                    center: .center, angle: .degrees(-90)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .shadow(color: color.opacity(0.35), radius: 2, y: 0.5)
        }
        .padding(lineWidth / 2 + 1)
    }
}

/// The family's shared dial: rounded square, number in the middle, optional
/// label below. Remaining percent on quota cards, used percent on the system card.
/// `label` is drawn verbatim: pass an already localized String.
struct GaugeDial: View {
    let value: Double
    var label: String? = nil
    let color: Color
    let diameter: CGFloat
    let numberSize: CGFloat

    var body: some View {
        ZStack {
            GaugeTrack(fill: value, color: color, lineWidth: diameter * 0.11)
            VStack(spacing: -1) {
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    // Sign position follows the locale ("24%" vs Turkish "%24").
                    if percentSignLeads { percentSign }
                    Text(verbatim: Int(value.rounded()).formatted())
                        .font(.system(size: numberSize, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if !percentSignLeads { percentSign }
                }
                // "100%" ran into the ring's stroke: fit it to the inner diameter.
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(maxWidth: diameter * 0.66)
                if let label {
                    Text(verbatim: label.uppercased())
                        .font(.system(size: max(7, diameter * 0.105), weight: .medium))
                        .tracking(0.2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).minimumScaleFactor(0.5)
                        .frame(maxWidth: diameter * 0.56)
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var percentSign: some View {
        Text(verbatim: "%")
            .font(.system(size: numberSize * 0.42, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
            .baselineOffset(numberSize * 0.04)
    }
}

/// Quota card dial: remaining percent plus the window's name.
struct HeroGauge: View {
    let bucket: UsageBucket
    let accent: Color
    let diameter: CGFloat
    let numberSize: CGFloat
    var showsLabel: Bool = true

    var body: some View {
        let remaining = max(0, 100 - bucket.usedPercent)
        GaugeDial(value: remaining,
                  // The ring's inside is narrow: "Last 5 hours" ran into the stroke.
                  label: showsLabel ? (bucket.shortLabel ?? bucket.label) : nil,
                  color: remainingColor(remaining, accent: accent),
                  diameter: diameter, numberSize: numberSize)
    }
}

/// Inline mini dial: fill level at a glance. Same language as the big dial,
/// just icon-sized.
struct MiniDial: View {
    let value: Double
    let color: Color
    var diameter: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: diameter * 0.22)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, value / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: diameter * 0.22, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(diameter * 0.11 + 1)
        .frame(width: diameter, height: diameter)
    }
}

/// The family's shared meter row: label, filling bar, value, optional trailing
/// text. Kept in one place so quota and system cards share the same geometry.
/// Texts are drawn verbatim: pass already localized Strings.
struct MeterRow: View {
    let label: String
    let fill: Double
    let valueText: String
    var trailingText: String? = nil
    var color: Color
    var trackColor: Color
    var labelWidth: CGFloat = 58
    var barHeight: CGFloat = 8
    var fontSize: CGFloat = 10
    var trailingWidth: CGFloat = 32
    /// Width of the value column; defaults to 38 with trailing text, else 34.
    /// Compound values like "14/32" don't fit the default (local LLM card).
    var valueWidth: CGFloat? = nil
    var emphasized: Bool = false
    var trailingColor: Color? = nil
    var trailingIcon: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(verbatim: label)
                .font(.system(size: fontSize, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: labelWidth, alignment: .leading)
                .lineLimit(1).minimumScaleFactor(0.6)
            Capsule().fill(trackColor)
                .frame(height: barHeight)
                .overlay(alignment: .leading) {
                    GeometryReader { geo in
                        Capsule()
                            .fill(LinearGradient(colors: [color.opacity(0.72), color],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(barHeight, geo.size.width * min(1, fill / 100)))
                    }
                }
            Text(verbatim: valueText)
                .font(.system(size: fontSize + 3, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1).minimumScaleFactor(valueWidth == nil ? 0.7 : 1)
                // With `valueWidth` the text is pinned to its ideal width: even
                // inside a fixed 120 pt frame SwiftUI went by the first layout
                // proposal and clipped "14/32 GB" to "14/32…" (measured;
                // minimumScaleFactor didn't kick in either).
                .fixedSize(horizontal: valueWidth != nil, vertical: false)
                .frame(width: valueWidth ?? (trailingText == nil ? 34 : 38), alignment: .trailing)
                // The bar's Capsule is greedy: it squeezed the fixed-width value
                // column and clipped "14/32 GB" (measured). Priority only
                // changes for rows that pass `valueWidth`.
                .layoutPriority(valueWidth != nil ? 1 : 0)
            if let trailingText {
                HStack(spacing: 2) {
                    if let trailingIcon {
                        Image(systemName: trailingIcon).font(.system(size: fontSize - 1.5))
                    }
                    Text(verbatim: trailingText)
                        .font(.system(size: fontSize - 0.5))
                }
                .foregroundStyle(trailingColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
                .frame(width: trailingWidth, alignment: .trailing)
                .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }
}

struct BucketRow: View {
    let bucket: UsageBucket
    let accent: Color
    let now: Date
    var labelWidth: CGFloat = 58
    var barHeight: CGFloat = 8
    var fontSize: CGFloat = 10
    var showsReset: Bool = true
    var emphasized: Bool = false
    var compactLabel: Bool = false

    private var remaining: Double { max(0, 100 - bucket.usedPercent) }

    var body: some View {
        MeterRow(label: compactLabel ? bucket.compactLabel : bucket.label,
                 fill: remaining,
                 valueText: percentText(remaining),
                 trailingText: showsReset
                    ? (bucket.resetsAt.map { countdown(to: $0, from: now) } ?? (bucket.note ?? ""))
                    : nil,
                 color: remainingColor(remaining, accent: accent),
                 trackColor: accent.opacity(0.12),
                 labelWidth: labelWidth,
                 barHeight: barHeight,
                 fontSize: fontSize,
                 emphasized: emphasized)
    }
}

/// The family's shared header: color dot, title, chip, and on the right a time
/// or a stale warning. Texts are drawn verbatim: pass already localized Strings.
struct HeaderRow: View {
    let accent: Color
    let title: String
    var chip: String? = nil
    var chipColor: Color? = nil
    var trailing: String? = nil
    /// When set, the trailing text uses this color instead of tertiary (for warnings).
    var trailingColor: Color? = nil
    var stale: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(accent)
                .frame(width: 7, height: 7)
                .shadow(color: accent.opacity(0.6), radius: 2)
            Text(verbatim: title)
                .font(.system(size: 12.5, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
            if let chip {
                Text(verbatim: chip)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(chipColor ?? accent)
                    .padding(.horizontal, 4.5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill((chipColor ?? accent).opacity(0.16)))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if stale {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8)).foregroundStyle(.orange)
            } else if let trailing {
                Text(verbatim: trailing)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(trailingColor.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.tertiary))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Button(intent: RefreshAllWidgetsIntent()) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8.5, weight: .semibold))
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(Text("Refresh all widgets"))
        }
    }
}

extension HeaderRow {
    init(key: ProviderKey, usage: ProviderUsage?, trailing: String? = nil, compact: Bool = false) {
        self.init(accent: key.accent, title: compact ? key.shortName : key.displayName,
                  chip: usage?.plan, trailing: trailing, stale: usage?.isStale == true)
    }
}

/// Placeholder for a card without data. `message` is an already localized
/// String; inline Markdown (e.g. a `command`) is rendered.
struct EmptyStateView: View {
    let message: String
    var systemImage: String = "gauge.with.dots.needle.0percent"

    var body: some View {
        VStack(spacing: 4) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 18)).foregroundStyle(.tertiary)
            Text(inlineMarkdown(message))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
