import AppKit
import EventKit
import WidgetKit

enum CalendarCollector {
    /// Range covered by the grid: 7 days before this month's start (the previous
    /// month's days in the first week) to 45 days after its end (next month at
    /// the turn of the month).
    static func range(now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        let from = calendar.date(byAdding: .day, value: -7, to: monthStart) ?? monthStart
        let monthEnd = calendar.dateInterval(of: .month, for: now)?.end ?? now
        let to = calendar.date(byAdding: .day, value: 45, to: monthEnd) ?? monthEnd
        return DateInterval(start: from, end: to)
    }

    static func access() -> CalendarSnapshot.Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        // writeOnly can't read events; for the card that's the same as denied.
        default: return .denied
        }
    }

    static func collect(store: EKEventStore, now: Date = Date()) -> CalendarSnapshot {
        let access = access()
        guard access == .granted else {
            return CalendarSnapshot(updatedAt: now, access: access, dayCounts: [:],
                                    dayColors: [:], upcoming: [], error: nil)
        }
        let calendar = Calendar.current
        let interval = range(now: now, calendar: calendar)
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        // Recurring events arrive already expanded into single occurrences.
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        var counts: [String: Int] = [:]
        var colors: [String: [String]] = [:]
        for event in events {
            guard let start = event.startDate, let end = event.endDate else { continue }
            let hex = hexColor(event.calendar?.cgColor)
            // A multi-day event marks every day it covers. An end at midnight
            // excludes that day (exclusive bound); all-day events end at
            // 23:59:59, so their last day is included.
            var day = calendar.startOfDay(for: start)
            let last = max(end, start.addingTimeInterval(1))
            while day < last && day < interval.end {
                let key = CalendarSnapshot.dayKey(day, calendar: calendar)
                counts[key, default: 0] += 1
                if colors[key, default: []].count < 3, !colors[key, default: []].contains(hex) {
                    colors[key, default: []].append(hex)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }

        // The same public holiday coming from two calendars (e.g. a holiday
        // calendar + iCloud) showed up twice in the list (measured): same
        // title + same start collapse into one row. Grid counts are unaffected.
        var seen = Set<String>()
        let upcoming = events
            .filter { ($0.endDate ?? .distantPast) > now }
            .filter { seen.insert("\($0.title ?? "")|\($0.startDate.timeIntervalSince1970)").inserted }
            .prefix(8)
            .map { event in
                CalendarSnapshot.Event(
                    title: (event.title?.isEmpty == false ? event.title! : String(localized: "Untitled event")),
                    start: event.startDate, end: event.endDate, allDay: event.isAllDay,
                    colorHex: hexColor(event.calendar?.cgColor),
                    calendarName: event.calendar?.title ?? "",
                    location: event.location?.isEmpty == false ? event.location : nil,
                    eventID: event.eventIdentifier)
            }

        return CalendarSnapshot(updatedAt: now, access: .granted, dayCounts: counts,
                                dayColors: colors, upcoming: Array(upcoming), error: nil)
    }

    private static func hexColor(_ cgColor: CGColor?) -> String {
        guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB) else {
            return "#E85B5B"
        }
        let r = Int((color.redComponent * 255).rounded())
        let g = Int((color.greenComponent * 255).rounded())
        let b = Int((color.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

@MainActor
final class CalendarAgent {
    private let store = EKEventStore()
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .refreshAllWidgets, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        // EventKit posts this when events are added or removed (iCloud sync
        // included), so the card updates without waiting 15 minutes.
        observers.append(center.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        // At day change the "today" circle and the upcoming list must move.
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task { @MainActor in await self.requestAccessIfNeeded() }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Only the app can show the access prompt (first launch); the widget can't.
    private func requestAccessIfNeeded() async {
        if CalendarCollector.access() == .notDetermined {
            _ = try? await store.requestFullAccessToEvents()
        }
        refresh()
    }

    private func refresh() {
        let snapshot = CalendarCollector.collect(store: store)
        _ = CalendarStore.save(snapshot, mirrorToWidgetContainer: true)
        WidgetCenter.shared.reloadTimelines(ofKind: "CalendarWidget")
    }
}

/// Opens a tap from the card in Calendar.
enum CalendarOpener {
    @MainActor
    static func open(_ url: URL) {
        guard let (day, eventID) = CalendarLink.parse(url) else { return }
        // The event URL selects the event and opens its info popover, but
        // doesn't bring the window forward or go to the day; AppleScript does.
        if let eventID, let encoded = eventID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
           let eventURL = URL(string: "ical://ekevent/\(encoded)?method=show&options=more") {
            NSWorkspace.shared.open(eventURL)
        }
        let parts = (day ?? "").split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            return
        }
        // Date components are set numerically, so this works in any locale.
        // Day goes to 1 first: on the 31st, "month = 2" would overflow into March.
        let script = """
        set d to current date
        set day of d to 1
        set year of d to \(parts[0])
        set month of d to \(parts[1])
        set day of d to \(parts[2])
        tell application "Calendar"
            reopen
            activate
            switch view to day view
            view calendar at d
        end tell
        """
        // Let the event URL select first, then switch to the day view.
        DispatchQueue.main.asyncAfter(deadline: .now() + (eventID == nil ? 0 : 0.4)) {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
            if error != nil {
                // Automation permission denied: at least open Calendar.
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
            }
        }
    }
}
