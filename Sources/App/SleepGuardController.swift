import Foundation
import SwiftUI
import WidgetKit

/// Single root-only commands (pmset disablesleep, AC sleep).
/// First tries `sudo -n` (passes silently if a passwordless sudoers rule
/// exists); otherwise shows a one-time administrator password prompt (the
/// whole root program is passed inline to osascript, nothing on disk) that
/// both installs the rule (only the exact commands in `allowed`) and runs the
/// command. When the allow-list changes, the old rule no longer matches →
/// `sudo -n` fails → the prompt appears once more and the rule is rewritten.
enum RootCommand {
    static let sudoersPath = "/etc/sudoers.d/pano"

    /// Exact argument lists; each becomes one command in the sudoers rule.
    /// Nothing else (no wildcards) is allowed.
    static var allowed: [[String]] {
        let restore = String(PanoConfig.current.sleepGuard.acSleepRestoreMinutes)
        var list: [[String]] = [
            ["/usr/bin/pmset", "-a", "disablesleep", "0"],
            ["/usr/bin/pmset", "-a", "disablesleep", "1"],
            // AC profile only: `-c` = charger, the battery profile is untouched.
            ["/usr/bin/pmset", "-c", "sleep", "0"],
        ]
        list.append(["/usr/bin/pmset", "-c", "sleep", restore])
        return list
    }

    /// sudoers accepts plain user names; anything unusual is refused rather
    /// than escaped.
    static func isSafeUserName(_ user: String) -> Bool {
        !user.isEmpty && user.range(of: #"^[A-Za-z0-9_][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }

    /// The single sudoers line, e.g.
    /// `alice ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, …`.
    static func sudoersRule(user: String = NSUserName(), commands: [[String]] = allowed) -> String {
        "\(user) ALL=(root) NOPASSWD: " + commands.map { $0.joined(separator: " ") }.joined(separator: ", ")
    }

    /// Shell snippet that installs the rule by hand (for the README). With
    /// `user == nil` it uses `$(whoami)`, so it works for any account.
    /// Validates with `visudo -cf` before anything lands in /etc/sudoers.d.
    static func manualInstallCommand(user: String? = nil, commands: [[String]] = allowed) -> String {
        let rule = sudoersRule(user: user ?? "$(whoami)", commands: commands)
        return """
        printf '%s\\n' "\(rule)" > /tmp/pano.sudoers \\
          && sudo visudo -cf /tmp/pano.sudoers \\
          && sudo install -m 0440 -o root -g wheel /tmp/pano.sudoers \(sudoersPath); rm -f /tmp/pano.sudoers
        """
    }

    /// Returns an error message or nil.
    static func run(_ command: [String], prompt: String) -> String? {
        let allowed = allowed
        guard allowed.contains(command) else { return String(localized: "command not allowed") }
        let quiet = Shell.runCapturing("/usr/bin/sudo", ["-n"] + command)
        if quiet.status == 0 { return nil }
        return runWithPrompt(command, allowed: allowed, prompt: prompt)
    }

    /// POSIX single-quoting: the result is always one literal shell word.
    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// AppleScript string-literal escaping (backslash and double quote).
    static func appleScriptQuoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// One-line shell program run as root. Nothing is read from a
    /// user-writable location: root creates the temp file itself with mktemp
    /// inside /etc/sudoers.d (root-owned; sudo ignores names containing a
    /// dot), writes the single-quoted rule, validates it with visudo and only
    /// then moves it into place. Then it runs the requested command.
    static func rootShellCommand(command: [String], user: String, allowed: [[String]]) -> String {
        let rule = shellQuoted(sudoersRule(user: user, commands: allowed))
        return [
            "set -e",
            "t=$(/usr/bin/mktemp /etc/sudoers.d/.pano.XXXXXX)",
            "trap '/bin/rm -f \"$t\"' EXIT",
            "/usr/bin/printf '%s\\n' \(rule) > \"$t\"",
            "/bin/chmod 0440 \"$t\"",
            "/usr/sbin/chown root:wheel \"$t\"",
            "if /usr/sbin/visudo -cf \"$t\" >/dev/null; then /bin/mv -f \"$t\" \(shellQuoted(sudoersPath)); fi",
            command.map(shellQuoted).joined(separator: " "),
        ].joined(separator: "; ")
    }

    /// Complete AppleScript source handed to osascript as an argument (no
    /// shell in between, no file on disk).
    static func appleScriptSource(command: [String], user: String, allowed: [[String]], prompt: String) -> String {
        let shell = rootShellCommand(command: command, user: user, allowed: allowed)
        return "do shell script \"\(appleScriptQuoted(shell))\" with administrator privileges with prompt \"\(appleScriptQuoted(prompt))\""
    }

    private static func runWithPrompt(_ command: [String], allowed: [[String]], prompt: String) -> String? {
        let user = NSUserName()
        guard isSafeUserName(user) else { return String(localized: "unsupported user name for sudoers") }
        // Older builds ran a script from here; make sure it's gone.
        try? FileManager.default.removeItem(at: SleepGuardStore.fileURL.deletingLastPathComponent()
            .appendingPathComponent("root-command.sh"))
        let apple = appleScriptSource(command: command, user: user, allowed: allowed, prompt: prompt)
        let result = Shell.runCapturing("/usr/bin/osascript", ["-e", apple])
        if result.status == 0 { return nil }
        let err = (result.err ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if err.contains("-128") { return String(localized: "cancelled") }
        return err.isEmpty ? String(localized: "admin permission denied") : err
    }
}

extension Shell {
    struct Result { var status: Int32; var out: String?; var err: String? }

    /// Unlike `run` in Providers, this also returns stderr (where osascript
    /// reports errors).
    static func runCapturing(_ path: String, _ args: [String]) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return Result(status: -1, out: nil, err: error.localizedDescription) }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        p.waitUntilExit()
        return Result(status: p.terminationStatus, out: out, err: err)
    }
}

/// Reads and writes the pmset settings behind the two sleep guards.
enum SleepGuardController {
    struct PowerInfo {
        var source: String?
        var batteryPercent: Int?
    }

    static func readEnabled() -> Bool? {
        let out = Shell.run("/usr/bin/pmset", ["-g"]).out
        for line in out.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.trimmingCharacters(in: .whitespaces).hasSuffix("1")
        }
        return false
    }

    /// Extracts `sleep N` from the AC profile in `pmset -g custom` output;
    /// returns "is idle sleep disabled" (N == 0). A pure function so tests
    /// can feed it real output.
    ///
    /// Three traps (measured on real output): section order isn't fixed —
    /// `Battery Power:` may come before `AC Power:`; the `displaysleep`,
    /// `disksleep` and `Sleep On Power Button` lines also contain "sleep", so
    /// the first word must be EXACTLY "sleep"; the value sometimes has a
    /// trailing note, so only the first number is taken.
    static func parseACIdleAwake(_ output: String) -> Bool? {
        var inAC = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("AC Power") { inAC = true; continue }
            if line.hasPrefix("Battery Power") { inAC = false; continue }
            guard inAC else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[0] == "sleep", let value = Int(parts[1]) else { continue }
            return value == 0
        }
        return nil
    }

    static func readACIdleAwake() -> Bool? {
        parseACIdleAwake(Shell.run("/usr/bin/pmset", ["-g", "custom"]).out)
    }

    /// `pmset -g batt`: "Now drawing from 'Battery Power'" + "51%; discharging".
    static func readPower() -> PowerInfo {
        var info = PowerInfo()
        let out = Shell.run("/usr/bin/pmset", ["-g", "batt"]).out
        if out.contains("'AC Power'") { info.source = "AC" }
        else if out.contains("'Battery Power'") { info.source = "Battery" }
        if let range = out.range(of: #"(\d{1,3})%"#, options: .regularExpression) {
            info.batteryPercent = Int(out[range].dropLast())
        }
        return info
    }

    /// Returns an error message or nil.
    static func apply(enabled: Bool) -> String? {
        RootCommand.run(["/usr/bin/pmset", "-a", "disablesleep", enabled ? "1" : "0"],
                        prompt: String(localized: "Pano needs your administrator password once to control sleep with the lid closed."))
    }

    /// Turning it off restores `sleepGuard.acSleepRestoreMinutes` from the
    /// config (default 1, macOS's usual AC value on laptops).
    static func applyACIdleAwake(_ enabled: Bool) -> String? {
        let restore = String(PanoConfig.current.sleepGuard.acSleepRestoreMinutes)
        return RootCommand.run(["/usr/bin/pmset", "-c", "sleep", enabled ? "0" : restore],
                               prompt: String(localized: "Pano needs your administrator password once to control idle sleep on AC power."))
    }
}

/// Menu bar agent: reads the state every minute, writes the widget file, and
/// applies on/off requests from the widget.
@MainActor
final class SleepGuardAgent: ObservableObject {
    @Published var snapshot: SleepGuardSnapshot = SleepGuardStore.load() ?? .empty
    @Published var busy = false

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .refreshAllWidgets, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .sleepGuardRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let enable = note.userInfo?["enable"] as? Bool else { return }
            Task { @MainActor in await self?.set(enabled: enable) }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .sleepGuardACIdleRequested, object: nil, queue: .main
        ) { [weak self] note in
            guard let enable = note.userInfo?["enable"] as? Bool else { return }
            Task { @MainActor in await self?.set(acIdleAwake: enable) }
        })
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func refresh() {
        // pmset takes a few ms; fine on the main thread, but keeping
        // Process + Pipe in the background is cleaner.
        Task.detached(priority: .utility) {
            let enabled = SleepGuardController.readEnabled()
            let acIdleAwake = SleepGuardController.readACIdleAwake()
            let power = SleepGuardController.readPower()
            await MainActor.run {
                var s = self.snapshot
                s.updatedAt = Date()
                if let enabled { s.enabled = enabled; s.error = nil } else { s.error = String(localized: "couldn't read pmset") }
                // If the AC value can't be read keep the old one; don't
                // overwrite a disablesleep error (the card has one error line).
                if let acIdleAwake { s.acIdleAwake = acIdleAwake }
                else if s.error == nil { s.error = String(localized: "couldn't read pmset -g custom") }
                s.powerSource = power.source
                s.batteryPercent = power.batteryPercent
                // Clear the pending flag once the applied value matches the request.
                if let pending = s.pendingEnabled, pending == s.enabled || s.activePending == nil {
                    s.pendingEnabled = nil; s.pendingSince = nil
                }
                if let pending = s.pendingACIdleAwake,
                   pending == s.acIdleAwake || s.activeACIdlePending == nil {
                    s.pendingACIdleAwake = nil; s.pendingACIdleSince = nil
                }
                self.publish(s)
            }
        }
    }

    func set(enabled: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let error = await Task.detached(priority: .userInitiated) {
            SleepGuardController.apply(enabled: enabled)
        }.value
        var s = snapshot
        s.pendingEnabled = nil
        s.pendingSince = nil
        s.error = error
        s.updatedAt = Date()
        if error == nil { s.enabled = enabled }
        publish(s)
        refresh()
    }

    /// The AC profile switch. Shares the `busy` lock so two admin prompts
    /// can never be open at once.
    func set(acIdleAwake: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let error = await Task.detached(priority: .userInitiated) {
            SleepGuardController.applyACIdleAwake(acIdleAwake)
        }.value
        var s = snapshot
        s.pendingACIdleAwake = nil
        s.pendingACIdleSince = nil
        s.error = error
        s.updatedAt = Date()
        if error == nil { s.acIdleAwake = acIdleAwake }
        publish(s)
        refresh()
    }

    private func publish(_ s: SleepGuardSnapshot) {
        snapshot = s
        SleepGuardStore.save(s, mirrorToWidgetContainer: true)
        WidgetCenter.shared.reloadTimelines(ofKind: "SleepGuardWidget")
    }
}

extension Notification.Name {
    static let sleepGuardRequested = Notification.Name("Pano.sleepGuardRequested")
    static let sleepGuardACIdleRequested = Notification.Name("Pano.sleepGuardACIdleRequested")
}
