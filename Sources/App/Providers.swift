import Foundation

// MARK: - Small helpers

enum Shell {
    /// Minimal process runner. The Claude credential lives in the Keychain and
    /// /usr/bin/security can read that item without a prompt; calling
    /// SecItemCopyMatching from our own (ad-hoc signed) binary would raise an
    /// ACL prompt after every rebuild.
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> (out: String, status: Int32) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", p.terminationStatus)
    }
}

struct FetchError: LocalizedError {
    let message: String
    /// The provider isn't set up on this Mac; the card shows a setup hint.
    var signedOut = false
    var errorDescription: String? { message }
    init(_ m: String, signedOut: Bool = false) { message = m; self.signedOut = signedOut }
}

extension URLSession {
    /// JSON GET/POST. Non-2xx status codes become errors.
    static func json(_ request: URLRequest) async throws -> [String: Any] {
        var req = request
        req.timeoutInterval = 20
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue("Pano/1.0", forHTTPHeaderField: "User-Agent")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw FetchError(String(localized: "no response"))
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 { throw FetchError(String(localized: "rate limited (HTTP 429)")) }
            throw FetchError("HTTP \(http.statusCode)")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError(String(localized: "couldn’t parse JSON"))
        }
        return obj
    }
}

private func iso(_ s: Any?) -> Date? {
    guard let str = s as? String else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: str) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: str)
}

private func num(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let i = v as? Int { return Double(i) }
    if let n = v as? NSNumber { return n.doubleValue }
    return nil
}

/// Decodes a JWT's payload (no signature check; we only read our own tokens).
private func jwtPayload(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count > 1 else { return nil }
    var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while b64.count % 4 != 0 { b64 += "=" }
    guard let data = Data(base64Encoded: b64) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

private func setFailure(_ usage: inout ProviderUsage, _ error: Error) {
    usage.error = error.localizedDescription
    if (error as? FetchError)?.signedOut == true { usage.signedOut = true }
}

// MARK: - Claude Code

enum ClaudeProvider {
    static let service = "Claude Code-credentials"
    /// Claude Code's public OAuth client id (same for every install).
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// On macOS Claude Code keeps its credential in the Keychain, not in a
    /// file. The file is only a fallback for setups that write one anyway.
    static let credentialsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/.credentials.json")

    private enum Source { case keychain, file }

    /// `security` exits with 44 when the item doesn't exist; any other
    /// failure (locked keychain, denied access) is a real error.
    private static func readCreds() throws -> (creds: [String: Any], source: Source) {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service, "-w"])
        if r.status == 0, let data = r.out.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (obj, .keychain)
        }
        if let data = try? Data(contentsOf: credentialsFile),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return (obj, .file)
        }
        if r.status == 44 {
            throw FetchError(ProviderKey.claude.signedOutMessage, signedOut: true)
        }
        throw FetchError(String(localized: "couldn’t read the Claude credential from the Keychain"))
    }

    private static func account() -> String {
        let r = Shell.run("/usr/bin/security", ["find-generic-password", "-s", service])
        for line in r.out.split(separator: "\n") where line.contains("\"acct\"") {
            if let range = line.range(of: "=\"") {
                let rest = line[range.upperBound...]
                if let end = rest.lastIndex(of: "\"") { return String(rest[..<end]) }
            }
        }
        return NSUserName()
    }

    private static func write(_ creds: [String: Any], to source: Source) {
        guard let data = try? JSONSerialization.data(withJSONObject: creds) else { return }
        switch source {
        case .keychain:
            guard let json = String(data: data, encoding: .utf8) else { return }
            Shell.run("/usr/bin/security",
                      ["add-generic-password", "-U", "-a", account(), "-s", service, "-w", json])
        case .file:
            try? data.write(to: credentialsFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: credentialsFile.path)
        }
    }

    /// A valid access token. When it has expired we refresh it and WRITE IT
    /// BACK to where it came from: the refresh token rotates, so not saving
    /// it would sign the CLI out.
    private static func accessToken() async throws -> (token: String, creds: [String: Any]) {
        var (creds, source) = try readCreds()
        guard var oauth = creds["claudeAiOauth"] as? [String: Any] else {
            throw FetchError(ProviderKey.claude.signedOutMessage, signedOut: true)
        }
        let expiresAt = num(oauth["expiresAt"]) ?? 0
        let token = oauth["accessToken"] as? String ?? ""
        if expiresAt > Date().timeIntervalSince1970 * 1000 + 60_000, !token.isEmpty {
            return (token, creds)
        }
        guard let refresh = oauth["refreshToken"] as? String else {
            throw FetchError(String(localized: "session expired — sign in to Claude Code again"))
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("claude-code/1.0", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token", "refresh_token": refresh, "client_id": clientID,
        ])
        let body: [String: Any]
        do { body = try await URLSession.json(req) }
        catch {
            throw FetchError(String(localized: "token refresh failed (\(error.localizedDescription))"))
        }
        guard let newToken = body["access_token"] as? String else {
            throw FetchError(String(localized: "session expired — sign in to Claude Code again"))
        }
        oauth["accessToken"] = newToken
        if let r = body["refresh_token"] as? String { oauth["refreshToken"] = r }
        oauth["expiresAt"] = Date().timeIntervalSince1970 * 1000 + (num(body["expires_in"]) ?? 0) * 1000
        if let scope = body["scope"] as? String {
            oauth["scopes"] = scope.split(separator: " ").map(String.init)
        }
        creds["claudeAiOauth"] = oauth
        write(creds, to: source)
        return (newToken, creds)
    }

    private static func planLabel(_ creds: [String: Any]) -> String? {
        guard let oauth = creds["claudeAiOauth"] as? [String: Any] else { return nil }
        let tier = (oauth["rateLimitTier"] as? String ?? "").lowercased()
        let sub = (oauth["subscriptionType"] as? String ?? "").lowercased()
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        if sub.contains("max") { return "Max" }
        if sub.contains("pro") { return "Pro" }
        return sub.isEmpty ? nil : sub.capitalized
    }

    static func fetch() async -> ProviderUsage {
        var usage = ProviderUsage(key: ProviderKey.claude.rawValue,
                                  name: ProviderKey.claude.displayName,
                                  plan: nil, buckets: [], error: nil, fetchedAt: Date())
        do {
            let (token, creds) = try await accessToken()
            usage.plan = planLabel(creds)
            var req = URLRequest(url: usageURL)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let body = try await URLSession.json(req)

            func bucket(_ key: String, _ id: String, _ label: String, _ short: String) -> UsageBucket? {
                guard let w = body[key] as? [String: Any], let util = num(w["utilization"]) else { return nil }
                return UsageBucket(id: id, label: label, usedPercent: util, resetsAt: iso(w["resets_at"]),
                                   note: nil, shortLabel: short)
            }
            let week = windowShortLabel(days: 7)
            usage.buckets = [
                bucket("five_hour", "claude-5h", windowLabel(hours: 5), windowShortLabel(hours: 5)),
                bucket("seven_day", "claude-week", windowLabel(days: 7), week),
                bucket("seven_day_opus", "claude-week-opus", "\(week) · Opus", "Opus"),
            ].compactMap { $0 }

            // Limits scoped to a model or surface only show up in the limits[]
            // array, not in the top-level seven_day_* fields.
            if let limits = body["limits"] as? [[String: Any]] {
                for lim in limits {
                    guard let scope = lim["scope"] as? [String: Any], let pct = num(lim["percent"]) else { continue }
                    var scopeName: String?
                    if let m = scope["model"] as? [String: Any], let dn = m["display_name"] as? String {
                        scopeName = dn
                    } else if let sf = scope["surface"] as? [String: Any], let dn = sf["display_name"] as? String {
                        scopeName = dn
                    }
                    guard let name = scopeName else { continue }
                    let prefix = (lim["group"] as? String) == "session" ? windowShortLabel(hours: 5) : week
                    let label = "\(prefix) · \(name)"
                    // Skip if a named field (e.g. seven_day_opus) already added it.
                    if usage.buckets.contains(where: { $0.label == label }) { continue }
                    usage.buckets.append(UsageBucket(id: "claude-scope-\(name.lowercased())",
                                                     label: label, usedPercent: pct,
                                                     resetsAt: iso(lim["resets_at"]), note: nil,
                                                     shortLabel: name))
                }
            }

            if let extra = body["extra_usage"] as? [String: Any],
               (extra["is_enabled"] as? Bool) == true, let util = num(extra["utilization"]) {
                let used = num(extra["used_credits"]) ?? 0
                let limit = num(extra["monthly_limit"]).map { $0 / 100 } ?? 0
                let usd = FloatingPointFormatStyle<Double>.Currency(code: "USD")
                usage.buckets.append(UsageBucket(id: "claude-credit", label: String(localized: "Extra credit"),
                                                 usedPercent: util, resetsAt: nil,
                                                 note: "\(used.formatted(usd)) / \(limit.formatted(usd.precision(.fractionLength(0))))"))
            }
            if usage.buckets.isEmpty { usage.error = String(localized: "no limits in the response") }
        } catch {
            setFailure(&usage, error)
        }
        return usage
    }
}

// MARK: - Codex (ChatGPT)

enum CodexProvider {
    static let authFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/auth.json")
    /// Codex CLI's public OAuth client id (same for every install).
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private static func jwtExpiry(_ token: String) -> Date? {
        num(jwtPayload(token)?["exp"]).map { Date(timeIntervalSince1970: $0) }
    }

    private static func authClaims(_ idToken: String) -> [String: Any]? {
        jwtPayload(idToken)?["https://api.openai.com/auth"] as? [String: Any]
    }

    private static func accountID(idToken: String) -> String? {
        authClaims(idToken)?["chatgpt_account_id"] as? String
    }

    private static func planLabel(idToken: String) -> String? {
        (authClaims(idToken)?["chatgpt_plan_type"] as? String)?.capitalized
    }

    /// Tokens from ~/.codex/auth.json. Expired ones are refreshed and written
    /// back to the same file (the refresh token rotates, like Claude's).
    private static func tokens() async throws -> (access: String, account: String, id: String) {
        guard FileManager.default.fileExists(atPath: authFile.path) else {
            throw FetchError(ProviderKey.codex.signedOutMessage, signedOut: true)
        }
        guard let data = try? Data(contentsOf: authFile),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var toks = root["tokens"] as? [String: Any],
              let access = toks["access_token"] as? String else {
            // An API-key-only login has no ChatGPT tokens and no usage windows.
            throw FetchError(ProviderKey.codex.signedOutMessage, signedOut: true)
        }
        let idToken = toks["id_token"] as? String ?? ""
        let account = (toks["account_id"] as? String) ?? accountID(idToken: idToken) ?? ""
        let exp = jwtExpiry(access) ?? .distantPast
        if exp.timeIntervalSinceNow > 300 {
            return (access, account, idToken)
        }
        guard let refresh = toks["refresh_token"] as? String else {
            throw FetchError(String(localized: "session expired — run `codex login` again"))
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": clientID, "grant_type": "refresh_token",
            "refresh_token": refresh, "scope": "openid profile email",
        ])
        let body = try await URLSession.json(req)
        guard let newAccess = body["access_token"] as? String else {
            throw FetchError(String(localized: "session expired — run `codex login` again"))
        }
        let newID = body["id_token"] as? String ?? idToken
        toks["access_token"] = newAccess
        toks["id_token"] = newID
        if let r = body["refresh_token"] as? String { toks["refresh_token"] = r }
        let acct = accountID(idToken: newID) ?? account
        toks["account_id"] = acct
        root["tokens"] = toks
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = f.string(from: Date())
        if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
            try? out.write(to: authFile, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: authFile.path)
        }
        return (newAccess, acct, newID)
    }

    static func fetch() async -> ProviderUsage {
        var usage = ProviderUsage(key: ProviderKey.codex.rawValue,
                                  name: ProviderKey.codex.displayName,
                                  plan: nil, buckets: [], error: nil, fetchedAt: Date())
        do {
            let (access, account, idToken) = try await tokens()
            usage.plan = planLabel(idToken: idToken)
            var req = URLRequest(url: usageURL)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            req.setValue(account, forHTTPHeaderField: "chatgpt-account-id")
            req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
            let body = try await URLSession.json(req)
            if let plan = body["plan_type"] as? String { usage.plan = plan.capitalized }
            guard let rl = body["rate_limit"] as? [String: Any] else {
                throw FetchError(String(localized: "no limits in the response"))
            }
            func window(_ key: String, _ id: String) -> UsageBucket? {
                guard let w = rl[key] as? [String: Any], let pct = num(w["used_percent"]) else { return nil }
                let seconds = num(w["limit_window_seconds"]) ?? 0
                let label: String, short: String
                switch seconds {
                case 0:
                    label = String(localized: "Window"); short = label
                case ..<86_400:
                    let hours = Int((seconds / 3600).rounded())
                    label = windowLabel(hours: hours); short = windowShortLabel(hours: hours)
                default:
                    let days = Int((seconds / 86_400).rounded())
                    label = windowLabel(days: days); short = windowShortLabel(days: days)
                }
                let reset = num(w["reset_at"]).map { Date(timeIntervalSince1970: $0) }
                return UsageBucket(id: id, label: label, usedPercent: pct, resetsAt: reset,
                                   note: nil, shortLabel: short)
            }
            usage.buckets = [window("primary_window", "codex-primary"),
                             window("secondary_window", "codex-secondary")].compactMap { $0 }
            if let credits = body["credits"] as? [String: Any],
               (credits["has_credits"] as? Bool) == true,
               let balance = credits["balance"] as? String {
                usage.buckets.append(UsageBucket(id: "codex-credit", label: String(localized: "Credit"),
                                                 usedPercent: 0, resetsAt: nil, note: balance))
            }
            if usage.buckets.isEmpty { usage.error = String(localized: "no limits in the response") }
        } catch {
            setFailure(&usage, error)
        }
        return usage
    }
}

enum UsageFetcher {
    static func fetchAll() async -> UsageSnapshot {
        async let claude = ClaudeProvider.fetch()
        async let codex = CodexProvider.fetch()
        let results = await [claude, codex]
        var byKey: [String: ProviderUsage] = [:]
        for r in results { byKey[r.key] = r }
        return UsageSnapshot(updatedAt: Date(), providers: byKey)
    }
}
