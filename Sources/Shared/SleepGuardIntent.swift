import AppIntents
import CoreFoundation
import Foundation
import WidgetKit

/// Widget → app: "turn the sleep guard on/off". The extension is sandboxed
/// and can't run pmset; it uses the same Darwin-notification channel as
/// RefreshRequest.
enum SleepGuardRequest {
    static let enableName = CFNotificationName("dev.pano.app.sleepguard.enable" as CFString)
    static let disableName = CFNotificationName("dev.pano.app.sleepguard.disable" as CFString)

    static func post(enable: Bool) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            enable ? enableName : disableName,
            nil,
            nil,
            true
        )
    }
}

/// Widget → app: "don't idle-sleep while on AC". A separate notification
/// pair: the two switches share one lock in the app but their requests must
/// not mix.
enum SleepGuardACIdleRequest {
    static let enableName = CFNotificationName("dev.pano.app.sleepguard.acidle.enable" as CFString)
    static let disableName = CFNotificationName("dev.pano.app.sleepguard.acidle.disable" as CFString)

    static func post(enable: Bool) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            enable ? enableName : disableName,
            nil,
            nil,
            true
        )
    }
}

struct SetSleepGuardIntent: AppIntent {
    static let title: LocalizedStringResource = "Set sleep guard"
    static let description = IntentDescription(LocalizedStringResource("Keeps the Mac awake with the lid closed, or lets it sleep again."))
    static let openAppWhenRun = false

    @Parameter(title: "On")
    var enable: Bool

    init() {}
    init(enable: Bool) { self.enable = enable }

    func perform() async throws -> some IntentResult {
        // Inside the extension `~` resolves to its container: write the
        // pending request over the app's mirrored file so the card flips to
        // "changing…" immediately; the app overwrites it once applied.
        var snapshot = SleepGuardStore.load() ?? .empty
        snapshot.pendingEnabled = enable
        snapshot.pendingSince = Date()
        SleepGuardStore.save(snapshot)
        SleepGuardRequest.post(enable: enable)
        WidgetCenter.shared.reloadTimelines(ofKind: "SleepGuardWidget")
        return .result()
    }
}

struct SetSleepGuardACIdleIntent: AppIntent {
    static let title: LocalizedStringResource = "Set idle sleep on AC"
    static let description = IntentDescription(LocalizedStringResource("Turns idle system sleep off or on while on AC power (pmset -c sleep). The display still sleeps; the battery profile is unchanged."))
    static let openAppWhenRun = false

    @Parameter(title: "On")
    var enable: Bool

    init() {}
    init(enable: Bool) { self.enable = enable }

    func perform() async throws -> some IntentResult {
        var snapshot = SleepGuardStore.load() ?? .empty
        snapshot.pendingACIdleAwake = enable
        snapshot.pendingACIdleSince = Date()
        SleepGuardStore.save(snapshot)
        SleepGuardACIdleRequest.post(enable: enable)
        WidgetCenter.shared.reloadTimelines(ofKind: "SleepGuardWidget")
        return .result()
    }
}
