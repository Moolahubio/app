import Foundation

/// Shared date styles (DESIGN.md v2 W5). Formats use the person's locale and
/// calendar; money formatting stays fixed en_US (W4).
public enum MoolaDates {
    /// The one "date and time" style (ruling 9): goal history rows, pay-in rows
    /// and every receipt's "Date" row. "Oct 24 at 5:00 PM"; outside the current
    /// year "Oct 20, 2025 at 9:12 AM" (en_US).
    public static func dateAndTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).hour().minute()
        if !sameYear {
            style = style.year()
        }
        return date.formatted(style)
    }
}
