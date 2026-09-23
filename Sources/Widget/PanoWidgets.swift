import WidgetKit
import SwiftUI

@main
struct PanoWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeUsageWidget()
        CodexUsageWidget()
        SystemMetricsWidget()
        StorageWidget()
        SleepGuardWidget()
        LocalLLMWidget()
        NanoGPTWidget()
        CalendarWidget()
    }
}
