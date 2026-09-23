import Foundation

/// `pmset disablesleep` state: should the Mac stay awake even with the lid
/// closed? The menu bar app writes the snapshot, the widget only reads it.
/// Change requests arrive from the widget as intents; the app applies them
/// and updates the file.
struct SleepGuardSnapshot: Codable, Hashable {
    var updatedAt: Date
    /// `pmset -g` → `SleepDisabled 1`. A missing line counts as 0.
    var enabled: Bool
    /// The widget's toggle was tapped but the app hasn't applied it yet.
    /// Short-lived: if `pendingSince` is older than 20 s the request was lost.
    var pendingEnabled: Bool?
    var pendingSince: Date?
    /// Second, gentler guard: `pmset -c sleep 0` — disables idle system sleep
    /// ONLY in the AC power profile. It leaves the battery profile and
    /// `displaysleep` alone (the display still turns off), so it is far less
    /// invasive than `disablesleep`. Turning it off restores a configurable
    /// value (default 1 minute).
    var acIdleAwake: Bool = false
    /// The AC switch's own pending request: separate fields so the two
    /// switches can't clobber each other.
    var pendingACIdleAwake: Bool?
    var pendingACIdleSince: Date?
    /// "AC" or "Battery" — staying awake on battery with the lid closed drains
    /// it, so the card should show this.
    var powerSource: String?
    var batteryPercent: Int?
    var error: String?

    /// Spelled out because of the custom `init(from:)` below, and so that
    /// field names can't drift silently.
    enum CodingKeys: String, CodingKey {
        case updatedAt, enabled, pendingEnabled, pendingSince
        case acIdleAwake, pendingACIdleAwake, pendingACIdleSince
        case powerSource, batteryPercent, error
    }

    static let empty = SleepGuardSnapshot(updatedAt: .distantPast, enabled: false)

    var onBattery: Bool { powerSource == "Battery" }

    /// Is the request still live? If the app hasn't answered within 20 s,
    /// ignore it and let the stale badge speak.
    var activePending: Bool? {
        guard let pendingEnabled, let pendingSince,
              Date().timeIntervalSince(pendingSince) < 20 else { return nil }
        return pendingEnabled
    }

    /// Same for the AC switch.
    var activeACIdlePending: Bool? {
        guard let pendingACIdleAwake, let pendingACIdleSince,
              Date().timeIntervalSince(pendingACIdleSince) < 20 else { return nil }
        return pendingACIdleAwake
    }

    /// The app writes every minute; 5 min of silence = not running or stuck.
    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 5 * 60 }
}

extension SleepGuardSnapshot {
    /// Older `sleepguard.json` files lack the AC fields; the synthesized
    /// decoder would reject the whole file on a missing key and blank the
    /// card. Newer fields use `decodeIfPresent` and keep their defaults.
    /// (Declared in an extension: inside the struct body it would suppress
    /// the synthesized memberwise init, which call sites rely on.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        pendingEnabled = try c.decodeIfPresent(Bool.self, forKey: .pendingEnabled)
        pendingSince = try c.decodeIfPresent(Date.self, forKey: .pendingSince)
        acIdleAwake = try c.decodeIfPresent(Bool.self, forKey: .acIdleAwake) ?? false
        pendingACIdleAwake = try c.decodeIfPresent(Bool.self, forKey: .pendingACIdleAwake)
        pendingACIdleSince = try c.decodeIfPresent(Date.self, forKey: .pendingACIdleSince)
        powerSource = try c.decodeIfPresent(String.self, forKey: .powerSource)
        batteryPercent = try c.decodeIfPresent(Int.self, forKey: .batteryPercent)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

enum SleepGuardStore {
    static let fileURL = AppPaths.file("sleepguard.json")

    static let widgetContainerFileURL = AppPaths.widgetContainerFile("sleepguard.json")

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

    static func load() -> SleepGuardSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(SleepGuardSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: SleepGuardSnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
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
