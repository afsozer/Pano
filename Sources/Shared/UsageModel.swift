import Foundation
import SwiftUI

/// One limit window (5 hours, 7 days, monthly, ...). The percentage is always
/// the USED share; views derive "remaining" as 100 - used.
struct UsageBucket: Codable, Hashable, Identifiable {
    var id: String
    /// Already localized by the app when the snapshot was written.
    var label: String
    var usedPercent: Double
    var resetsAt: Date?
    var note: String?
    /// Label for tight spots (inside the gauge ring, the small card's rows):
    /// "Last 5 hours" → "5 hours". Missing in older snapshots.
    var shortLabel: String? = nil
}

extension UsageBucket {
    /// The small card's label column is narrow: "7 days · Opus" → "Opus",
    /// "Last 7 days" → "7 days". Leaves room for the bar.
    var compactLabel: String {
        if let tail = label.components(separatedBy: " · ").last, tail != label { return tail }
        return shortLabel ?? label
    }
}

struct ProviderUsage: Codable, Hashable {
    var key: String
    var name: String
    var plan: String?
    var buckets: [UsageBucket]
    var error: String?
    var fetchedAt: Date
    /// True when the provider isn't set up on this Mac (no Keychain item /
    /// no auth.json). The card then shows a setup hint instead of an error.
    var signedOut: Bool? = nil

    var primary: UsageBucket? { buckets.max(by: { $0.usedPercent < $1.usedPercent }) }

    /// The window shown in the ring: the 5-hour one for every provider.
    /// Matched by id (ids differ per provider), else the first bucket.
    var hero: UsageBucket? {
        buckets.first { ["claude-5h", "codex-primary"].contains($0.id) } ?? buckets.first
    }
    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > 30 * 60 }
    var isSignedOut: Bool { signedOut == true && buckets.isEmpty }
}

struct UsageSnapshot: Codable {
    var updatedAt: Date
    var providers: [String: ProviderUsage]

    static let empty = UsageSnapshot(updatedAt: .distantPast, providers: [:])
}

enum ProviderKey: String, CaseIterable {
    case claude, codex

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Small card title: the full name doesn't fit in 123 pt ("Claude C…").
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }

    var short: String {
        switch self {
        case .claude: return "CC"
        case .codex: return "CX"
        }
    }

    /// The CLI command that signs the provider in; shown in the setup hint.
    var cliCommand: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        }
    }

    var accent: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.44, blue: 0.24)   // Anthropic orange
        case .codex: return Color(red: 0.30, green: 0.72, blue: 0.58)    // OpenAI green
        }
    }

    /// Friendly hint for a provider that isn't set up on this Mac. Markdown:
    /// the command renders monospaced where the view supports it.
    var signedOutMessage: String {
        String(localized: "Not signed in — run `\(cliCommand)` once")
    }
}

/// Snapshot file. The menu bar app writes it, the widget reads it.
enum SnapshotStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Pano", isDirectory: true)
    static let fileURL = directory.appendingPathComponent("usage.json")

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// The widget extension MUST be sandboxed (otherwise it never registers
    /// with pluginkit — measured), and an App Group needs a provisioning
    /// profile that a free account can't get. So the app also writes the
    /// snapshot into the extension's own container: inside the extension `~`
    /// already resolves there, so the read path stays the same.
    static let widgetContainerFileURL = AppPaths.widgetContainerFile("usage.json")

    static func load() -> UsageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(UsageSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: UsageSnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL, options: .atomic)
            if mirrorToWidgetContainer {
                let dir = widgetContainerFileURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try? data.write(to: widgetContainerFileURL, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Locale-aware formatting

/// "24%" in English, "%24" in Turkish. `value` is 0-100.
func percentText(_ value: Double) -> String {
    (value / 100).formatted(.percent.precision(.fractionLength(0)))
}

/// Whether the current locale writes the percent sign before the number
/// (Turkish "%24"). The gauge draws number and sign separately.
var percentSignLeads: Bool { percentText(50).hasPrefix("%") }

/// Short countdown such as "2h 14m" / "3d 4h"; nil once the date has passed.
func shortDuration(until date: Date, from now: Date = Date()) -> String? {
    let secs = Int(date.timeIntervalSince(now))
    guard secs > 0 else { return nil }
    let d = secs / 86_400, h = (secs % 86_400) / 3600, m = (secs % 3600) / 60
    let (ds, hs, ms) = (d.formatted(), h.formatted(), m.formatted())
    if d > 0 { return String(localized: "\(ds)d \(hs)h", comment: "Countdown: days and hours") }
    if h > 0 { return String(localized: "\(hs)h \(ms)m", comment: "Countdown: hours and minutes") }
    return String(localized: "\(ms)m", comment: "Countdown: minutes")
}

extension Date {
    /// Countdown for the menu panel; "now" once the date has passed.
    var shortCountdown: String {
        shortDuration(until: self) ?? String(localized: "now", comment: "Countdown reached zero")
    }
}

// MARK: - Window labels (stored localized in the snapshot)

func windowLabel(hours: Int) -> String {
    String(localized: "Last \(hours.formatted()) hours", comment: "Quota window, e.g. Last 5 hours")
}

func windowLabel(days: Int) -> String {
    String(localized: "Last \(days.formatted()) days", comment: "Quota window, e.g. Last 7 days")
}

func windowShortLabel(hours: Int) -> String {
    String(localized: "\(hours.formatted()) hours", comment: "Short quota window, e.g. 5 hours")
}

func windowShortLabel(days: Int) -> String {
    String(localized: "\(days.formatted()) days", comment: "Short quota window, e.g. 7 days")
}

/// Renders inline Markdown (e.g. a `command`) in an already localized String.
func inlineMarkdown(_ string: String) -> AttributedString {
    (try? AttributedString(markdown: string)) ?? AttributedString(string)
}
