import Domain
import Foundation

/// One day of activity (DESIGN.md v2 B2.6): a header and the moves made that day,
/// newest first.
struct ActivityDaySection: Identifiable, Hashable, Sendable {
    /// Start of the day in the user's calendar.
    let day: Date
    /// "Today", "Yesterday", or "Tuesday, Oct 20" (DESIGN.md v2 W5).
    let title: String
    /// `yyyy-MM-dd` of `day`, for stable accessibility identifiers.
    let dayKey: String
    let items: [ActivityItem]

    var id: Date { day }
}

/// Groups API activity into day sections. Pure, so it can be reasoned about
/// (and previewed) without the network.
enum ActivityDayGrouping {
    /// Groups `items` by the calendar day of `createdAt`, newest day first,
    /// keeping the newest move first inside each day. Equal timestamps keep the
    /// server's order.
    static func sections(
        for items: [ActivityItem],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .autoupdatingCurrent
    ) -> [ActivityDaySection] {
        let ordered = items.enumerated().sorted { lhs, rhs in
            if lhs.element.createdAt != rhs.element.createdAt {
                return lhs.element.createdAt > rhs.element.createdAt
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var sections: [ActivityDaySection] = []
        var currentDay: Date?
        var currentItems: [ActivityItem] = []

        func flush() {
            guard let day = currentDay, !currentItems.isEmpty else { return }
            sections.append(ActivityDaySection(
                day: day,
                title: title(for: day, now: now, calendar: calendar, locale: locale),
                dayKey: APIDate.dayString(from: day, calendar: calendar),
                items: currentItems
            ))
        }

        for item in ordered {
            let day = calendar.startOfDay(for: item.createdAt)
            if day != currentDay {
                flush()
                currentDay = day
                currentItems = []
            }
            currentItems.append(item)
        }
        flush()
        return sections
    }

    /// Day header (DESIGN.md v2 W5): "Today", "Yesterday", else
    /// `.dateTime.weekday(.wide).day().month(.abbreviated)`, plus `.year()`
    /// when the day is not in the current year.
    static func title(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.abbreviated)
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
            style = style.year()
        }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return day.formatted(style)
    }
}
