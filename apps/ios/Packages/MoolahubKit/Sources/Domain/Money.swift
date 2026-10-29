import Foundation

/// An amount of US dollars held as integer cents.
///
/// Money is never a `Double` or `Float` anywhere in the app: amounts arrive from
/// the API as integer cents, are converted to `Decimal` only for formatting,
/// and user input is parsed from the string (see `Money.parse(_:)`).
public struct Money: Hashable, Comparable, Sendable, Codable {
    public var cents: Int64

    public init(cents: Int64) {
        self.cents = cents
    }

    public init(cents: Int) {
        self.cents = Int64(cents)
    }

    public static let zero = Money(cents: Int64(0))

    /// Exact dollar value (`Decimal(cents) / 100`), for formatting only.
    public var decimal: Decimal { Decimal(cents) / 100 }

    public var isZero: Bool { cents == 0 }
    public var isPositive: Bool { cents > 0 }
    public var isNegative: Bool { cents < 0 }

    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.cents < rhs.cents }
    public static func + (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents + rhs.cents) }
    public static func - (lhs: Money, rhs: Money) -> Money { Money(cents: lhs.cents - rhs.cents) }
    public static func += (lhs: inout Money, rhs: Money) { lhs.cents += rhs.cents }
    public static func -= (lhs: inout Money, rhs: Money) { lhs.cents -= rhs.cents }

    /// Encoded and decoded as a bare integer of cents, like the API.
    public init(from decoder: any Decoder) throws {
        cents = try decoder.singleValueContainer().decode(Int64.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(cents)
    }
}

// MARK: - Formatting (DESIGN.md §2.3)

/// How many decimals an amount shows.
public enum MoneyPresentation: Sendable, Hashable {
    /// Always two decimals: balances, money-move sheets, receipts, activity.
    case exact
    /// Drops `.00` only when the amount is a whole number of dollars
    /// (`$5,000` but `$5,000.50`): goal targets, presets, group summaries.
    case wholeIfRound
}

/// Which way money moved, relative to the user's balance.
public enum MoneyDirection: Sendable, Hashable {
    case none
    case moneyIn
    case moneyOut
}

extension Money {
    /// Fixed so the app always shows `$1,234.56`, never `US$1,234.56` (en-GH)
    /// or `1.234,56 $` (European regions). Dates use the user's locale; money
    /// does not.
    public static let formattingLocale = Locale(identifier: "en_US")

    /// U+2212 MINUS SIGN, used for money out (DESIGN.md §2.3).
    public static let minusSign = "\u{2212}"

    private var absoluteDecimal: Decimal { Decimal(cents.magnitude) / 100 }

    private func fractionDigits(_ presentation: MoneyPresentation) -> Int {
        switch presentation {
        case .exact: 2
        case .wholeIfRound: cents % 100 == 0 ? 0 : 2
        }
    }

    private func formattedMagnitude(_ presentation: MoneyPresentation) -> String {
        let style = Decimal.FormatStyle.Currency(code: "USD", locale: Self.formattingLocale)
            .precision(.fractionLength(fractionDigits(presentation)))
        return absoluteDecimal.formatted(style)
    }

    /// `$1,234.56`; negative amounts get a leading `−` (U+2212).
    public func formatted(_ presentation: MoneyPresentation = .exact) -> String {
        let body = formattedMagnitude(presentation)
        return cents < 0 ? Self.minusSign + body : body
    }

    /// `+$50.00` for money in, `−$20.00` for money out, `$0.00` (no sign) for
    /// zero. The sign comes from `direction`, the digits from the magnitude.
    public func formatted(_ presentation: MoneyPresentation = .exact, direction: MoneyDirection) -> String {
        guard cents != 0 else { return Money.zero.formatted(presentation) }
        switch direction {
        case .none: return formatted(presentation)
        case .moneyIn: return "+" + formattedMagnitude(presentation)
        case .moneyOut: return Self.minusSign + formattedMagnitude(presentation)
        }
    }

    /// VoiceOver text: "1,240.50 US dollars". Direction adds "plus" / "minus".
    public func accessibilityText(direction: MoneyDirection = .none) -> String {
        let style = Decimal.FormatStyle.Currency(code: "USD", locale: Self.formattingLocale)
            .precision(.fractionLength(2))
            .presentation(.fullName)
        let body = absoluteDecimal.formatted(style)
        switch direction {
        case .moneyIn where cents != 0: return "plus " + body
        case .moneyOut where cents != 0: return "minus " + body
        default: return cents < 0 ? "minus " + body : body
        }
    }
}

// MARK: - Parsing user input (port of artifacts/moolahub-app/src/lib/amount.ts)

extension Money {
    /// Maximum digits in the whole-dollar part accepted by `parse(_:)`; the
    /// web uses 12 so cents stay far below 2^53.
    public static let maxWholeDigits = 12

    /// Parses a user-typed amount into cents with the exact rules of the web
    /// app's `parseAmountToCents`: "19.99" → 1999, "0.29" → 29, "5" → 500,
    /// "$12,5" → 1250, "5." → 500, ".5" → 50. Returns nil for anything that
    /// isn't a plain non-negative amount with at most two decimals (negatives,
    /// "1e3", "NaN", "1.999", "", ".", "1,000", "+5"). Zero parses to zero;
    /// callers decide whether zero is allowed. No floating point is involved.
    public static func parse(_ input: String) -> Money? {
        var text = Substring(input.trimmingCharacters(in: .whitespacesAndNewlines))
        if text.first == "$" {
            text = text.dropFirst().drop(while: { $0.isWhitespace })
        }

        let separatorIndex = text.firstIndex(where: { $0 == "." || $0 == "," })
        let whole: Substring
        let fraction: Substring
        if let separatorIndex {
            whole = text[..<separatorIndex]
            fraction = text[text.index(after: separatorIndex)...]
        } else {
            whole = text
            fraction = ""
        }

        guard whole.count <= maxWholeDigits, whole.allSatisfy(\.isASCIIDigit) else { return nil }
        guard fraction.count <= 2, fraction.allSatisfy(\.isASCIIDigit) else { return nil }
        if whole.isEmpty && fraction.isEmpty { return nil }

        let wholeValue = Int64(whole) ?? 0
        let paddedFraction = String(fraction) + String(repeating: "0", count: 2 - fraction.count)
        let fractionValue = Int64(paddedFraction) ?? 0
        return Money(cents: wholeValue * 100 + fractionValue)
    }

    /// Cents back to a plain input string ("19.99", "100", "0.05"), for presets
    /// and "All" buttons. Negative amounts clamp to "0" (web `centsToAmountInput`).
    public var inputString: String {
        let clamped = max(0, cents)
        let whole = clamped / 100
        let fraction = clamped % 100
        if fraction == 0 { return String(whole) }
        return fraction < 10 ? "\(whole).0\(fraction)" : "\(whole).\(fraction)"
    }
}

extension Character {
    /// `0`…`9` only (JavaScript `\d`), never other Unicode digits.
    var isASCIIDigit: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }
}
