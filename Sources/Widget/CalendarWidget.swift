import WidgetKit
import SwiftUI

// MARK: - Calendar widget
//
// Draws Apple Calendar events in the family's style: the small card is a month
// grid (a dot in the calendar's color under days with events, today as a filled
// coral circle); the medium card adds upcoming events next to the grid.
// Data comes from the menu bar app's EventKit read (CalendarAgent): the
// extension is sandboxed, can't ask for access and can't read the store itself.

private let calendarAccent = Color(red: 0.96, green: 0.38, blue: 0.40)

/// The user's calendar: first weekday, weekend and symbols all follow the
/// system's region settings.
private var gridCalendar: Calendar { Calendar.autoupdatingCurrent }

/// One-letter weekday symbols rotated to start at the calendar's first weekday.
private func weekdaySymbols(_ cal: Calendar) -> [String] {
    let symbols = cal.veryShortStandaloneWeekdaySymbols   // Sunday first
    return (0..<7).map { symbols[(cal.firstWeekday - 1 + $0) % 7] }
}

/// "September" → capitalized per locale (some languages write months lowercase).
private func capitalizedFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return String(first).capitalized(with: .current) + text.dropFirst()
}

private func color(hex: String) -> Color {
    let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return calendarAccent }
    return Color(red: Double((value >> 16) & 0xFF) / 255,
                 green: Double((value >> 8) & 0xFF) / 255,
                 blue: Double(value & 0xFF) / 255)
}

/// Standalone month name ("LLLL"), optionally with the year, in the user's locale.
/// `compact`: the small card's header also carries the "today N" chip in
/// ~123 pt, and "September" + chip clipped to "Septem… toda…" (measured).
/// Names longer than six letters fall back to the abbreviation there, so
/// short ones ("Eylül", "June") stay whole.
private func monthTitle(_ date: Date, withYear: Bool = false, compact: Bool = false) -> String {
    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.setLocalizedDateFormatFromTemplate(withYear ? "LLLLy" : "LLLL")
    let full = capitalizedFirst(formatter.string(from: date))
    guard compact, full.count > 6 else { return full }
    formatter.setLocalizedDateFormatFromTemplate("LLL")
    return capitalizedFirst(formatter.string(from: date))
}

struct CalendarEntry: TimelineEntry {
    let date: Date
    let calendar: CalendarSnapshot?
}

struct CalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarEntry {
        CalendarEntry(date: Date(), calendar: Self.sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        completion(CalendarEntry(date: Date(),
                                 calendar: CalendarStore.load() ?? (context.isPreview ? Self.sample : nil)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        let now = Date()
        let snapshot = CalendarStore.load()
        let midnight = gridCalendar.startOfDay(for: now).addingTimeInterval(86_400)
        // The app reloads the card whenever the calendar changes. These
        // entries keep two things right even while the app is closed: ended
        // events drop off the list, and the "today" circle moves at midnight.
        var dates: Set<Date> = [now, midnight]
        for event in snapshot?.upcoming ?? [] where event.end > now && event.end < midnight {
            dates.insert(event.end)
        }
        let entries = dates.sorted().map { CalendarEntry(date: $0, calendar: snapshot) }
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }

    static var sample: CalendarSnapshot {
        let cal = gridCalendar
        let today = cal.startOfDay(for: Date())
        func day(_ offset: Int, _ hour: Int) -> Date {
            cal.date(byAdding: .hour, value: hour, to: cal.date(byAdding: .day, value: offset, to: today)!)!
        }
        let work = String(localized: "Work"), personal = String(localized: "Personal")
        let events = [
            CalendarSnapshot.Event(title: String(localized: "Design review"), start: day(0, 10), end: day(0, 11),
                                   allDay: false, colorHex: "#63DAF2", calendarName: work),
            CalendarSnapshot.Event(title: String(localized: "Dentist"), start: day(1, 14), end: day(1, 15),
                                   allDay: false, colorHex: "#F2A93B", calendarName: personal),
            CalendarSnapshot.Event(title: String(localized: "Team standup"), start: day(13, 9), end: day(13, 10),
                                   allDay: false, colorHex: "#63DAF2", calendarName: work),
        ]
        var counts: [String: Int] = [:]
        var colors: [String: [String]] = [:]
        for event in events + [CalendarSnapshot.Event(title: "", start: day(-1, 9), end: day(-1, 10),
                                                      allDay: false, colorHex: "#63DAF2", calendarName: "")] {
            let key = CalendarSnapshot.dayKey(event.start)
            counts[key, default: 0] += 1
            colors[key, default: []].append(event.colorHex)
        }
        return CalendarSnapshot(updatedAt: Date(), access: .granted, dayCounts: counts,
                                dayColors: colors, upcoming: events, error: nil)
    }
}

/// Set by the preview tool (Tools/render-preview.sh) to draw links as plain
/// views: ImageRenderer renders a `Link` as a yellow "prohibited" sign (measured).
nonisolated(unsafe) var calendarLinksDisabled = false

/// A tappable area on the card; the tap is routed to the menu bar app.
struct CalendarTap<Content: View>: View {
    let url: URL
    @ViewBuilder let content: Content

    var body: some View {
        if calendarLinksDisabled {
            content
        } else {
            Link(destination: url) { content }
        }
    }
}

// MARK: - Month grid

struct MonthGrid: View {
    let snapshot: CalendarSnapshot?
    let date: Date

    /// Cell size is derived from the available space, not hard-coded: a month
    /// spans 4–6 rows, and with a fixed font a six-row month pushed the header
    /// out of the small card (measured on a November 2026 preview).
    var body: some View {
        let cal = gridCalendar
        let days = monthDays(cal)
        let rows = max(1, days.count / 7)
        let symbols = weekdaySymbols(cal)
        let weekendColumns = weekendColumns(cal)
        GeometryReader { geo in
            let headerHeight: CGFloat = 11
            let rowHeight = (geo.size.height - headerHeight) / CGFloat(rows)
            let colWidth = geo.size.width / 7
            // Today's circle; leaves ~3.5 pt for the event dot underneath.
            let diameter = max(9, min(rowHeight - 3.5, colWidth - 1.5, 19))
            let fontSize = min(11, diameter * 0.66)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { i in
                        Text(verbatim: symbols[i])
                            .font(.system(size: min(9, fontSize - 0.5), weight: .semibold))
                            .foregroundStyle(weekendColumns.contains(i) ? AnyShapeStyle(.tertiary)
                                                                        : AnyShapeStyle(.secondary))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: headerHeight, alignment: .top)
                ForEach(0..<rows, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            let day = days[row * 7 + col]
                            let cellView = cell(day, weekend: weekendColumns.contains(col), cal: cal,
                                                diameter: diameter, fontSize: fontSize)
                                .frame(width: colWidth, height: rowHeight)
                            // Every day opens itself, even without events.
                            if let day {
                                CalendarTap(url: CalendarLink.url(day: day)) { cellView }
                            } else {
                                cellView
                            }
                        }
                    }
                }
            }
        }
    }

    /// Grid columns that fall on the weekend in the user's region.
    private func weekendColumns(_ cal: Calendar) -> Set<Int> {
        guard let weekStart = cal.dateInterval(of: .weekOfYear, for: date)?.start else { return [] }
        return Set((0..<7).filter { i in
            cal.date(byAdding: .day, value: i, to: weekStart).map(cal.isDateInWeekend) ?? false
        })
    }

    /// The month's days aligned to the first weekday; empty cells are nil.
    /// 4–6 rows depending on the month — no fixed six rows like Apple's widget.
    private func monthDays(_ cal: Calendar) -> [Date?] {
        guard let month = cal.dateInterval(of: .month, for: date),
              let count = cal.range(of: .day, in: .month, for: date)?.count else { return [] }
        let offset = (cal.component(.weekday, from: month.start) - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: offset)
        for i in 0..<count { cells.append(cal.date(byAdding: .day, value: i, to: month.start)) }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    @ViewBuilder
    private func cell(_ day: Date?, weekend: Bool, cal: Calendar,
                      diameter: CGFloat, fontSize: CGFloat) -> some View {
        if let day {
            let isToday = cal.isDate(day, inSameDayAs: date)
            let isPast = day < cal.startOfDay(for: date)
            let colors = snapshot?.colors(on: day) ?? []
            let hasEvents = (snapshot?.count(on: day) ?? 0) > 0
            Text(verbatim: cal.component(.day, from: day).formatted())
                .font(.system(size: fontSize, weight: hasEvents || isToday ? .bold : .medium,
                              design: .rounded).monospacedDigit())
                .foregroundStyle(isToday ? AnyShapeStyle(.white)
                                 : hasEvents ? AnyShapeStyle(.primary)
                                 : (weekend || isPast) ? AnyShapeStyle(.tertiary)
                                 : AnyShapeStyle(.secondary))
                .lineLimit(1).fixedSize()
                .frame(width: diameter, height: diameter)
                .background {
                    if isToday {
                        Circle().fill(calendarAccent)
                            .shadow(color: calendarAccent.opacity(0.55), radius: 2.5)
                    }
                }
                .overlay(alignment: .bottom) {
                    HStack(spacing: 1.5) {
                        ForEach(Array(colors.prefix(3).enumerated()), id: \.offset) { _, hex in
                            Circle().fill(color(hex: hex))
                                .frame(width: 3, height: 3)
                                .opacity(isPast ? 0.5 : 1)
                        }
                    }
                    .offset(y: 3.5)
                }
                .offset(y: -1.5)
        } else {
            Color.clear
        }
    }
}

// MARK: - Upcoming event row

struct CalendarEventRow: View {
    let event: CalendarSnapshot.Event
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color(hex: event.colorHex))
                .frame(width: 3)
                .shadow(color: color(hex: event.colorHex).opacity(0.5), radius: 1.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: event.title)
                    .font(.system(size: 11, weight: .semibold))
                    // Inside a Link, uncolored text gets tinted with the accent color.
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: whenText)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(isNow ? AnyShapeStyle(calendarAccent) : AnyShapeStyle(.secondary))
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var isNow: Bool { event.start <= now && event.end > now }

    /// "today · 10:00", "Fri, Oct 2 · all day", "now · until 11:00" — every
    /// part localized; times follow the user's 12/24-hour setting.
    private var whenText: String {
        let cal = gridCalendar
        let dayText: String
        if isNow {
            dayText = String(localized: "now", comment: "An event is in progress")
        } else if cal.isDate(event.start, inSameDayAs: now) {
            dayText = String(localized: "today")
        } else if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
                  cal.isDate(event.start, inSameDayAs: tomorrow) {
            dayText = String(localized: "tomorrow")
        } else {
            let f = DateFormatter()
            f.locale = .current
            f.setLocalizedDateFormatFromTemplate("EEEdMMM")
            dayText = f.string(from: event.start)
        }
        if event.allDay {
            return "\(dayText) · " + String(localized: "all day")
        }
        let time: String
        if isNow {
            let end = event.end.formatted(date: .omitted, time: .shortened)
            time = String(localized: "until \(end)", comment: "Event end time, e.g. until 11:00")
        } else {
            time = event.start.formatted(date: .omitted, time: .shortened)
        }
        return "\(dayText) · \(time)"
    }
}

// MARK: - Cards

private extension CalendarSnapshot {
    var accessMessage: String? {
        switch access {
        case .granted: return error
        case .notDetermined: return String(localized: "Waiting for calendar access — open Pano")
        case .denied:
            return String(localized: "No calendar access — System Settings › Privacy & Security › Calendars › Pano")
        }
    }

    func todayCount(_ now: Date) -> Int {
        upcoming.filter { gridCalendar.isDate($0.start, inSameDayAs: now) && $0.end > now }.count
    }
}

struct SmallCalendarView: View {
    let snapshot: CalendarSnapshot?
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HeaderRow(accent: calendarAccent, title: monthTitle(date, compact: true),
                      chip: todayChip, chipColor: calendarAccent,
                      trailing: snapshot?.access == .granted ? nil : String(localized: "no access"),
                      trailingColor: .orange,
                      stale: snapshot?.isStale == true)
            MonthGrid(snapshot: snapshot, date: date)
        }
    }

    private var todayChip: String? {
        guard let n = snapshot?.todayCount(date), n > 0 else { return nil }
        let count = n.formatted()
        return String(localized: "today \(count)", comment: "Chip: number of events today")
    }
}

struct MediumCalendarView: View {
    let snapshot: CalendarSnapshot?
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HeaderRow(accent: calendarAccent, title: monthTitle(date, withYear: true),
                      chip: todayChip, chipColor: calendarAccent,
                      trailing: snapshot.map { $0.updatedAt.formatted(date: .omitted, time: .shortened) },
                      stale: snapshot?.isStale == true)
            HStack(alignment: .top, spacing: 10) {
                MonthGrid(snapshot: snapshot, date: date)
                    .frame(width: 128)
                Rectangle().fill(.quaternary).frame(width: 0.5)
                upcomingList
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var upcomingList: some View {
        if let message = snapshot?.accessMessage
            ?? (snapshot == nil ? String(localized: "Calendar not loaded yet — open Pano") : nil) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 16)).foregroundStyle(.orange)
                Text(verbatim: message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(4).minimumScaleFactor(0.8)
            }
            .padding(.top, 4)
        } else {
            // Four rows don't fit the 104 pt body; they pushed the header out (measured).
            let events = (snapshot?.upcoming ?? []).filter { $0.end > date }.prefix(3)
            if events.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 16)).foregroundStyle(.tertiary)
                    Text("No upcoming events")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(events.enumerated()), id: \.offset) { _, event in
                        CalendarTap(url: CalendarLink.url(day: event.start, eventID: event.eventID)) {
                            CalendarEventRow(event: event, now: date)
                        }
                    }
                }
                .padding(.top, 1)
            }
        }
    }

    private var todayChip: String? {
        guard let n = snapshot?.todayCount(date), n > 0 else { return nil }
        let count = n.formatted()
        return String(localized: "today \(count)", comment: "Chip: number of events today")
    }
}

struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalendarEntry

    var body: some View {
        Group {
            if family == .systemSmall {
                SmallCalendarView(snapshot: entry.calendar, date: entry.date)
            } else {
                MediumCalendarView(snapshot: entry.calendar, date: entry.date)
            }
        }
        // Tapping outside a link (header, empty cell) opens Calendar at today.
        .widgetURL(CalendarLink.url(day: entry.date))
        .containerBackground(for: .widget) {
            ZStack {
                Rectangle().fill(.fill.tertiary)
                LinearGradient(colors: [calendarAccent.opacity(0.16), .clear],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
    }
}

struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CalendarWidget", provider: CalendarProvider()) { entry in
            CalendarWidgetView(entry: entry)
        }
        .configurationDisplayName("Calendar")
        .description("Month grid with event days and your upcoming events (Apple Calendar).")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
