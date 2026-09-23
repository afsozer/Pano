import Foundation

/// Where snapshots live. The app writes to its own Application Support folder
/// and mirrors each file into the widget extension's sandbox container, because
/// an App Group would need a provisioning profile (ad-hoc signing can't do it).
/// Inside the sandboxed extension `~` already resolves to that container, so
/// the same `file(_:)` path works on both sides.
enum AppPaths {
    static let widgetBundleID = "dev.pano.app.widgets"

    static func file(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Pano/\(name)")
    }

    static func widgetContainerFile(_ name: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support/Pano/\(name)")
    }
}
