import Foundation

/// Boot disk usage, in Finder's terms: "available" includes purgeable space
/// (which the system reclaims on demand), used = total - available. `df` does
/// NOT answer this correctly: because the system volume is separate, `df /`
/// showed 12 GB while real usage in the APFS container was ~396 GB (measured).
struct StorageSnapshot: Codable, Hashable {
    var updatedAt: Date
    var volumeName: String
    /// E.g. "APFS"; nil if unreadable.
    var format: String?
    var totalBytes: UInt64
    /// The available space Finder shows: truly free + purgeable.
    var availableBytes: UInt64
    /// Truly free space, NOT counting purgeable.
    var freeBytes: UInt64

    var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    var purgeableBytes: UInt64 { availableBytes > freeBytes ? availableBytes - freeBytes : 0 }

    /// The three parts add up to the whole disk: used + purgeable + free.
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(usedBytes) / Double(totalBytes) * 100)
    }

    var purgeablePercent: Double {
        guard totalBytes > 0 else { return 0 }
        return min(100, Double(purgeableBytes) / Double(totalBytes) * 100)
    }

    /// Disk usage barely changes within hours; the system card's 15-minute
    /// threshold would flag it as stale for no reason.
    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 60 * 60 }
}

enum StorageStore {
    static let fileURL = AppPaths.file("storage.json")

    static let widgetContainerFileURL = AppPaths.widgetContainerFile("storage.json")

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

    static func load() -> StorageSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(StorageSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: StorageSnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
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
