import AppIntents
import SwiftUI
import WidgetKit

// Shared glass controls for the card family (macOS Tahoe Liquid Glass look).
// Rule: the view tree stays IDENTICAL across state changes; only opacity and
// alignment animate. `if enabled { … }` or swapping a gradient fill for a flat
// colour makes WidgetKit's transition flash and draw black squares (observed
// on the sleep guard).

/// Glass capsule: draws the Liquid Glass look by hand — translucent material,
/// bright top rim, soft shadow. `glassEffect` is deliberately NOT used: it
/// swallows the button entirely in ImageRenderer (measured) and carries the
/// same risk in WidgetKit's archived rendering; a material draws in both.
struct GlassCapsule: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .background(Capsule().fill((tint ?? .clear).opacity(0.35)))
            .overlay(
                Capsule().strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1.5)
    }
}

/// Glass track switch. A tap runs `intent`; `enabled` is the state to draw
/// (the target state while a request is pending), `pending` shows a mini
/// spinner in the knob.
struct GlassSwitch<I: AppIntent>: View {
    let enabled: Bool
    var pending = false
    var height: CGFloat = 26
    /// On-state colour; track and glass tint derive from it.
    let accent: Color
    let intent: I
    var accessibility: String = ""
    /// SF Symbol inside the knob, so the switch explains itself where no
    /// label fits (e.g. the battery card's Low Power switch).
    var knobSymbol: String? = nil

    var body: some View {
        Button(intent: intent) {
            ZStack(alignment: enabled ? .trailing : .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(accent.opacity(0.9)).opacity(enabled ? 1 : 0)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(height * 0.11)
                    .overlay {
                        // Symbol always in the tree (via opacity); the spinner sits on top.
                        Image(systemName: knobSymbol ?? "circle")
                            .font(.system(size: height * 0.42, weight: .bold))
                            .foregroundStyle(enabled ? accent : Color.black.opacity(0.4))
                            .opacity(knobSymbol == nil || pending ? 0 : 1)
                        if pending {
                            ProgressView().controlSize(.mini).scaleEffect(0.6)
                        }
                    }
            }
            .frame(width: height * 1.75, height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsule(tint: accent.opacity(enabled ? 1 : 0)))
        .accessibilityLabel(accessibility)
    }
}

/// Glass capsule button (a one-shot action, not a toggle): icon + short label.
/// `title` is shown verbatim; pass an already localized string.
struct GlassButton<I: AppIntent>: View {
    let symbol: String
    let title: String
    let accent: Color
    let intent: I
    var height: CGFloat = 22

    var body: some View {
        Button(intent: intent) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: height * 0.42, weight: .semibold))
                Text(title).font(.system(size: height * 0.45, weight: .semibold))
            }
            .foregroundStyle(accent)
            .padding(.horizontal, height * 0.45)
            .frame(height: height)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsule(tint: accent.opacity(0.35)))
    }
}
