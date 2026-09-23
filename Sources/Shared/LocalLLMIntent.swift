import AppIntents
import CoreFoundation
import Foundation
import WidgetKit

/// Widget → app: start/stop the local LLM service or warm up a model. The
/// extension is sandboxed and can neither run `brew` nor make HTTP requests.
/// Same Darwin-notification channel as the sleep guard, three names.
enum LocalLLMRequest {
    static let startName = CFNotificationName("dev.pano.app.localllm.start" as CFString)
    static let stopName = CFNotificationName("dev.pano.app.localllm.stop" as CFString)
    static let warmName = CFNotificationName("dev.pano.app.localllm.warm" as CFString)

    static func name(for action: String) -> CFNotificationName? {
        switch action {
        case "start": return startName
        case "stop": return stopName
        case "warm": return warmName
        default: return nil
        }
    }

    static func post(action: String) {
        guard let name = name(for: action) else { return }
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }
}

struct LocalLLMActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Local LLM action"
    static let description = IntentDescription(LocalizedStringResource("Starts or stops the oMLX server, or loads the selected model into memory."))
    static let openAppWhenRun = false

    /// "start" | "stop" | "warm" | "select" (next model)
    @Parameter(title: "Action")
    var action: String

    init() {}
    init(action: String) { self.action = action }

    func perform() async throws -> some IntentResult {
        if action == "select" {
            // Purely local: advance to the next alias and persist the choice.
            // The app picks it up from the container on its next poll, so no
            // notification is needed.
            var snapshot = LocalLLMStore.load() ?? .empty
            if let next = snapshot.nextModel {
                snapshot.selectedModel = next
                LocalLLMSelectionStore.save(next)
                LocalLLMStore.save(snapshot)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: "LocalLLMWidget")
            return .result()
        }
        // Inside the extension `~` resolves to its container: write the
        // pending request over the app's mirrored file so the card flips to
        // "changing…" immediately; the app overwrites it once applied.
        var snapshot = LocalLLMStore.load() ?? .empty
        snapshot.pendingAction = action
        snapshot.pendingSince = Date()
        LocalLLMStore.save(snapshot)
        LocalLLMRequest.post(action: action)
        WidgetCenter.shared.reloadTimelines(ofKind: "LocalLLMWidget")
        return .result()
    }
}
