import Foundation

// The account's savings streak (`GET /streaks` and the three streak POSTs all
// answer a `StreakOverview`). Derived values and words: `Streaks.swift`.

/// How often the person saves to keep the streak. The server's values.
public enum StreakFrequency: String, CaseIterable, Codable, Hashable, Sendable {
    case daily
    case weekly
    case monthly
}

/// `StreakOverview`. `commitments` (always empty for the account streak) is
/// not decoded. Values are current at response time; a cached snapshot can be
/// past its `currentPeriodEnd`, which `StreakRules.isSavedThisPeriod` guards.
public struct StreakOverview: Codable, Hashable, Sendable {
    /// Nil when there is no streak or it is broken.
    public let hero: StreakHero?
    /// The raw value, so a new server value never fails decoding. Every
    /// sentence uses `effectiveFrequency`; the rows that name the frequency use
    /// `knownFrequency` and show nothing for an unknown value.
    public let frequency: String
    public let canChangeFrequency: Bool
    /// Set only after a change this year.
    public let nextChangeYear: Int?
    /// Exclusive end of the open period (the start of the next one).
    public let currentPeriodEnd: Date?
    public let currentPeriodSatisfied: Bool
    public let atRisk: Bool
    public let lifetimeBest: Int
    public let totalPeriodsSaved: Int
    public let freezes: StreakFreezes
    /// Ordered by year, then quarter.
    public let badges: [StreakBadge]
    public let badgeProgress: StreakBadgeProgress
    /// Decoded, not shown this wave.
    public let reminderOptIn: Bool
    public let vacation: StreakVacation
    /// The zone the server counts periods in (absent on a server before C3).
    /// Used only through the at-risk deadline's local-midnight test.
    public let timezone: String?

    /// The frequency when the server sent one of the three known values.
    public var knownFrequency: StreakFrequency? { StreakFrequency(rawValue: frequency) }

    /// `knownFrequency`, or weekly for an unknown value (the server's own
    /// fallback, `normFreq`).
    public var effectiveFrequency: StreakFrequency { knownFrequency ?? .weekly }
}

/// `StreakOverview.hero`. `status` is "active", "frozen" or "paused";
/// `commitmentName` and `emoji` are always null for the account streak and are
/// never shown.
public struct StreakHero: Codable, Hashable, Sendable {
    public let count: Int
    public let status: String
    public let commitmentName: String?
    public let emoji: String?
}

/// A quarter badge ("2026-q2"): cosmetic, never revoked.
public struct StreakBadge: Codable, Hashable, Sendable, Identifiable {
    public let badgeKey: String
    public let year: Int
    /// 1 to 4.
    public let quarterIndex: Int
    public let earnedAt: Date

    public var id: String { badgeKey }
}

/// `StreakOverview.badgeProgress`. `nextTier` is decoded and not used.
public struct StreakBadgeProgress: Codable, Hashable, Sendable {
    public let earnedQuarters: Int
    public let nextTier: String?
    /// Progress toward the next badge, 0 to 1 (bar geometry, not money).
    public let pct: Double
    /// Nil when the streak is broken or there is none.
    public let daysToNext: Int?
}

/// `StreakOverview.vacation`: the yearly break.
public struct StreakVacation: Codable, Hashable, Sendable {
    public let active: Bool
    public let start: Date?
    public let end: Date?
    public let usedThisYear: Bool
}

/// `StreakOverview.freezes`. The server's cap is not in the API, so no cap is
/// ever shown.
public struct StreakFreezes: Codable, Hashable, Sendable {
    public let balance: Int
    public let usedTotal: Int
}

// MARK: - Inputs

/// A break length the server accepts: a whole number of days, 1 to 30. The
/// initializer clamps, so every value is a valid body.
public struct StreakBreakDays: Hashable, Sendable {
    public static let range = 1...30
    /// The suggested length.
    public static let standard = StreakBreakDays(14)

    public let days: Int

    public init(_ days: Int) {
        self.days = min(max(days, Self.range.lowerBound), Self.range.upperBound)
    }
}

/// `SetStreakFrequencyBody` (`POST /streaks/frequency`): `{"frequency":"daily"}`.
public struct StreakFrequencyInput: Encodable, Sendable {
    public var frequency: String

    public init(_ frequency: StreakFrequency) {
        self.frequency = frequency.rawValue
    }
}

/// `StartStreakVacationBody` (`POST /streaks/vacation`): `{"days":14}`, an
/// integer.
public struct StreakBreakInput: Encodable, Sendable {
    public var days: Int

    public init(_ days: StreakBreakDays) {
        self.days = days.days
    }
}
