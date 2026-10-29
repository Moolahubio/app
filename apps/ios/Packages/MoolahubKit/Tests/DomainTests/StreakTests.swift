import Foundation
import Testing
@testable import Domain

// streaks.md ST.15.1 items 1 to 10, 12 and 14 (R7's "Next" cases removed by
// D-09), `StreakWords.frequencyName` (D-38) and the other streak words of SPEC
// §6.2. Item 11 (R13) is `StreakBadgeSeenTests`; item 13 (endpoints) is
// `APIClientTests/EndpointWaveTests`.

/// A device calendar in `zone`, speaking en_US.
func streakCalendar(_ zone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    calendar.locale = Locale(identifier: "en_US")
    return calendar
}

func streakDate(_ text: String) -> Date {
    APIDate.parse(text)!
}

/// `GET_streaks.json` (demo, captured 2026-10-25), with fields changed.
func streakOverview(_ change: (inout [String: Any]) -> Void = { _ in }) throws -> StreakOverview {
    var object = try Fixture.object("GET_streaks")
    change(&object)
    return try Fixture.decode(StreakOverview.self, object: object)
}

/// A JSON badge.
func badgeObject(_ year: Int, _ quarter: Int) -> [String: Any] {
    let month = String(format: "%02d", quarter * 3)
    return ["badgeKey": "\(year)-q\(quarter)", "year": year, "quarterIndex": quarter, "earnedAt": "\(year)-\(month)-01T00:00:00.000Z"]
}

func streakBadges(_ list: [(Int, Int)]) throws -> [StreakBadge] {
    try Fixture.decode([StreakBadge].self, object: list.map { badgeObject($0.0, $0.1) })
}

/// The capture moment of the sample: inside the open week, which ends
/// 2026-10-26T00:00Z.
private let sampleNow = streakDate("2026-10-25T12:00:00.000Z")

/// Sets the hero (`nil` removes it).
private func hero(_ count: Int?, status: String = "active") -> (inout [String: Any]) -> Void {
    { object in
        guard let count else { object["hero"] = NSNull(); return }
        object["hero"] = ["count": count, "status": status, "commitmentName": NSNull(), "emoji": NSNull()]
    }
}

private func onBreak(until end: String) -> (inout [String: Any]) -> Void {
    { object in
        object["vacation"] = ["active": true, "start": "2026-10-25T15:00:00.000Z", "end": end, "usedThisYear": true]
    }
}

private func combine(_ changes: ((inout [String: Any]) -> Void)...) -> (inout [String: Any]) -> Void {
    { object in for change in changes { change(&object) } }
}

@Suite("Streak overview decoding")
struct StreakDecodingTests {
    /// Item 1.
    @Test func capturedSample() throws {
        let overview = try streakOverview()
        let hero = try #require(overview.hero)
        #expect(hero.count == 1)
        #expect(hero.status == "active")
        #expect(hero.commitmentName == nil)
        #expect(overview.frequency == "weekly")
        #expect(overview.knownFrequency == .weekly)
        #expect(overview.currentPeriodEnd == streakDate("2026-10-26T00:00:00Z"))
        #expect(overview.currentPeriodSatisfied)
        #expect(overview.freezes.balance == 1)
        #expect(overview.freezes.usedTotal == 0)
        #expect(overview.badges.isEmpty)
        #expect(overview.badgeProgress.daysToNext == 90)
        #expect(overview.badgeProgress.earnedQuarters == 0)
        #expect(!overview.vacation.active)
        #expect(overview.timezone == nil)
        #expect(overview.lifetimeBest == 1)
        #expect(overview.totalPeriodsSaved == 1)
        #expect(overview.canChangeFrequency)
        #expect(overview.nextChangeYear == nil)
    }

    /// Item 2.
    @Test func variants() throws {
        #expect(try streakOverview(hero(nil)).hero == nil)

        let noProgress = try streakOverview { object in
            object["badgeProgress"] = ["earnedQuarters": 0, "nextTier": "bronze", "pct": 0, "daysToNext": NSNull()]
        }
        #expect(noProgress.badgeProgress.daysToNext == nil)

        let breakTaken = try streakOverview(onBreak(until: "2026-11-08T15:00:00.000Z"))
        #expect(breakTaken.vacation.active)
        #expect(breakTaken.vacation.start == streakDate("2026-10-25T15:00:00Z"))
        #expect(breakTaken.vacation.end == streakDate("2026-11-08T15:00:00Z"))

        let twoBadges = try streakOverview { object in object["badges"] = [badgeObject(2026, 1), badgeObject(2026, 2)] }
        #expect(twoBadges.badges.map(\.badgeKey) == ["2026-q1", "2026-q2"])
        #expect(twoBadges.badges.last?.quarterIndex == 2)

        let commitments = try streakOverview { object in object["commitments"] = [["id": "x", "name": "Something"]] }
        #expect(commitments.hero?.count == 1)

        #expect(try streakOverview { $0["timezone"] = "Africa/Accra" }.timezone == "Africa/Accra")

        let unknownStatus = try streakOverview(hero(2, status: "frozen2"))
        #expect(StreakRules.displayStatus(unknownStatus) == .unknown)
    }

    /// Item 2, D-38: an unknown frequency decodes; sentences fall back to
    /// weekly and the rows that name it show nothing.
    @Test func unknownFrequency() throws {
        let overview = try streakOverview { $0["frequency"] = "fortnightly" }
        #expect(overview.frequency == "fortnightly")
        #expect(overview.knownFrequency == nil)
        #expect(overview.effectiveFrequency == .weekly)
        #expect(StreakWords.frequencyName(overview.frequency) == nil)
        #expect(StreakWords.homeRow(overview, now: sampleNow, calendar: streakCalendar()).subtitle == "Saved this week")
    }
}

@Suite("Streak rules")
struct StreakRulesTests {
    /// Item 3, R1.
    @Test func savedOnlyWhileThePeriodIsOpen() throws {
        let overview = try streakOverview()
        #expect(StreakRules.isSavedThisPeriod(overview, now: sampleNow))
        #expect(!StreakRules.isSavedThisPeriod(overview, now: streakDate("2026-10-26T00:00:00Z")))
        #expect(!StreakRules.isSavedThisPeriod(overview, now: streakDate("2026-10-27T09:00:00Z")))
        #expect(!StreakRules.isSavedThisPeriod(try streakOverview { $0["currentPeriodSatisfied"] = false }, now: sampleNow))
        #expect(!StreakRules.isSavedThisPeriod(try streakOverview { $0["currentPeriodEnd"] = NSNull() }, now: sampleNow))
    }

    /// Item 4, R2's precedence.
    @Test func displayStatusPrecedence() throws {
        #expect(StreakRules.displayStatus(try streakOverview(hero(nil))) == StreakDisplayStatus.none)
        #expect(StreakRules.displayStatus(try streakOverview(hero(0))) == StreakDisplayStatus.none)
        #expect(StreakRules.displayStatus(try streakOverview(combine(hero(3, status: "frozen"), onBreak(until: "2026-11-08T15:00:00.000Z")))) == .onBreak)
        #expect(StreakRules.displayStatus(try streakOverview(hero(3, status: "frozen"))) == .frozen)
        #expect(StreakRules.displayStatus(try streakOverview(hero(3, status: "paused"))) == .active)
        #expect(StreakRules.displayStatus(try streakOverview(hero(3, status: "active"))) == .active)
        #expect(StreakRules.displayStatus(try streakOverview(hero(3, status: "frozen2"))) == .unknown)
        #expect(StreakRules.displayStatus(try streakOverview(combine(hero(nil), onBreak(until: "2026-11-08T15:00:00.000Z")))) == StreakDisplayStatus.none)
    }

    /// R5.
    @Test func atRiskNoticeShowsOnlyWhileOpenAndNotOnABreak() throws {
        let atRisk = try streakOverview { $0["atRisk"] = true; $0["currentPeriodSatisfied"] = false }
        #expect(StreakRules.showsAtRisk(atRisk, now: sampleNow))
        #expect(!StreakRules.showsAtRisk(atRisk, now: streakDate("2026-10-26T00:00:00Z")))
        #expect(!StreakRules.showsAtRisk(try streakOverview(), now: sampleNow))
        let breakTaken = try streakOverview(combine({ $0["atRisk"] = true }, onBreak(until: "2026-11-08T15:00:00.000Z")))
        #expect(!StreakRules.showsAtRisk(breakTaken, now: sampleNow))
    }

    /// Item 7, R7 (no "Next" tier, D-09).
    @Test(arguments: [(0, StreakTier.none), (1, .bronze), (3, .bronze), (4, .silver), (7, .silver), (8, .gold), (12, .gold)])
    func tiers(_ count: Int, _ tier: StreakTier) {
        #expect(StreakRules.tier(count: count) == tier)
    }

    /// Item 8, R8.
    @Test func quarterRows() throws {
        let rows = StreakRules.quarterRows(badges: try streakBadges([(2025, 3), (2026, 2)]), now: sampleNow, calendar: streakCalendar())
        #expect(rows.map(\.year) == [2026, 2025])
        #expect(rows[0].quarters.map(\.collected) == [false, true, false, false])
        #expect(rows[1].quarters.map(\.collected) == [false, false, true, false])
        #expect(rows[0].quarters.map(\.label) == ["Q1", "Q2", "Q3", "Q4"])

        let none = StreakRules.quarterRows(badges: [], now: sampleNow, calendar: streakCalendar())
        #expect(none.map(\.year) == [2026])
        #expect(none[0].quarters.allSatisfy { !$0.collected })

        // The current year comes from the device calendar.
        let tokyo = StreakRules.quarterRows(badges: [], now: streakDate("2026-12-31T20:00:00Z"), calendar: streakCalendar("Asia/Tokyo"))
        #expect(tokyo.map(\.year) == [2027])
    }

    /// Item 9, R9.
    @Test func breakEnd() {
        #expect(StreakRules.breakEnd(days: StreakBreakDays(14), now: streakDate("2026-10-25T15:00:00Z")) == streakDate("2026-11-08T15:00:00Z"))
    }

    /// Item 13's clamp: every value is a valid body.
    @Test func breakDaysClamp() {
        #expect(StreakBreakDays(14).days == 14)
        #expect(StreakBreakDays(0).days == 1)
        #expect(StreakBreakDays(-3).days == 1)
        #expect(StreakBreakDays(31).days == 30)
        #expect(StreakBreakDays(30).days == 30)
        #expect(StreakBreakDays.standard.days == 14)
    }

    /// R10.
    @Test func nextYear() throws {
        #expect(StreakRules.nextYear(try streakOverview(), now: sampleNow, calendar: streakCalendar()) == 2027)
        #expect(StreakRules.nextYear(try streakOverview { $0["nextChangeYear"] = 2028 }, now: sampleNow, calendar: streakCalendar()) == 2028)
    }

    /// R12.
    @Test func monthsOfSaving() throws {
        let earned: (Int) -> (inout [String: Any]) -> Void = { quarters in
            { $0["badgeProgress"] = ["earnedQuarters": quarters, "nextTier": "silver", "pct": 0.5, "daysToNext": 40] }
        }
        #expect(StreakRules.monthsOfSaving(try streakOverview(earned(2))) == 6)
        #expect(StreakRules.monthsOfSaving(try streakOverview(earned(0))) == nil)
        #expect(StreakRules.monthsOfSaving(try streakOverview(combine(earned(1), hero(14, status: "frozen")))) == 3)
        #expect(StreakRules.monthsOfSaving(try streakOverview(combine(earned(1), onBreak(until: "2026-11-08T15:00:00.000Z")))) == 3)
        #expect(StreakRules.monthsOfSaving(try streakOverview(combine(earned(1), hero(nil)))) == nil)
        #expect(StreakRules.monthsOfSaving(try streakOverview(combine(earned(1), hero(14, status: "frozen2")))) == nil)
    }
}

/// Item 10, R11: every row of ST.8.2's table.
@Suite("Receipt footnote (R11)")
struct StreakReceiptNoteTests {
    private let thisWeekEnd = "2026-10-26T00:00:00.000Z"
    private let lastWeekEnd = "2026-10-19T00:00:00.000Z"

    private func state(_ count: Int?, end: String, saved: Bool, status: String = "active") throws -> StreakOverview {
        try streakOverview(combine(hero(count, status: status), { object in
            object["currentPeriodEnd"] = end
            object["currentPeriodSatisfied"] = saved
        }))
    }

    @Test func firstSaveEver() throws {
        let note = StreakRules.receiptNote(before: try state(nil, end: thisWeekEnd, saved: false), after: try state(1, end: thisWeekEnd, saved: true), now: sampleNow)
        #expect(note == .starts(.weekly))
        #expect(note?.text == "This starts your weekly streak.")
    }

    @Test func saveAfterABrokenStreak() throws {
        let before = try streakOverview(combine(hero(nil), { $0["lifetimeBest"] = 5; $0["currentPeriodSatisfied"] = false }))
        #expect(StreakRules.receiptNote(before: before, after: try state(1, end: thisWeekEnd, saved: true), now: sampleNow) == .starts(.weekly))
    }

    @Test func staleRowMissedPeriodNoFreeze() throws {
        let note = StreakRules.receiptNote(before: try state(3, end: lastWeekEnd, saved: false), after: try state(1, end: thisWeekEnd, saved: true), now: sampleNow)
        #expect(note?.text == "This starts your weekly streak.")
    }

    @Test func newPeriodStreakAlive() throws {
        let note = StreakRules.receiptNote(before: try state(3, end: thisWeekEnd, saved: false), after: try state(4, end: thisWeekEnd, saved: true), now: sampleNow)
        #expect(note == .keepsGoing(.weekly))
        #expect(note?.text == "This keeps your weekly streak going.")
    }

    @Test func staleRowSavedPeriodRolled() throws {
        let note = StreakRules.receiptNote(before: try state(3, end: lastWeekEnd, saved: true), after: try state(4, end: thisWeekEnd, saved: true), now: sampleNow)
        #expect(note?.text == "This keeps your weekly streak going.")
    }

    @Test func saveDuringABreak() throws {
        let before = try streakOverview(combine(hero(3, status: "paused"), onBreak(until: "2026-11-08T15:00:00.000Z"), { $0["currentPeriodSatisfied"] = false }))
        let after = try streakOverview(combine(hero(4, status: "paused"), onBreak(until: "2026-11-08T15:00:00.000Z")))
        #expect(StreakRules.receiptNote(before: before, after: after, now: sampleNow) == .keepsGoing(.weekly))
    }

    @Test func alreadySavedThisPeriod() throws {
        #expect(StreakRules.receiptNote(before: try state(3, end: thisWeekEnd, saved: true), after: try state(3, end: thisWeekEnd, saved: true), now: sampleNow) == nil)
    }

    @Test func aMissingReadNeverGuesses() throws {
        #expect(StreakRules.receiptNote(before: nil, after: try state(1, end: thisWeekEnd, saved: true), now: sampleNow) == nil)
        #expect(StreakRules.receiptNote(before: try state(nil, end: thisWeekEnd, saved: false), after: nil, now: sampleNow) == nil)
    }

    /// A move that didn't go through recorded no save: `after` reads as
    /// `before`, so there is no footnote (and the receipt hides it while it
    /// says Didn't go through).
    @Test func aFailedMoveShowsNone() throws {
        let unsaved = try state(3, end: thisWeekEnd, saved: false)
        #expect(StreakRules.receiptNote(before: unsaved, after: unsaved, now: sampleNow) == nil)
    }

    /// The satisfied flag alone is never the test: a closed period is not
    /// saved (R1).
    @Test func aClosedPeriodShowsNone() throws {
        let note = StreakRules.receiptNote(before: try state(nil, end: lastWeekEnd, saved: false), after: try state(1, end: lastWeekEnd, saved: true), now: sampleNow)
        #expect(note == nil)
    }

    /// The cadence word comes from `after.effectiveFrequency`.
    @Test func cadenceWordFromTheNewRead() throws {
        let daily = try streakOverview(combine(hero(1), { $0["frequency"] = "daily" }))
        #expect(StreakRules.receiptNote(before: try state(nil, end: thisWeekEnd, saved: false), after: daily, now: sampleNow)?.text == "This starts your daily streak.")
        let monthly = try streakOverview(combine(hero(5), { $0["frequency"] = "monthly" }))
        #expect(StreakRules.receiptNote(before: try state(4, end: thisWeekEnd, saved: false), after: monthly, now: sampleNow)?.text == "This keeps your monthly streak going.")
        let unknown = try streakOverview(combine(hero(1), { $0["frequency"] = "fortnightly" }))
        #expect(StreakRules.receiptNote(before: try state(nil, end: thisWeekEnd, saved: false), after: unknown, now: sampleNow)?.text == "This starts your weekly streak.")
    }
}

@Suite("Streak words")
struct StreakWordsTests {
    /// Item 5, R3 and R4.
    @Test func unitsAndPeriods() {
        #expect(StreakWords.unitWord(count: 1, frequency: .daily) == "day")
        #expect(StreakWords.unitWord(count: 3, frequency: .daily) == "days")
        #expect(StreakWords.unitWord(count: 1, frequency: .weekly) == "week")
        #expect(StreakWords.unitWord(count: 3, frequency: .weekly) == "weeks")
        #expect(StreakWords.unitWord(count: 1, frequency: .monthly) == "month")
        #expect(StreakWords.unitWord(count: 3, frequency: .monthly) == "months")
        #expect(StreakWords.periodPhrase(frequency: .daily) == "today")
        #expect(StreakWords.periodPhrase(frequency: .weekly) == "this week")
        #expect(StreakWords.periodPhrase(frequency: .monthly) == "this month")
    }

    /// Item 7, D-38: the Streak screen's and Account's frequency value.
    @Test func frequencyNames() {
        #expect(StreakWords.frequencyName("daily") == "Daily")
        #expect(StreakWords.frequencyName("weekly") == "Weekly")
        #expect(StreakWords.frequencyName("monthly") == "Monthly")
        #expect(StreakWords.frequencyName("Weekly") == nil)
        #expect(StreakWords.frequencyName("fortnightly") == nil)
        #expect(StreakWords.frequencyName("") == nil)
    }

    /// ST-03.
    @Test func unitLines() {
        #expect(StreakWords.unitLine(count: 1, frequency: .weekly) == "week so far")
        #expect(StreakWords.unitLine(count: 13, frequency: .weekly) == "weeks in a row")
        #expect(StreakWords.unitLine(count: 1, frequency: .daily) == "day so far")
        #expect(StreakWords.unitLine(count: 12, frequency: .daily) == "days in a row")
        #expect(StreakWords.unitLine(count: 1, frequency: .monthly) == "month so far")
        #expect(StreakWords.unitLine(count: 2, frequency: .monthly) == "months in a row")
    }

    /// ST-04 (D-19) and ST-05.
    @Test func statusWordsAndSavedLines() {
        #expect(StreakWords.statusWord(.active) == "Active")
        #expect(StreakWords.statusWord(.frozen) == "Covered by a freeze")
        #expect(StreakWords.statusWord(.onBreak) == "On a break")
        #expect(StreakWords.statusWord(.none) == "No streak yet")
        #expect(StreakWords.statusWord(.unknown) == nil)
        #expect(StreakWords.savedLine(saved: true, frequency: .daily) == "Saved today")
        #expect(StreakWords.savedLine(saved: true, frequency: .weekly) == "Saved this week")
        #expect(StreakWords.savedLine(saved: true, frequency: .monthly) == "Saved this month")
        #expect(StreakWords.savedLine(saved: false, frequency: .daily) == "Not saved today yet")
        #expect(StreakWords.savedLine(saved: false, frequency: .weekly) == "Not saved this week yet")
        #expect(StreakWords.savedLine(saved: false, frequency: .monthly) == "Not saved this month yet")
    }

    /// AC-18 with the captured sample, and SPEC §1.4's other states.
    @Test func homeRow() throws {
        let calendar = streakCalendar()
        #expect(StreakWords.homeRow(try streakOverview(), now: sampleNow, calendar: calendar) == StreakRowWords(title: "1 week", subtitle: "Saved this week"))
        // After the period end with no new save, never "Saved this week".
        #expect(StreakWords.homeRow(try streakOverview(), now: streakDate("2026-10-26T01:00:00Z"), calendar: calendar)
            == StreakRowWords(title: "1 week", subtitle: "One save keeps your weekly streak going"))
        #expect(StreakWords.homeRow(try streakOverview(hero(nil)), now: sampleNow, calendar: calendar)
            == StreakRowWords(title: "No streak yet", subtitle: "Save once to start a streak"))
        #expect(StreakWords.homeRow(try streakOverview(combine(hero(3), onBreak(until: "2026-11-08T15:00:00.000Z"))), now: sampleNow, calendar: calendar)
            == StreakRowWords(title: "3 weeks", subtitle: "On a break until Nov 8"))
        #expect(StreakWords.homeRow(try streakOverview(combine(hero(12), { $0["frequency"] = "daily" })), now: sampleNow, calendar: calendar).title == "12 days")
        #expect(StreakWords.homeRow(try streakOverview(combine(hero(2), { $0["frequency"] = "monthly"; $0["currentPeriodSatisfied"] = false })), now: sampleNow, calendar: calendar)
            == StreakRowWords(title: "2 months", subtitle: "One save keeps your monthly streak going"))
    }

    /// The Streak screen's status line (ST-04 · ST-05, or ST-06).
    @Test func statusLines() throws {
        let calendar = streakCalendar()
        #expect(StreakWords.statusLine(try streakOverview(), now: sampleNow, calendar: calendar) == "Active \u{00B7} Saved this week")
        let frozen = try streakOverview(combine(hero(4, status: "frozen"), { $0["currentPeriodSatisfied"] = false }))
        #expect(StreakWords.statusLine(frozen, now: sampleNow, calendar: calendar) == "Covered by a freeze \u{00B7} Not saved this week yet")
        #expect(StreakWords.statusLine(try streakOverview(hero(2, status: "frozen2")), now: sampleNow, calendar: calendar) == "Saved this week")
        #expect(StreakWords.statusLine(try streakOverview(combine(hero(3), onBreak(until: "2026-11-08T15:00:00.000Z"))), now: sampleNow, calendar: calendar) == "On a break until Nov 8")
        #expect(StreakWords.statusLine(try streakOverview(combine(hero(3), onBreak(until: "2027-01-08T15:00:00.000Z"))), now: sampleNow, calendar: calendar) == "On a break until Jan 8, 2027")
        #expect(StreakWords.statusLine(try streakOverview(hero(nil)), now: sampleNow, calendar: calendar) == nil)
    }

    /// SPEC §2.3's hero VoiceOver values.
    @Test func heroSpoken() throws {
        let calendar = streakCalendar()
        #expect(StreakWords.heroSpoken(try streakOverview(), now: sampleNow, calendar: calendar) == "1 week so far. Active. Saved this week.")
        #expect(StreakWords.heroSpoken(try streakOverview(hero(1, status: "frozen")), now: sampleNow, calendar: calendar) == "1 week so far. Covered by a freeze. Saved this week.")
        #expect(StreakWords.heroSpoken(try streakOverview(combine(hero(0), { $0["lifetimeBest"] = 0 })), now: sampleNow, calendar: calendar)
            == "No streak yet. Save once this week to start your streak.")
        #expect(StreakWords.heroSpoken(try streakOverview(combine(hero(3), onBreak(until: "2026-11-08T15:00:00.000Z"))), now: sampleNow, calendar: calendar)
            == "3 weeks in a row. On a break until November 8.")
        #expect(StreakWords.heroSpoken(try streakOverview(hero(1, status: "frozen2")), now: sampleNow, calendar: calendar) == "1 week so far. Saved this week.")
    }

    /// ST-07.
    @Test func noStreakLine() throws {
        #expect(StreakWords.noStreakLine(try streakOverview(combine(hero(nil), { $0["lifetimeBest"] = 0 }))) == "Save once this week to start your streak.")
        #expect(StreakWords.noStreakLine(try streakOverview(hero(nil))) == "Save once this week to start a new streak.")
        #expect(StreakWords.noStreakLine(try streakOverview(combine(hero(nil), { $0["lifetimeBest"] = 0; $0["frequency"] = "monthly" })))
            == "Save once this month to start your streak.")
    }

    /// Item 6, R6 and ST-08, in the device zone.
    @Test func atRiskDeadlines() throws {
        let atRisk = try streakOverview { $0["atRisk"] = true; $0["currentPeriodSatisfied"] = false }
        let utc = streakCalendar()
        #expect(StreakWords.atRiskNotice(atRisk, now: streakDate("2026-10-25T10:00:00Z"), calendar: utc) == "Save once today to keep your streak.")
        #expect(StreakWords.atRiskNotice(atRisk, now: streakDate("2026-10-24T10:00:00Z"), calendar: utc) == "Save once by tomorrow to keep your streak.")
        #expect(StreakWords.atRiskNotice(atRisk, now: streakDate("2026-10-21T10:00:00Z"), calendar: utc) == "Save once by Sunday, Oct 25 to keep your streak.")
        // The server's zone (UTC) is not the device's: the exact time.
        let newYork = StreakWords.atRiskNotice(atRisk, now: streakDate("2026-10-25T10:00:00Z"), calendar: streakCalendar("America/New_York"))
        #expect(newYork.map(Self.plainSpaces) == "Save once before Oct 25 at 8:00 PM to keep your streak.")
        let monthly = try streakOverview { $0["frequency"] = "monthly"; $0["currentPeriodEnd"] = "2027-01-01T00:00:00.000Z" }
        #expect(StreakWords.atRiskNotice(monthly, now: streakDate("2026-12-10T10:00:00Z"), calendar: utc) == "Save once by Thursday, Dec 31 to keep your streak.")
        // A last day in another year names the year.
        let nextYear = try streakOverview { $0["currentPeriodEnd"] = "2027-01-05T00:00:00.000Z" }
        #expect(StreakWords.atRiskNotice(nextYear, now: streakDate("2026-12-30T10:00:00Z"), calendar: utc) == "Save once by Monday, Jan 4, 2027 to keep your streak.")
        #expect(StreakWords.atRiskNotice(try streakOverview { $0["currentPeriodEnd"] = NSNull() }, now: sampleNow, calendar: utc) == nil)
    }

    /// ST-11 and ST-13 (the captured sample: "No badge yet", "Next badge in
    /// about 90 days.").
    @Test func badgeBlock() throws {
        let sample = try streakOverview()
        #expect(StreakWords.tierTitle(StreakRules.tier(count: sample.badges.count)) == "No badge yet")
        #expect(StreakWords.badgeDaysLine(sample) == "Next badge in about 90 days.")
        #expect(StreakWords.tierTitle(.bronze) == "Bronze saver")
        #expect(StreakWords.tierTitle(.silver) == "Silver saver")
        #expect(StreakWords.tierTitle(.gold) == "Gold saver")
        let progress: (Any) -> (inout [String: Any]) -> Void = { days in
            { $0["badgeProgress"] = ["earnedQuarters": 0, "nextTier": "bronze", "pct": 0.9, "daysToNext": days] }
        }
        #expect(StreakWords.badgeDaysLine(try streakOverview(progress(1))) == "Next badge in about 1 day.")
        #expect(StreakWords.badgeDaysLine(try streakOverview(progress(0))) == "Your next badge is on its way.")
        #expect(StreakWords.badgeDaysLine(try streakOverview(progress(NSNull()))) == "Keep a streak going for three months to get a badge.")
        #expect(StreakWords.badgeDaysLine(try streakOverview(onBreak(until: "2026-11-08T15:00:00.000Z"))) == "Badge progress is paused during your break.")
    }

    /// ST-14.
    @Test func quarterWords() {
        let collected = StreakQuarter(year: 2026, quarter: 2, collected: true)
        let open = StreakQuarter(year: 2026, quarter: 3, collected: false)
        #expect(collected.label == "Q2")
        #expect(collected.word == "Collected")
        #expect(open.word == "Not yet")
        #expect(collected.spoken == "Q2 2026, collected")
        #expect(open.spoken == "Q3 2026, not collected yet")
    }

    /// ST-17, ST-18 (D-21) and ST-19.
    @Test func settingsRowWords() throws {
        let calendar = streakCalendar()
        #expect(StreakWords.frequencyLockNote(try streakOverview(), now: sampleNow, calendar: calendar) == "You can change this once a year.")
        let locked = try streakOverview { $0["canChangeFrequency"] = false; $0["nextChangeYear"] = 2027 }
        #expect(StreakWords.frequencyLockNote(locked, now: sampleNow, calendar: calendar) == "You can change this again in 2027.")
        #expect(StreakWords.freezesValue(try streakOverview()) == "1 available")
        #expect(StreakWords.freezesNote(frequency: .weekly) == "One freeze can cover a missed week in any three months, and you get a new one every three months.")
        #expect(StreakWords.freezesNote(frequency: .daily) == "One freeze can cover a missed day in any three months, and you get a new one every three months.")
        #expect(StreakWords.breakUntilValue(streakDate("2026-11-08T15:00:00Z"), now: sampleNow, calendar: calendar) == "Until Nov 8")
        #expect(StreakWords.breakAgainValue(now: sampleNow, calendar: calendar) == "Again in 2027")
    }

    /// ST-33.
    @Test func frequencyChangeTitles() {
        #expect(StreakWords.frequencyChangeTitle(to: .daily) == "Change to daily?")
        #expect(StreakWords.frequencyChangeTitle(to: .monthly) == "Change to monthly?")
        #expect(StreakWords.frequencyChangeButton(to: .weekly) == "Change to weekly")
    }

    /// Item 12, ST-34: alive, on a break and no streak, for every new
    /// frequency, with counts 1 and 3.
    @Test(arguments: [StreakFrequency.daily, .weekly, .monthly])
    func frequencyChangeMessages(_ frequency: StreakFrequency) throws {
        let calendar = streakCalendar()
        let units = ["daily": "days", "weekly": "weeks", "monthly": "months"][frequency.rawValue]!
        let period = ["daily": "today", "weekly": "this week", "monthly": "this month"][frequency.rawValue]!
        let yearly = "You can change this once a year, so your next change is in 2027."
        for count in [1, 3] {
            #expect(StreakWords.frequencyChangeMessage(try streakOverview(hero(count)), to: frequency, now: sampleNow, calendar: calendar)
                == "Your streak stays at \(count), counted in \(units) from now. Save once \(period) to keep it going. \(yearly)")
            let breakTaken = try streakOverview(combine(hero(count, status: "paused"), onBreak(until: "2026-11-08T15:00:00.000Z")))
            #expect(StreakWords.frequencyChangeMessage(breakTaken, to: frequency, now: sampleNow, calendar: calendar)
                == "Your streak stays at \(count), counted in \(units) from now. \(yearly)")
        }
        #expect(StreakWords.frequencyChangeMessage(try streakOverview(hero(nil)), to: frequency, now: sampleNow, calendar: calendar)
            == "Your streak will count \(units). \(yearly)")
    }

    /// ST-41 to ST-46.
    @Test func breakSheetWords() {
        let calendar = streakCalendar()
        let now = streakDate("2026-10-25T15:00:00Z")
        #expect(StreakWords.breakSheetBody(frequency: .weekly) == "Your streak pauses, so a missed week won't end it.")
        #expect(StreakWords.breakSheetBody(frequency: .monthly) == "Your streak pauses, so a missed month won't end it.")
        #expect(StreakWords.breakLength(StreakBreakDays(14)) == "14 days")
        #expect(StreakWords.breakLength(StreakBreakDays(1)) == "1 day")
        #expect(StreakWords.breakSheetUntil(StreakBreakDays(14), now: now, calendar: calendar) == "Until Sun, Nov 8")
        #expect(StreakWords.startBreakTitle(StreakBreakDays(14)) == "Start a 14-day break?")
        #expect(StreakWords.startBreakTitle(StreakBreakDays(1)) == "Start a 1-day break?")
        #expect(StreakWords.startBreakMessage(StreakBreakDays(14), now: now, calendar: calendar)
            == "Your streak pauses until Sun, Nov 8. You get one break a year, and ending it early still uses it.")
    }

    /// ST-81 and ST-82.
    @Test func newBadgeWords() throws {
        let badge = try #require(try streakBadges([(2026, 2)]).first)
        #expect(StreakWords.badgeLine(badge, badgeCount: 1) == "Q2 2026 \u{00B7} Bronze")
        #expect(StreakWords.badgeLine(badge, badgeCount: 4) == "Q2 2026 \u{00B7} Silver")
        #expect(StreakWords.badgeLine(badge, badgeCount: 8) == "Q2 2026 \u{00B7} Gold")
        #expect(StreakWords.badgeBody(badgeCount: 1) == "Three months of steady saving.")
        #expect(StreakWords.badgeBody(badgeCount: 2) == "Another three months of steady saving.")
    }

    /// Times are formatted with the system's narrow no-break space before
    /// AM/PM; compare with plain spaces.
    static func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
    }
}

/// Item 14: the share card's model and ST-98.
@Suite("Share card")
struct StreakShareCardTests {
    private let calendar = streakCalendar()

    @Test func capturedSampleWithTheAmountOff() throws {
        let card = StreakShareCard(overview: try streakOverview(), amountSaved: nil, now: sampleNow, calendar: calendar)
        #expect(card.countText == "1")
        #expect(card.unitLine == "week so far")
        #expect(card.monthsLine == nil)
        #expect(card.tierWord == nil)
        #expect(card.amountLine == nil)
        #expect(card.yearLabel == "2026 badges")
        #expect(card.quarters.map(\.word) == ["Not yet", "Not yet", "Not yet", "Not yet"])
        #expect(card.spokenValue == "1 week so far. 2026 badges: none collected yet.")
        let text = card.strings.joined(separator: " ")
        #expect(!text.contains("$"))
        // No digits but the count, the months figure and the year (and the
        // quarter labels).
        let digits = text.replacingOccurrences(of: "2026", with: "")
            .replacingOccurrences(of: "Q1", with: "").replacingOccurrences(of: "Q2", with: "")
            .replacingOccurrences(of: "Q3", with: "").replacingOccurrences(of: "Q4", with: "")
            .filter(\.isNumber)
        #expect(digits == "1")
    }

    @Test func amountOnShowsExactlyOneExactAmount() throws {
        let card = StreakShareCard(overview: try streakOverview(), amountSaved: Money(cents: 158_000), now: sampleNow, calendar: calendar)
        #expect(card.amountLine == "$1,580.00 saved in goals")
        let text = card.strings.joined(separator: " ")
        #expect(text.components(separatedBy: "$").count == 2)
        #expect(text.contains("$1,580.00"))
        #expect(card.spokenValue == "1 week so far. 1,580.00 US dollars saved in goals. 2026 badges: none collected yet.")
    }

    @Test func spokenValueWithBadges() throws {
        let earned: (inout [String: Any]) -> Void = { object in
            object["badgeProgress"] = ["earnedQuarters": 1, "nextTier": "bronze", "pct": 0.2, "daysToNext": 70]
        }
        let one = try streakOverview(combine(hero(13), earned, { $0["badges"] = [badgeObject(2026, 2)] }))
        let oneCard = StreakShareCard(overview: one, amountSaved: nil, now: sampleNow, calendar: calendar)
        #expect(oneCard.monthsLine == "3 months of saving")
        #expect(oneCard.tierWord == "Bronze saver")
        #expect(oneCard.spokenValue == "13 weeks in a row. 3 months of saving. Bronze saver. 2026 badges: Q2 collected.")

        let two = try streakOverview(combine(hero(13), earned, { $0["badges"] = [badgeObject(2026, 1), badgeObject(2026, 2)] }))
        #expect(StreakShareCard(overview: two, amountSaved: nil, now: sampleNow, calendar: calendar).spokenValue
            == "13 weeks in a row. 3 months of saving. Bronze saver. 2026 badges: Q1 and Q2 collected.")

        let three = try streakOverview(combine(hero(13), { $0["badges"] = [badgeObject(2025, 4), badgeObject(2026, 1), badgeObject(2026, 2), badgeObject(2026, 3)] }))
        let threeCard = StreakShareCard(overview: three, amountSaved: nil, now: sampleNow, calendar: calendar)
        #expect(threeCard.tierWord == "Silver saver")
        #expect(threeCard.spokenValue == "13 weeks in a row. Silver saver. 2026 badges: Q1, Q2 and Q3 collected.")

        // Badges only in another year: the card's year has none.
        let lastYear = try streakOverview(combine(hero(13), { $0["badges"] = [badgeObject(2025, 4)] }))
        #expect(StreakShareCard(overview: lastYear, amountSaved: nil, now: sampleNow, calendar: calendar).spokenValue
            == "13 weeks in a row. Bronze saver. 2026 badges: none collected yet.")
    }
}
