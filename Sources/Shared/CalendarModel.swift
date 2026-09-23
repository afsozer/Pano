import Foundation

/// Summary of Apple Calendar events. The widget extension CANNOT use EventKit
/// directly: only the app can show the access prompt, the sandboxed extension
/// can't trigger a TCC request. The menu bar app reads the events and writes
/// this snapshot into the extension's container; the card just draws the file.
struct CalendarSnapshot: Codable, Hashable {
    enum Access: String, Codable {
        case granted, denied, notDetermined
    }

    struct Event: Codable, Hashable {
        var title: String
        var start: Date
        var end: Date
        var allDay: Bool
        /// The calendar's color, "#RRGGBB".
        var colorHex: String
        var calendarName: String
        var location: String?
        /// EKEvent.eventIdentifier; tapping the row opens this event in
        /// Calendar. Optional because older snapshots don't have it.
        var eventID: String? = nil
    }

    var updatedAt: Date
    var access: Access
    /// "yyyy-MM-dd" (local time) → number of events starting or running that day.
    /// Covers 7 days before this month's start to 45 days after its end, so the
    /// grid isn't empty when the month turns over before the app re-reads.
    var dayCounts: [String: Int]
    /// Day → calendar colors of up to three events that day (the dot colors).
    var dayColors: [String: [String]]
    /// The next events that haven't ended yet, sorted by start.
    var upcoming: [Event]
    var error: String?

    /// The calendar rarely changes, but the app rewrites on every change
    /// notification; an hour of silence means the app isn't running.
    var isStale: Bool { Date().timeIntervalSince(updatedAt) > 60 * 60 }

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    func count(on date: Date) -> Int { dayCounts[Self.dayKey(date)] ?? 0 }
    func colors(on date: Date) -> [String] { dayColors[Self.dayKey(date)] ?? [] }
}

enum CalendarStore {
    static let fileURL = AppPaths.file("calendar.json")

    static let widgetContainerFileURL = AppPaths.widgetContainerFile("calendar.json")

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

    static func load() -> CalendarSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(CalendarSnapshot.self, from: data)
    }

    @discardableResult
    static func save(_ snapshot: CalendarSnapshot, mirrorToWidgetContainer: Bool = false) -> Bool {
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

/// Tap path from the card to Calendar: the card opens
/// `pano://calendar?day=…&event=…`, the system hands it to the menu bar app,
/// and the app opens Calendar at that day (and event, if any). The card can't
/// open Calendar directly: `ical://ekevent/…` selects the event but doesn't
/// bring the window forward, and going to a day needs AppleScript (measured).
enum CalendarLink {
    static let scheme = "pano"

    static func url(day: Date, eventID: String? = nil) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "calendar"
        c.queryItems = [URLQueryItem(name: "day", value: CalendarSnapshot.dayKey(day))]
        if let eventID { c.queryItems?.append(URLQueryItem(name: "event", value: eventID)) }
        return c.url!
    }

    /// (day "yyyy-MM-dd", event id) — nil if the URL isn't ours.
    static func parse(_ url: URL) -> (day: String?, eventID: String?)? {
        guard url.scheme == scheme, url.host == "calendar",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        return (items.first { $0.name == "day" }?.value, items.first { $0.name == "event" }?.value)
    }
}
