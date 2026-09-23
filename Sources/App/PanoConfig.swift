import Foundation

/// Optional per-user settings, read from `~/.config/pano/config.json`.
///
/// Every key is optional. A missing file, a missing key or a malformed file
/// all fall back to the defaults below; the loader never throws. The file is
/// re-read whenever its modification date changes, so edits apply on the next
/// refresh without restarting the app.
///
/// Only the menu bar app reads this file. The widget extension is sandboxed
/// (`~` resolves to its container), so anything a widget needs, such as the
/// Nano-GPT bar scale or model display names, is copied into the snapshot.
///
/// Schema:
///
///     {
///       "nanogptApiKey": String        // overridden by env NANOGPT_API_KEY
///       "nanogptFullScaleUsd": Number  // balance that fills the bar, default 10
///       "omlx": {
///         "baseURL": String            // default: host/port from <home>/settings.json,
///                                      //          else http://127.0.0.1:8000
///         "home": String               // oMLX state dir, default "~/.omlx"
///         "ssdCacheDir": String        // default: cache.ssd_cache_dir from settings.json
///         "brewPath": String           // default: /opt/homebrew/bin/brew or /usr/local/bin/brew
///         "brewService": String        // name for `brew services info/stop`, default "omlx"
///         "brewFormula": String        // full name for `brew services start`, default "jundot/omlx/omlx"
///         "models": [String]           // picker order; empty = every alias the server lists
///         "displayNames": {String: String} // alias -> short label for the widget picker
///       },
///       "sleepGuard": {
///         "acSleepRestoreMinutes": Int // AC idle-sleep value restored when the
///                                      // "on AC" switch is turned off, default 1
///       }
///     }
struct PanoConfig: Equatable {
    var nanogptApiKey: String?
    var nanogptFullScaleUsd: Double = 10
    var omlx = OMLX()
    var sleepGuard = SleepGuard()

    struct OMLX: Equatable {
        var baseURL: String?
        var home: String = "~/.omlx"
        var ssdCacheDir: String?
        var brewPath: String?
        var brewService: String = "omlx"
        var brewFormula: String = "jundot/omlx/omlx"
        var models: [String] = []
        var displayNames: [String: String] = [:]
    }

    struct SleepGuard: Equatable {
        var acSleepRestoreMinutes: Int = 1
    }

    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/pano/config.json")

    /// Paste-ready example for the README.
    static let example = """
    {
      "nanogptApiKey": "YOUR_NANOGPT_API_KEY",
      "nanogptFullScaleUsd": 10,
      "omlx": {
        "baseURL": "http://127.0.0.1:8000",
        "home": "~/.omlx",
        "brewService": "omlx",
        "brewFormula": "jundot/omlx/omlx",
        "models": ["my-model-a", "my-model-b"],
        "displayNames": { "my-model-a": "Model A 27B" }
      },
      "sleepGuard": {
        "acSleepRestoreMinutes": 1
      }
    }
    """

    // MARK: Loading

    private static let lock = NSLock()
    private static var cached: (stamp: Date?, config: PanoConfig)?

    /// Current config; re-parsed only when the file's mtime changes.
    static var current: PanoConfig {
        let stamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        lock.lock(); defer { lock.unlock() }
        if let cached, cached.stamp == stamp { return cached.config }
        let config = (try? Data(contentsOf: fileURL)).map(parse) ?? PanoConfig()
        cached = (stamp, config)
        return config
    }

    /// Lenient parser: wrong types are ignored key by key instead of rejecting
    /// the whole file.
    static func parse(_ data: Data) -> PanoConfig {
        var config = PanoConfig()
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return config }

        config.nanogptApiKey = nonEmpty(root["nanogptApiKey"])
        if let scale = number(root["nanogptFullScaleUsd"]), scale > 0 { config.nanogptFullScaleUsd = scale }

        if let o = root["omlx"] as? [String: Any] {
            config.omlx.baseURL = nonEmpty(o["baseURL"]).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            if let home = nonEmpty(o["home"]) { config.omlx.home = home }
            config.omlx.ssdCacheDir = nonEmpty(o["ssdCacheDir"])
            config.omlx.brewPath = nonEmpty(o["brewPath"])
            if let service = nonEmpty(o["brewService"]) { config.omlx.brewService = service }
            if let formula = nonEmpty(o["brewFormula"]) { config.omlx.brewFormula = formula }
            if let models = o["models"] as? [Any] { config.omlx.models = models.compactMap(nonEmpty) }
            if let names = o["displayNames"] as? [String: Any] {
                config.omlx.displayNames = names.compactMapValues(nonEmpty)
            }
        }

        if let s = root["sleepGuard"] as? [String: Any],
           let minutes = number(s["acSleepRestoreMinutes"]), minutes >= 1, minutes <= 600 {
            config.sleepGuard.acSleepRestoreMinutes = Int(minutes)
        }
        return config
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber, !(n === kCFBooleanTrue || n === kCFBooleanFalse) { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    /// `~/x` → absolute path.
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
