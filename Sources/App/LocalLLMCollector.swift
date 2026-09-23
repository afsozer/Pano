import Foundation
import WidgetKit

/// Polls the oMLX server and carries out actions requested from the card.
///
/// Sources (all local, no root):
/// - `GET /api/status` → version, uptime, loaded/loading models, request and
///   token counters, tok/s averages, model memory.
/// - `GET /v1/models` → alias list + `max_model_len`.
/// - `<home>/model_settings.json` → raw model name → alias map
///   (`/api/status` reports raw names, `/v1/models` aliases).
/// - `<home>/stats.json` → lifetime totals, readable while the server is down.
/// - `<home>/settings.json` → default host/port and SSD cache directory.
/// - Size of the SSD KV cache directory.
/// - `brew services info <service>` → launchd state.
///
/// Everything machine-specific comes from `PanoConfig` (see its schema).
enum LocalLLMCollector {
    /// Resolved settings for one poll.
    struct Settings {
        var baseURL: String
        var home: URL
        var ssdCacheURL: URL?
        var brewPath: String?
        var service: String
        /// The formula may come from a tap (`jundot/omlx/omlx`): `start`
        /// needs the full name, `stop` and `info` work with the short one.
        var formula: String
        var models: [String]
        var displayNames: [String: String]
    }

    static func settings(_ config: PanoConfig = .current) -> Settings {
        let o = config.omlx
        let home = PanoConfig.expand(o.home)
        let server = readJSONFile(home.appendingPathComponent("settings.json"))
        var baseURL = o.baseURL
        if baseURL == nil, let srv = server?["server"] as? [String: Any] {
            var host = (srv["host"] as? String) ?? "127.0.0.1"
            // A wildcard bind address isn't something we can connect to.
            if host == "0.0.0.0" || host == "::" || host.isEmpty { host = "127.0.0.1" }
            if host.contains(":") { host = "[\(host)]" }
            let port = (srv["port"] as? Int) ?? 8000
            baseURL = "http://\(host):\(port)"
        }
        var cache = o.ssdCacheDir.map(PanoConfig.expand)
        if cache == nil, let dir = (server?["cache"] as? [String: Any])?["ssd_cache_dir"] as? String, !dir.isEmpty {
            cache = PanoConfig.expand(dir)
        }
        let brew = o.brewPath ?? ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        return Settings(baseURL: baseURL ?? "http://127.0.0.1:8000", home: home, ssdCacheURL: cache,
                        brewPath: brew, service: o.brewService, formula: o.brewFormula,
                        models: o.models, displayNames: o.displayNames)
    }

    // MARK: HTTP

    /// Local request with a short timeout. `URLSession.json` waits 20 s; a
    /// stopped server refuses instantly, but one that is starting up can hang,
    /// and a poll shouldn't be held for more than 2 s.
    private static func getJSON(_ baseURL: String, _ path: String, timeout: TimeInterval = 2) async -> [String: Any]? {
        guard let url = URL(string: baseURL + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.setValue("Pano/1.0", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: req),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    // MARK: Helpers

    private static func readJSONFile(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Raw model name → alias. `loaded_models` and `default_model` in
    /// `/api/status` are raw directory names ("Some-Model-27B-MLX-4bit"); the
    /// card shows aliases ("some-model-27b-omlx").
    static func aliasMap(home: URL) -> [String: String] {
        guard let root = readJSONFile(home.appendingPathComponent("model_settings.json")),
              let models = root["models"] as? [String: Any] else { return [:] }
        var map: [String: String] = [:]
        for (raw, value) in models {
            if let dict = value as? [String: Any], let alias = dict["model_alias"] as? String {
                map[raw] = alias
            }
        }
        return map
    }

    /// Total size of a directory. `URLResourceValues`, not `du`: same method
    /// as the storage card, no subprocess.
    static func directorySize(_ url: URL) -> UInt64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
        ) else { return nil }
        var total: UInt64 = 0
        for case let child as URL in enumerator {
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// `brew services info omlx` prints:
    /// ```
    /// omlx (sh.brew.omlx)
    /// Running: true
    /// Loaded: true
    /// ```
    /// (Measured — the `✔`/`✘` marks only appear in the coloured output of
    /// `brew services list`.) Returns whether it runs; nil if the command
    /// failed (no Homebrew, unknown service).
    static func brewRunning(_ settings: Settings) -> Bool? {
        guard let brewPath = settings.brewPath else { return nil }
        let result = Shell.run(brewPath, ["services", "info", settings.service])
        guard result.status == 0 else { return nil }
        for line in result.out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Running:") else { continue }
            let value = trimmed.dropFirst("Running:".count).trimmingCharacters(in: .whitespaces)
            return value.hasPrefix("true") || value.hasPrefix("✔")
        }
        return false
    }

    // MARK: Polling

    /// `previous`: the prior snapshot — live generation speed is derived from
    /// the completion-token delta between two samples. `cacheBytes` is
    /// measured every 5 min and carried over in between.
    static func collect(previous: LocalLLMSnapshot?, cacheBytes: UInt64?,
                        settings: Settings = settings()) async -> LocalLLMSnapshot {
        var snapshot = LocalLLMSnapshot(updatedAt: Date())
        snapshot.ssdCacheBytes = cacheBytes ?? previous?.ssdCacheBytes
        snapshot.modelDisplayNames = settings.displayNames

        // Keep brew (a subprocess) off the main thread.
        snapshot.serviceRegistered = await Task.detached(priority: .utility) { brewRunning(settings) }.value

        // Lifetime totals are readable while the server is down, too.
        if let stats = readJSONFile(settings.home.appendingPathComponent("stats.json")) {
            snapshot.lifetimeRequests = stats["total_requests"] as? Int
            snapshot.lifetimePromptTokens = stats["total_prompt_tokens"] as? Int
            snapshot.lifetimeCachedTokens = stats["total_cached_tokens"] as? Int
            if let gen = stats["total_generation_duration"] as? Double, gen > 0,
               let tokens = stats["total_completion_tokens"] as? Int {
                snapshot.lifetimeGenerationTps = Double(tokens) / gen
            }
            if let pre = stats["total_prefill_duration"] as? Double, pre > 0,
               let tokens = stats["total_prompt_tokens"] as? Int {
                snapshot.lifetimePrefillTps = Double(tokens) / pre
            }
        }

        let map = aliasMap(home: settings.home)
        func alias(_ raw: String) -> String { map[raw] ?? raw }

        // Unreachable = "off" state, not an error: no oMLX installed looks
        // the same as oMLX stopped.
        guard let status = await getJSON(settings.baseURL, "/api/status") else {
            snapshot.reachable = false
            return snapshot
        }
        snapshot.reachable = true
        snapshot.version = status["version"] as? String
        snapshot.uptimeSec = status["uptime_seconds"] as? Double
        snapshot.modelsDiscovered = status["models_discovered"] as? Int
        snapshot.loadedModels = (status["loaded_models"] as? [String] ?? []).map(alias)
        snapshot.loadingCount = status["models_loading"] as? Int ?? 0
        snapshot.activeRequests = status["active_requests"] as? Int ?? 0
        snapshot.waitingRequests = status["waiting_requests"] as? Int ?? 0
        snapshot.defaultModel = (status["default_model"] as? String).map(alias)
        snapshot.promptTokens = status["total_prompt_tokens"] as? Int
        snapshot.completionTokens = status["total_completion_tokens"] as? Int
        snapshot.cachedTokens = status["total_cached_tokens"] as? Int
        snapshot.avgPrefillTps = status["avg_prefill_tps"] as? Double
        snapshot.avgGenerationTps = status["avg_generation_tps"] as? Double
        if let mem = status["model_memory_used"] as? UInt64 {
            snapshot.modelMemoryBytes = mem
        } else if let mem = status["model_memory_used"] as? Int, mem >= 0 {
            snapshot.modelMemoryBytes = UInt64(mem)
        }

        // The selection comes from the extension's container (the card writes
        // it there); drop it if the server no longer lists that alias.
        snapshot.selectedModel = LocalLLMSelectionStore.load(from: LocalLLMSelectionStore.widgetContainerFileURL)
        if let models = await getJSON(settings.baseURL, "/v1/models")?["data"] as? [[String: Any]] {
            // Picker order: the configured list (only aliases the server
            // actually has), else every alias the server lists, sorted.
            let served = models.compactMap { $0["id"] as? String }
            let configured = settings.models.filter(served.contains)
            snapshot.availableModels = configured.isEmpty ? served.sorted() : configured
            if let sel = snapshot.selectedModel, !snapshot.availableModels.contains(sel) {
                snapshot.selectedModel = nil
            }
            // Context window = `max_model_len` of the model shown on the card.
            let target = snapshot.shownModel
            let entry = models.first { ($0["id"] as? String) == target } ?? models.first
            snapshot.contextWindow = entry?["max_model_len"] as? Int
        }

        // Live generation speed: the server's `avg_generation_tps` is a
        // session average that freezes when generation stops. The completion
        // delta between two samples gives the "right now" speed. Skip it if
        // the service restarted (uptime went backwards) or the counter fell.
        if let prev = previous, let now = snapshot.completionTokens, let before = prev.completionTokens,
           now >= before, (snapshot.uptimeSec ?? 0) >= (prev.uptimeSec ?? 0) {
            let elapsed = snapshot.updatedAt.timeIntervalSince(prev.updatedAt)
            if elapsed > 1, elapsed < 120 {
                let delta = Double(now - before)
                snapshot.recentGenerationTps = delta > 0 ? delta / elapsed : 0
            }
        }
        return snapshot
    }

    // MARK: Actions

    /// `brew services start <formula>`, then poll `/v1/models`.
    /// Returns an error message or nil.
    static func startService(_ settings: Settings = settings()) async -> String? {
        guard let brewPath = settings.brewPath else { return String(localized: "Homebrew not found") }
        let result = await Task.detached(priority: .userInitiated) {
            Shell.runCapturing(brewPath, ["services", "start", settings.formula])
        }.value
        if result.status != 0 {
            let err = (result.err ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? String(localized: "brew services start failed") : String(err.prefix(80))
        }
        // The server scans its model directory while starting; poll up to 40 s.
        for _ in 0..<40 {
            if await getJSON(settings.baseURL, "/v1/models") != nil { return nil }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return String(localized: "no response in 40 s")
    }

    static func stopService(_ settings: Settings = settings()) async -> String? {
        guard let brewPath = settings.brewPath else { return String(localized: "Homebrew not found") }
        let result = await Task.detached(priority: .userInitiated) {
            Shell.runCapturing(brewPath, ["services", "stop", settings.service])
        }.value
        if result.status != 0 {
            let err = (result.err ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return err.isEmpty ? String(localized: "brew services stop failed") : String(err.prefix(80))
        }
        return nil
    }

    /// "Warm up": a 1-token chat request to the target alias. A 27B 4-bit
    /// model loaded in ~6.5 s in testing, but a cold disk can take much
    /// longer: timeout 180 s. There is NO unload endpoint; the model drops
    /// out by itself when its TTL expires.
    static func warm(alias: String, settings: Settings = settings()) async -> String? {
        guard let url = URL(string: settings.baseURL + "/v1/chat/completions") else {
            return String(localized: "invalid server URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Pano/1.0", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 180
        let body: [String: Any] = [
            "model": alias,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 180
        config.timeoutIntervalForResource = 180
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return String(localized: "no response") }
            return (200..<300).contains(http.statusCode) ? nil : "HTTP \(http.statusCode)"
        } catch {
            return String(localized: "warm-up failed")
        }
    }
}

/// Menu bar agent: polls the server, writes the snapshot, and carries out
/// start/stop/warm requests from the card.
@MainActor
final class LocalLLMAgent: ObservableObject {
    @Published var snapshot: LocalLLMSnapshot = LocalLLMStore.load() ?? .empty
    @Published var busy = false

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// While the server is down, poll only every fourth tick (60 s).
    private var tick = 0
    private var lastCacheMeasure: Date = .distantPast
    private var cacheBytes: UInt64?

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .refreshAllWidgets, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh(force: true) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .localLLMActionRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let action = note.userInfo?["action"] as? String else { return }
            Task { @MainActor in await self?.perform(action: action) }
        })
        Task { await refresh(force: true) }
        // One 15 s timer; while the server is down three of four ticks are
        // skipped (60 s). Simpler than juggling two timers.
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refresh(force: Bool = false) async {
        tick &+= 1
        // 60 s while the server is down: HTTP is refused instantly anyway, but
        // there's no point spawning brew every 15 s.
        if !force, !snapshot.reachable, tick % 4 != 0 { return }

        let settings = LocalLLMCollector.settings()
        // The cache directory can be tens of GB; every 5 minutes is enough.
        if let cacheURL = settings.ssdCacheURL, Date().timeIntervalSince(lastCacheMeasure) > 300 {
            lastCacheMeasure = Date()
            let measured = await Task.detached(priority: .utility) {
                LocalLLMCollector.directorySize(cacheURL)
            }.value
            if let measured { cacheBytes = measured }
        }

        var fresh = await LocalLLMCollector.collect(previous: snapshot, cacheBytes: cacheBytes, settings: settings)
        // While a long action is running, carry the pending flag over and
        // refresh its timestamp so the card doesn't fall out of the 20 s window.
        if busy, let action = snapshot.pendingAction {
            fresh.pendingAction = action
            fresh.pendingSince = Date()
            fresh.error = snapshot.error
        }
        publish(fresh)
    }

    /// action: "start" | "stop" | "warm"
    func perform(action: String) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        var s = snapshot
        s.pendingAction = action
        s.pendingSince = Date()
        s.error = nil
        publish(s)

        var error: String?
        switch action {
        case "start": error = await LocalLLMCollector.startService()
        case "stop": error = await LocalLLMCollector.stopService()
        case "warm":
            if let alias = snapshot.warmTarget {
                error = await LocalLLMCollector.warm(alias: alias)
            } else {
                error = String(localized: "no model to warm")
            }
        default: error = String(localized: "unknown action")
        }

        var done = snapshot
        done.pendingAction = nil
        done.pendingSince = nil
        done.error = error
        done.updatedAt = Date()
        publish(done)
        busy = false
        await refresh(force: true)
    }

    private func publish(_ s: LocalLLMSnapshot) {
        snapshot = s
        LocalLLMStore.save(s, mirrorToWidgetContainer: true)
        WidgetCenter.shared.reloadTimelines(ofKind: "LocalLLMWidget")
    }
}

extension Notification.Name {
    static let localLLMActionRequested = Notification.Name("Pano.localLLMActionRequested")
}
