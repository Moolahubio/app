import Testing
@testable import Domain

/// streaks.md ST.15.1 item 11, R13: which badge the New badge sheet
/// celebrates. The store's use of it is `AuthTests/StreakStoreTests`.
@Suite("StreakBadgeSeen (R13)")
struct StreakBadgeSeenTests {
    /// The first live read for this user on this device seeds the list with
    /// every badge and celebrates nothing.
    @Test func firstReadSeedsSilently() throws {
        let result = StreakBadgeSeen.evaluate(badges: try streakBadges([(2025, 4), (2026, 1)]), seen: nil)
        #expect(result.seen == ["2025-q4", "2026-q1"])
        #expect(result.pending == nil)

        let none = StreakBadgeSeen.evaluate(badges: [], seen: nil)
        #expect(none.seen.isEmpty)
        #expect(none.pending == nil)
    }

    @Test func aNewBadgeIsPending() throws {
        let result = StreakBadgeSeen.evaluate(badges: try streakBadges([(2026, 1), (2026, 2)]), seen: ["2026-q1"])
        #expect(result.pending?.badgeKey == "2026-q2")
        #expect(result.seen == ["2026-q1"])
    }

    /// Several new badges: the newest by (year, quarter) shows; marking seen
    /// covers all of them.
    @Test func severalNewBadgesShowTheNewest() throws {
        let unordered = try streakBadges([(2026, 1), (2025, 4), (2025, 3), (2024, 4)])
        let result = StreakBadgeSeen.evaluate(badges: unordered, seen: ["2024-q4"])
        #expect(result.pending?.badgeKey == "2026-q1")
        #expect(result.seen == ["2024-q4"])
    }

    @Test func nothingNewIsNil() throws {
        let result = StreakBadgeSeen.evaluate(badges: try streakBadges([(2026, 2)]), seen: ["2026-q2", "2025-q1"])
        #expect(result.pending == nil)
        #expect(StreakBadgeSeen.evaluate(badges: [], seen: []).pending == nil)
    }
}
