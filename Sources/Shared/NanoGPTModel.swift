import Foundation
import SwiftUI

/// Nano-GPT prepaid balance plus the usage breakdown for this API key.
/// Unlike the quota cards there is no percentage here, only dollars. To draw
/// a bar at all we need a fixed scale: by default $10 fills it (one practical
/// top-up), configurable via `nanogptFullScaleUsd`. The bar drops as the
/// balance drops; anything above the scale is drawn in a different colour,
/// otherwise a $40 account and a $10 account would look identical.
///
/// Spend and top-model figures come from the `api/v1/usage` endpoint; they are
/// NOT estimated from the difference between two balance readings. The
/// endpoint counts per key, so these numbers cover the key this Mac uses, not
/// the whole account.
struct NanoGPTSnapshot: Codable, Hashable {
    var updatedAt: Date
    /// nil = never read (no key, or the first request failed).
    var usdBalance: Double?
    /// Usage not yet deducted from the balance; usually null.
    var pendingUsd: Double?
    var nanoBalance: Double?
    var error: String?

    /// No API key configured: the card shows a setup hint, not an error.
    var missingKey: Bool?
    /// Full-bar scale in USD, copied from the app's config (the sandboxed
    /// widget can't read it). nil = default.
    var fullScaleUsd: Double?

    /// Today's spend. The endpoint's day buckets are UTC, so "today" rolls
    /// over at UTC midnight, not local midnight.
    var todaySpendUsd: Double?
    var todayRequests: Int?
    /// The endpoint's default window: the last 30 UTC days.
    var windowSpendUsd: Double?
    var windowRequests: Int?
    var windowDays: Int?
    /// Model with the most REQUESTS in the window: that is "most used".
    var topModel: String?
    var topModelRequests: Int?
    var topModelSpendUsd: Double?
    /// If the usage endpoint fails the balance is still shown; this field
    /// carries only that error and does not blank the card.
    var usageError: String?

    static let defaultFullScaleUsd: Double = 10

    static let empty = NanoGPTSnapshot(updatedAt: .distantPast, usdBalance: nil,
                                       pendingUsd: nil, nanoBalance: nil, error: nil)

    /// Dollars that fill the whole bar.
    var scaleUsd: Double {
        guard let fullScaleUsd, fullScaleUsd > 0 else { return Self.defaultFullScaleUsd }
        return fullScaleUsd
    }

    /// Fill ratio of bar and dial: balance / scale, capped at 100.
    var fillPercent: Double {
        guard let usdBalance, usdBalance > 0 else { return 0 }
        return min(100, usdBalance / scaleUsd * 100)
    }

    /// At or above the scale: bar full, colour changes.
    var isOverflow: Bool { (usdBalance ?? 0) >= scaleUsd }

    /// The balance doesn't move by itself; the quota cards' 30 min threshold
    /// is enough.
    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 30 * 60 }
}

/// Card accent: lime. Unique in the family (quota cards orange/green/blue,
/// system purple, storage cyan, local LLM pink, sleep guard gold).
let nanoAccent = Color(red: 0.55, green: 0.82, blue: 0.28)
/// Above the scale: sky blue. The header dot stays lime (card identity), only
/// bar and dial switch.
let nanoOverflowAccent = Color(red: 0.35, green: 0.78, blue: 0.98)

/// Bar colour. Same thresholds as the quota cards: red below 10 % of the
/// scale, orange below 25 %.
func balanceColor(_ snapshot: NanoGPTSnapshot) -> Color {
    guard snapshot.usdBalance != nil else { return .secondary }
    if snapshot.isOverflow { return nanoOverflowAccent }
    switch snapshot.fillPercent {
    case ..<10: return .red
    case ..<25: return .orange
    default: return nanoAccent
    }
}

/// Locale-aware dollars: "$1.24" / "$1,24". Cents are dropped from $100 up.
func usdLabel(_ value: Double) -> String {
    let digits = abs(value) >= 100 ? 0 : 2
    return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
}

extension NanoGPTSnapshot {
    /// Compact scale for dials and chips: "$10", "$12.50".
    var scaleLabel: String {
        let whole = scaleUsd.rounded() == scaleUsd
        return scaleUsd.formatted(.currency(code: "USD").precision(.fractionLength(whole ? 0 : 2)))
    }

    /// Chip shown when the balance is above the scale: "$10+".
    var overflowChip: String { scaleLabel + "+" }

    var todayLabel: String {
        guard let requests = todayRequests else { return String(localized: "Today") }
        let count = String(requests)
        return String(localized: "Today · \(count) req")
    }
    var todayValue: String { todaySpendUsd.map(usdLabel) ?? "—" }

    var windowLabel: String {
        let days = String(windowDays ?? 30)
        guard let requests = windowRequests else { return String(localized: "\(days) days") }
        let count = String(requests)
        return String(localized: "\(days) days · \(count) req")
    }
    var windowValue: String { windowSpendUsd.map(usdLabel) ?? "—" }

    /// Small card footer: today's spend, or nil (caller falls back to scale text).
    var todayLine: String? {
        guard let spend = todaySpendUsd else { return nil }
        let amount = usdLabel(spend)
        guard let requests = todayRequests else { return String(localized: "today \(amount)") }
        let count = String(requests)
        return String(localized: "today \(amount) · \(count) req")
    }

    /// Medium card footer: the model with the most requests in the window.
    var topModelLine: String? {
        topModel.map { model in String(localized: "top · \(model)") }
    }

    /// With neither spend nor model, the footer explains the scale.
    var scaleText: String {
        let scale = scaleLabel
        if isOverflow { return String(localized: "above the \(scale) scale") }
        let percent = (fillPercent / 100).formatted(.percent.precision(.fractionLength(0)))
        return String(localized: "\(percent) of \(scale) scale")
    }

    /// Text for the empty state (no balance read yet).
    var emptyMessage: String {
        if missingKey == true { return String(localized: "Add a Nano-GPT API key (see README)") }
        return error ?? String(localized: "No balance yet — start Pano")
    }
}

enum NanoGPTStore {
    static let fileURL = AppPaths.file("nanogpt.json")

    static let widgetContainerFileURL = AppPaths.widgetContainerFile("nanogpt.json")

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func load() -> NanoGPTSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(NanoGPTSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: NanoGPTSnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            if mirrorToWidgetContainer {
                let widgetDirectory = widgetContainerFileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: widgetDirectory, withIntermediateDirectories: true)
                try? data.write(to: widgetContainerFileURL, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }
}
