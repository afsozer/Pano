import Foundation

/// State of the local LLM server (oMLX, run as a `brew services` service).
/// The menu bar app writes the snapshot, the widget only reads it; start/stop
/// and "warm up" requests come from the widget as intents (the extension is
/// sandboxed and can neither make HTTP requests nor run `brew`).
///
/// EVERY field is optional or defaulted: the `/api/status` body is specific to
/// oMLX 0.6.x and field names may change between versions. Missing fields stay
/// nil and the card doesn't break (the custom `init(from:)` below also accepts
/// older and newer JSON).
struct LocalLLMSnapshot: Codable, Hashable {
    var updatedAt: Date
    /// `brew services info <service>` → registered with launchd and running.
    /// nil if it couldn't be read (e.g. Homebrew or the formula is missing).
    var serviceRegistered: Bool?
    /// Did the HTTP endpoint answer? The service may be registered but still
    /// starting up.
    var reachable: Bool = false
    var version: String?
    var uptimeSec: Double?
    var modelsDiscovered: Int?
    /// Models in memory — as `/v1/models` aliases, not raw directory names.
    var loadedModels: [String] = []
    var loadingCount: Int = 0
    var activeRequests: Int = 0
    var waitingRequests: Int = 0
    /// Alias of the server's default model (what "warm" loads if nothing is
    /// selected).
    var defaultModel: String?
    /// Picker order: the config's model list, or every alias the server lists.
    var availableModels: [String] = []
    /// Alias picked on the card (warm target). nil = default.
    var selectedModel: String?
    /// Alias → short label, copied from the app config (the sandboxed widget
    /// can't read it).
    var modelDisplayNames: [String: String] = [:]
    /// `max_model_len` of the shown model (65536 → "64k").
    var contextWindow: Int?
    var modelMemoryBytes: UInt64?
    /// Counters for this server session (reset when the service restarts).
    var promptTokens: Int?
    var completionTokens: Int?
    var cachedTokens: Int?
    /// `<omlx home>/stats.json` — lifetime totals, available even while the
    /// service is stopped.
    var lifetimeRequests: Int?
    var lifetimePromptTokens: Int?
    var lifetimeCachedTokens: Int?
    /// From the stats.json totals: completion_tokens / generation_duration.
    /// Shown instead of a dash while the server is idle or stopped.
    var lifetimeGenerationTps: Double?
    var lifetimePrefillTps: Double?
    /// The server's own averages (per session).
    var avgPrefillTps: Double?
    var avgGenerationTps: Double?
    /// Completion-token delta between two polls / elapsed time — the "right
    /// now" speed. The server's session average freezes when generation ends;
    /// this one stays live.
    var recentGenerationTps: Double?
    /// Total size of the SSD KV cache directory (measured every 5 min with
    /// `URLResourceValues`, not `du` — same method as the storage card).
    var ssdCacheBytes: UInt64?
    /// Request from the widget not yet completed: "start" / "stop" / "warm".
    var pendingAction: String?
    var pendingSince: Date?
    var error: String?

    static let empty = LocalLLMSnapshot(updatedAt: .distantPast)

    // MARK: Derived

    enum State: String {
        case off, idle, loading, ready, busy
    }

    /// State machine: OFF (unreachable) → IDLE (no model) → LOADING →
    /// READY → BUSY (generating).
    var state: State {
        guard reachable else { return .off }
        if activeRequests > 0 { return .busy }
        if loadingCount > 0 { return .loading }
        // Show the loading state while a warm-up is pending: the user pressed
        // the button but the model isn't in memory yet.
        if activeAction == "warm" && loadedModels.isEmpty { return .loading }
        return loadedModels.isEmpty ? .idle : .ready
    }

    var badge: String {
        switch state {
        case .off: return String(localized: "OFF")
        case .idle: return String(localized: "IDLE")
        case .loading: return String(localized: "LOADING")
        case .ready: return String(localized: "READY")
        case .busy: return String(localized: "BUSY")
        }
    }

    /// Is the request still live? If the app hasn't answered within 20 s
    /// (not running or stuck), ignore the pending flag. During long actions
    /// (start/warm) the app refreshes `pendingSince` every poll, so 20 s is
    /// not too tight.
    var activeAction: String? {
        guard let pendingAction, let pendingSince,
              Date().timeIntervalSince(pendingSince) < 20 else { return nil }
        return pendingAction
    }

    /// Switch position to draw: the target state while a request is pending
    /// (instant feedback on tap), otherwise the real state.
    var shownRunning: Bool {
        switch activeAction {
        case "start": return true
        case "stop": return false
        default: return reachable
        }
    }

    /// Model named on the card: the selected one, else the loaded one, else
    /// the default, else the first in the picker list.
    var shownModel: String? { selectedModel ?? loadedModels.first ?? defaultModel ?? availableModels.first }
    /// Warm-up target.
    var warmTarget: String? { selectedModel ?? defaultModel ?? loadedModels.first ?? availableModels.first }
    /// Next alias in the picker (wraps around).
    var nextModel: String? {
        guard !availableModels.isEmpty else { return nil }
        guard let current = shownModel, let i = availableModels.firstIndex(of: current) else {
            return availableModels.first
        }
        return availableModels[(i + 1) % availableModels.count]
    }
    /// Warm-up makes sense: server up and the target model not in memory.
    var canWarm: Bool {
        guard reachable, loadingCount == 0, let target = warmTarget else { return false }
        return !loadedModels.contains(target)
    }

    /// Raw aliases rarely fit the card's 100 pt picker. A label from the
    /// config's `displayNames` wins; otherwise a generic rule drops an
    /// "-omlx" suffix and truncates at 20 characters
    /// ("mistral-small-24b-omlx" → "mistral-small-24b").
    static func shortModel(_ alias: String?, displayNames: [String: String] = [:]) -> String? {
        guard var name = alias, !name.isEmpty else { return nil }
        if let pretty = displayNames[name] ?? displayNames[name.lowercased()] { return pretty }
        if name.lowercased().hasSuffix("-omlx") { name.removeLast(5) }
        return name.count > 20 ? String(name.prefix(20)) : name
    }

    var shortModelName: String? { Self.shortModel(shownModel, displayNames: modelDisplayNames) }

    /// Cache hit rate: this session's if there is data, else from lifetime
    /// totals (session counters are zero right after a restart).
    var cacheHitPercent: Double? {
        if let p = promptTokens, p > 0, let c = cachedTokens {
            return min(100, Double(c) / Double(p) * 100)
        }
        if let p = lifetimePromptTokens, p > 0, let c = lifetimeCachedTokens {
            return min(100, Double(c) / Double(p) * 100)
        }
        return nil
    }

    /// Generation speed to show: the live measurement, else the server's
    /// session average, else the lifetime average.
    var generationTps: Double? {
        if let recent = recentGenerationTps, recent > 0 { return recent }
        if let avg = avgGenerationTps, avg > 0 { return avg }
        if let life = lifetimeGenerationTps, life > 0 { return life }
        return nil
    }

    /// "18h" / "42m" / "9s".
    var uptimeText: String? {
        guard let uptimeSec, uptimeSec > 0 else { return nil }
        let s = Int(uptimeSec)
        if s >= 3600 { let n = String(s / 3600); return String(localized: "\(n)h") }
        if s >= 60 { let n = String(s / 60); return String(localized: "\(n)m") }
        let n = String(s)
        return String(localized: "\(n)s")
    }

    /// 65536 → "64k".
    var contextText: String? {
        guard let contextWindow, contextWindow > 0 else { return nil }
        if contextWindow >= 1024 { return "\(contextWindow / 1024)k" }
        return "\(contextWindow)"
    }

    /// The app writes every 15 s while the server is up; 5 min of silence =
    /// app not running or stuck.
    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 5 * 60 }

    // MARK: Codable
    //
    // The synthesized decoder throws on a missing key, so an older file would
    // become unreadable whenever a field is added. Everything is lenient.

    enum CodingKeys: String, CodingKey {
        case updatedAt, serviceRegistered, reachable, version, uptimeSec
        case modelsDiscovered, loadedModels, loadingCount, activeRequests, waitingRequests
        case defaultModel, availableModels, selectedModel, modelDisplayNames, contextWindow, modelMemoryBytes
        case promptTokens, completionTokens, cachedTokens
        case lifetimeRequests, lifetimePromptTokens, lifetimeCachedTokens, lifetimeGenerationTps, lifetimePrefillTps
        case avgPrefillTps, avgGenerationTps, recentGenerationTps
        case ssdCacheBytes, pendingAction, pendingSince, error
    }

    init(updatedAt: Date) { self.updatedAt = updatedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // nil when the key is missing or has the wrong type, so both older
        // and newer files decode.
        func opt<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        updatedAt = opt(Date.self, .updatedAt) ?? .distantPast
        serviceRegistered = opt(Bool.self, .serviceRegistered)
        reachable = opt(Bool.self, .reachable) ?? false
        version = opt(String.self, .version)
        uptimeSec = opt(Double.self, .uptimeSec)
        modelsDiscovered = opt(Int.self, .modelsDiscovered)
        loadedModels = opt([String].self, .loadedModels) ?? []
        loadingCount = opt(Int.self, .loadingCount) ?? 0
        activeRequests = opt(Int.self, .activeRequests) ?? 0
        waitingRequests = opt(Int.self, .waitingRequests) ?? 0
        defaultModel = opt(String.self, .defaultModel)
        availableModels = opt([String].self, .availableModels) ?? []
        selectedModel = opt(String.self, .selectedModel)
        modelDisplayNames = opt([String: String].self, .modelDisplayNames) ?? [:]
        contextWindow = opt(Int.self, .contextWindow)
        modelMemoryBytes = opt(UInt64.self, .modelMemoryBytes)
        promptTokens = opt(Int.self, .promptTokens)
        completionTokens = opt(Int.self, .completionTokens)
        cachedTokens = opt(Int.self, .cachedTokens)
        lifetimeRequests = opt(Int.self, .lifetimeRequests)
        lifetimePromptTokens = opt(Int.self, .lifetimePromptTokens)
        lifetimeCachedTokens = opt(Int.self, .lifetimeCachedTokens)
        lifetimeGenerationTps = opt(Double.self, .lifetimeGenerationTps)
        lifetimePrefillTps = opt(Double.self, .lifetimePrefillTps)
        avgPrefillTps = opt(Double.self, .avgPrefillTps)
        avgGenerationTps = opt(Double.self, .avgGenerationTps)
        recentGenerationTps = opt(Double.self, .recentGenerationTps)
        ssdCacheBytes = opt(UInt64.self, .ssdCacheBytes)
        pendingAction = opt(String.self, .pendingAction)
        pendingSince = opt(Date.self, .pendingSince)
        error = opt(String.self, .error)
    }
}

enum LocalLLMStore {
    static let fileURL = AppPaths.file("localllm.json")

    /// App Groups need a provisioning profile, which ad-hoc signing can't
    /// provide, so the app also writes the snapshot into the extension's
    /// container. Inside the extension `~` already resolves there, so the
    /// reading code is shared.
    static let widgetContainerFileURL = AppPaths.widgetContainerFile("localllm.json")

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

    static func load() -> LocalLLMSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(LocalLLMSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: LocalLLMSnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
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

/// The model picked on the card lives in a SEPARATE file: the app rewrites
/// localllm.json every 15 s and would wipe a selection stored inside it. The
/// extension writes into its own container; the app reads it from there.
enum LocalLLMSelectionStore {
    static let fileURL = AppPaths.file("localllm-selection.json")
    static let widgetContainerFileURL = AppPaths.widgetContainerFile("localllm-selection.json")

    struct Selection: Codable { var model: String }

    static func load(from url: URL = fileURL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let sel = try? JSONDecoder().decode(Selection.self, from: data) else { return nil }
        return sel.model
    }

    static func save(_ model: String, to url: URL = fileURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Selection(model: model)) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
