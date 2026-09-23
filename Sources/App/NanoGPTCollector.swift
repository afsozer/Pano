import Foundation
import WidgetKit

/// Nano-GPT's two official endpoints: balance (the wallet) and usage (spend
/// breakdown). The balance is account-wide, usage is counted PER KEY, so the
/// two won't always agree (another machine may use another key).
enum NanoGPTCollector {
    static let balanceURL = URL(string: "https://nano-gpt.com/api/check-balance")!
    static let usageURL = "https://nano-gpt.com/api/v1/usage"
    /// Fallback key source: OpenCode stores provider keys here. Reusing it
    /// means one less copy of the secret; the key is never written into any
    /// snapshot.
    static let openCodeAuthFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")

    /// Lookup order: env `NANOGPT_API_KEY` → config `nanogptApiKey` →
    /// OpenCode's auth.json (`nanogpt.key`). nil = not configured.
    static func apiKey(config: PanoConfig = .current) -> String? {
        let fromEnv = (ProcessInfo.processInfo.environment["NANOGPT_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !fromEnv.isEmpty { return fromEnv }
        if let key = config.nanogptApiKey { return key }
        guard let data = try? Data(contentsOf: openCodeAuthFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["nanogpt"] as? [String: Any],
              let key = (entry["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    /// The balance endpoint returns numbers as STRINGS ("1.23651051"), the
    /// usage endpoint as numbers; accept both.
    private static func amount(_ value: Any?) -> Double? {
        if let text = value as? String { return Double(text) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func count(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    /// One usage window. Requested with `group_by=model`: no per-day
    /// breakdown needed, which keeps the response at 2–3 KB.
    private struct UsageWindow {
        var spendUsd: Double?
        var requests: Int?
        /// Model with the most REQUESTS (name, requests, spend).
        var top: (model: String, requests: Int, spendUsd: Double)?
    }

    private static func usage(key: String, from: String? = nil, to: String? = nil) async throws -> UsageWindow {
        var components = URLComponents(string: usageURL)!
        var query = [URLQueryItem(name: "group_by", value: "model")]
        if let from, let to {
            query.append(URLQueryItem(name: "from", value: from))
            query.append(URLQueryItem(name: "to", value: to))
        }
        components.queryItems = query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let body = try await URLSession.json(request)

        var window = UsageWindow()
        if let totals = body["totals"] as? [String: Any] {
            window.spendUsd = amount(totals["netCostUsd"]) ?? amount(totals["costUsd"])
            window.requests = count(totals["requests"])
        }
        let models = (body["byModel"] as? [[String: Any]]) ?? []
        // "Most used" = most requests. Sorting by spend would let a single
        // video generation outrank 200 chats.
        if let best = models.max(by: { (count($0["requests"]) ?? 0) < (count($1["requests"]) ?? 0) }),
           let name = best["model"] as? String, let requests = count(best["requests"]), requests > 0 {
            window.top = (name, requests, amount(best["netCostUsd"]) ?? amount(best["costUsd"]) ?? 0)
        }
        return window
    }

    /// The endpoint's day buckets are UTC, so "today" is requested in UTC too.
    private static func utcToday() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func fetch(previous: NanoGPTSnapshot) async -> NanoGPTSnapshot {
        let config = PanoConfig.current
        var snapshot = previous
        snapshot.error = nil
        snapshot.fullScaleUsd = config.nanogptFullScaleUsd
        guard let key = apiKey(config: config) else {
            // Not an error: the card shows a setup hint. Drop old figures so
            // a removed key doesn't leave a stale balance on screen.
            var empty = NanoGPTSnapshot.empty
            empty.updatedAt = Date()
            empty.missingKey = true
            empty.fullScaleUsd = config.nanogptFullScaleUsd
            return empty
        }
        snapshot.missingKey = nil

        do {
            var request = URLRequest(url: balanceURL)
            request.httpMethod = "POST"
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("{}".utf8)
            let body = try await URLSession.json(request)
            guard let usd = amount(body["usd_balance"]) else {
                throw FetchError(String(localized: "usd_balance missing"))
            }
            snapshot.usdBalance = usd
            snapshot.pendingUsd = amount(body["usd_pending_usage"])
            snapshot.nanoBalance = amount(body["nano_balance"])
            snapshot.updatedAt = Date()
        } catch {
            // KEEP the last good value and its updatedAt: the card shows its
            // own stale badge instead of blanking on a transient network error.
            snapshot.error = error.localizedDescription
        }

        do {
            let today = utcToday()
            async let todayWindow = usage(key: key, from: today, to: today)
            // Without a range the endpoint returns the last 30 UTC days.
            async let monthWindow = usage(key: key)
            let (day, month) = try await (todayWindow, monthWindow)
            snapshot.todaySpendUsd = day.spendUsd
            snapshot.todayRequests = day.requests
            snapshot.windowSpendUsd = month.spendUsd
            snapshot.windowRequests = month.requests
            snapshot.windowDays = 30
            snapshot.topModel = month.top?.model
            snapshot.topModelRequests = month.top?.requests
            snapshot.topModelSpendUsd = month.top?.spendUsd
            snapshot.usageError = nil
        } catch {
            // Usage is independent of the balance: on failure the old figures
            // stay and the card only mentions the error in its footer.
            snapshot.usageError = error.localizedDescription
        }
        return snapshot
    }
}

/// Menu bar agent: fetches balance and usage, writes the snapshot, reloads the
/// widget and the menu panel.
@MainActor
final class NanoGPTAgent: ObservableObject {
    @Published private(set) var snapshot: NanoGPTSnapshot = NanoGPTStore.load() ?? .empty

    private var timer: Timer?
    private var refreshObserver: NSObjectProtocol?
    private var refreshing = false

    init() {
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .refreshAllWidgets, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
        // The balance only drops with use; the quota agent's 5 minutes is plenty.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    deinit {
        if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let fresh = await NanoGPTCollector.fetch(previous: snapshot)
        snapshot = fresh
        NanoGPTStore.save(fresh, mirrorToWidgetContainer: true)
        WidgetCenter.shared.reloadTimelines(ofKind: "NanoGPTWidget")
    }
}
