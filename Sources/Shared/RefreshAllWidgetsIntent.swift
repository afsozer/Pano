import AppIntents
import CoreFoundation

enum RefreshRequest {
    static let darwinName = CFNotificationName("dev.pano.app.refresh-all" as CFString)

    static func post() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            darwinName,
            nil,
            nil,
            true
        )
    }
}

/// Runs in the widget extension and posts a cross-process (Darwin) notification
/// asking the running menu bar app to refresh every data source.
/// `openAppWhenRun` is deliberately off: with ad-hoc signing it needs a team ID.
struct RefreshAllWidgetsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh all widgets"
    static let description = IntentDescription("Refreshes quota, system and storage data together.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        RefreshRequest.post()
        return .result()
    }
}
