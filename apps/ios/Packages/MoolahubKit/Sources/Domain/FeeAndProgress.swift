import Foundation

/// A fee in basis points (200 = 2%), as returned by the API (`feeBps`).
public struct FeeRate: Hashable, Sendable {
    public let basisPoints: Int

    public init(basisPoints: Int) {
        self.basisPoints = max(0, basisPoints)
    }

    public static let none = FeeRate(basisPoints: 0)

    public var isZero: Bool { basisPoints == 0 }

    /// `floor(amount × bps / 10000)`, the server's rounding (DESIGN.md §7.3).
    public func fee(on amount: Money) -> Money {
        guard amount.cents > 0, basisPoints > 0 else { return .zero }
        return Money(cents: amount.cents * Int64(basisPoints) / 10_000)
    }

    /// `amount − fee`.
    public func net(of amount: Money) -> Money {
        amount - fee(on: amount)
    }

    /// "2%", "1.5%", "0.25%": bps / 100 with up to 2 decimals, no trailing zeros.
    public var percentText: String {
        let percent = Decimal(basisPoints) / 100
        let style = Decimal.FormatStyle(locale: Money.formattingLocale)
            .precision(.fractionLength(0...2))
            .grouping(.never)
        return percent.formatted(style) + "%"
    }
}

/// Goal progress maths (DESIGN.md §2.3, §4.5).
public enum GoalProgress {
    /// `floor(saved × 100 / target)` clamped to 0…100. A zero or negative
    /// target counts as complete once anything is saved.
    public static func percent(saved: Money, target: Money) -> Int {
        guard target.cents > 0 else { return saved.cents > 0 ? 100 : 0 }
        guard saved.cents > 0 else { return 0 }
        let raw = saved.cents.multipliedReportingOverflow(by: 100)
        let value = raw.overflow ? 100 : raw.partialValue / target.cents
        return Int(min(100, max(0, value)))
    }

    /// "42%", or "<1%" when something is saved but the floor is 0.
    public static func percentText(saved: Money, target: Money) -> String {
        let value = percent(saved: saved, target: target)
        if value == 0 && saved.cents > 0 { return "<1%" }
        return "\(value)%"
    }

    /// Fill fraction for a progress bar, `min(saved / target, 1)`.
    /// This is view geometry, not money, so a `Double` is fine here.
    public static func fraction(saved: Money, target: Money) -> Double {
        guard target.cents > 0 else { return saved.cents > 0 ? 1 : 0 }
        guard saved.cents > 0 else { return 0 }
        if saved.cents >= target.cents { return 1 }
        return Double(saved.cents) / Double(target.cents)
    }
}
