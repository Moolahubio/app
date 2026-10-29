import Foundation

/// Date handling for API payloads.
///
/// The server sends instants as JavaScript `toISOString()` strings
/// (`2026-10-23T03:13:00.123Z`), date-only fields as `yyyy-MM-dd`, and goal
/// deadlines as UTC-midnight instants. `parse(_:)` accepts all of these plus
/// offsets and a space separator, so a format change on one route doesn't take
/// a screen down.
public enum APIDate {
    private static let utc = TimeZone(identifier: "UTC")!

    public static func parse(_ string: String) -> Date? {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        if let date = try? Date.ISO8601FormatStyle().parse(text) {
            return date
        }
        // "2026-10-23 03:13:00+00:00" (Postgres text) → ISO separator.
        if text.count > 10, text[text.index(text.startIndex, offsetBy: 10)] == " " {
            var isoText = text
            isoText.replaceSubrange(isoText.index(isoText.startIndex, offsetBy: 10)...isoText.index(isoText.startIndex, offsetBy: 10), with: "T")
            if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(isoText) {
                return date
            }
            if let date = try? Date.ISO8601FormatStyle().parse(isoText) {
                return date
            }
        }
        return parseDay(text)
    }

    /// `yyyy-MM-dd` → that day's UTC midnight.
    public static func parseDay(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == day // rejects 2026-02-31
        else { return nil }
        return date
    }

    /// The day the user picked, as `yyyy-MM-dd` in their own calendar
    /// (what the API expects for new goal deadlines and dates of birth).
    public static func dayString(from date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - digits.count)) + digits
        }
        return "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2))"
    }

    /// Formats a UTC-midnight day (goal deadline, date of birth) in UTC so
    /// users west of UTC don't see the day before: "1 Mar 2027" in en-GB,
    /// "Mar 1, 2027" in en-US (DESIGN.md §2.4).
    public static func formatUTCDay(_ date: Date, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.day().month(.abbreviated).year()
        style.timeZone = utc
        style.locale = locale
        return date.formatted(style)
    }
}

/// Coders configured for the API.
public enum APICoding {
    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = APIDate.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognised date format"
                )
            }
            return date
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return encoder
    }
}

// MARK: - Secrets

/// A value that must never be printed, logged or dumped (passwords, one-time
/// codes). Encodes as its plain string for the request body only.
public struct Secret: Encodable, Hashable, Sendable, ExpressibleByStringLiteral,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }

    public var isEmpty: Bool { rawValue.isEmpty }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The Moolahub session token returned to native clients (`X-Client: ios`).
/// Kept in the Keychain and sent as `x-session-token`. Never printed.
public struct SessionToken: Codable, Hashable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable
{
    public let rawValue: String

    public init(_ rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { "SessionToken(<redacted>)" }
    public var debugDescription: String { "SessionToken(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
