import Foundation
import WidgetKit

enum StorageCollector {
    /// Capacity of the boot volume ("/") via URLResourceValues:
    /// `volumeAvailableCapacityForImportantUsage` is the "available" figure
    /// Finder shows (purgeable included), `volumeAvailableCapacity` is the
    /// truly free space. The difference is purgeable space.
    static func collect() -> StorageSnapshot? {
        let url = URL(fileURLWithPath: "/")
        let keys: Set<URLResourceKey> = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey,
            .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity, total > 0 else { return nil }

        let free = Int64(max(0, values.volumeAvailableCapacity ?? 0))
        // Fall back to free space if the "important usage" value is missing;
        // never let available < free (purgeable would go negative).
        let available = max(free, values.volumeAvailableCapacityForImportantUsage ?? free)

        return StorageSnapshot(
            updatedAt: Date(),
            volumeName: values.volumeName ?? "Macintosh HD",
            format: values.volumeLocalizedFormatDescription,
            totalBytes: UInt64(total),
            availableBytes: UInt64(available),
            freeBytes: UInt64(free)
        )
    }
}

@MainActor
final class StorageAgent {
    private var timer: Timer?
    private var refreshObserver: NSObjectProtocol?

    init() {
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .refreshAllWidgets, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        // Disk usage doesn't move within minutes: the system agent's 60 s pace
        // would just mean pointless widget reloads here.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit {
        if let refreshObserver { NotificationCenter.default.removeObserver(refreshObserver) }
    }

    private func refresh() {
        guard let snapshot = StorageCollector.collect() else { return }
        _ = StorageStore.save(snapshot, mirrorToWidgetContainer: true)
        WidgetCenter.shared.reloadTimelines(ofKind: "StorageWidget")
    }
}
