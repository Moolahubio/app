import Foundation
import Testing
@testable import Domain

private var utcCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func utc(_ text: String) -> Date {
    APIDate.parse(text)!
}

/// The capture day of the samples.
private let sampleNow = utc("2026-10-25T12:00:00.000Z")

/// A goal from `GET_goals.json` (0 Emergency fund, 1 New laptop) with fields
/// replaced; `flag: .some(nil)` removes `balanceUnavailable` (a server before
/// C14).
private func goal(_ index: Int = 0, saved: Int64? = nil, flag: Bool?? = nil) throws -> Goal {
    let data = try Fixture.data("GET_goals")
    let goals = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    var object = goals[index]
    if let saved { object["savedCents"] = saved }
    switch flag {
    case .none: break
    case .some(.none): object.removeValue(forKey: "balanceUnavailable")
    case .some(.some(let value)): object["balanceUnavailable"] = value
    }
    return try Fixture.decode(Goal.self, object: object)
}

@Suite("GoalRowFigure")
struct GoalRowFigureTests {
    @Test func perGoalFalseIsShownWhateverTheSummarySays() throws {
        for summaryStale in [false, true] {
            for saved: Int64 in [0, 125_000] {
                #expect(GoalRowFigure.state(goal: try goal(saved: saved, flag: false), summaryStale: summaryStale) == .shown)
            }
        }
    }

    /// AC-10 and AC-11: the per-goal flag decides, even with a non-zero figure.
    @Test func perGoalTrueIsUnknownWhateverTheFigure() throws {
        for summaryStale in [false, true] {
            for saved: Int64 in [0, 1_250] {
                #expect(GoalRowFigure.state(goal: try goal(saved: saved, flag: true), summaryStale: summaryStale) == .unknown)
            }
        }
    }

    /// AC-13: no per-goal key and a stale summary.
    @Test func absentFlagWithAStaleSummary() throws {
        #expect(GoalRowFigure.state(goal: try goal(saved: 125_000, flag: .some(nil)), summaryStale: true) == .shownStale)
        #expect(GoalRowFigure.state(goal: try goal(saved: 0, flag: .some(nil)), summaryStale: true) == .unknown)
    }

    /// The summary not stale, absent, failed or not loaded yet: the caller
    /// passes false.
    @Test func absentFlagWithoutAStaleSummaryIsShown() throws {
        #expect(GoalRowFigure.state(goal: try goal(saved: 125_000, flag: .some(nil)), summaryStale: false) == .shown)
        #expect(GoalRowFigure.state(goal: try goal(saved: 0, flag: .some(nil)), summaryStale: false) == .shown)
    }
}

/// savings-groups §12.1 `GoalNextStepTests`.
@Suite("GoalNextStep")
struct GoalNextStepTests {
    @Test func emergencyFundIsStep7Of10() throws {
        let fund = try goal(0)
        let line = try #require(GoalNextStep.line(goal: fund, figure: .shown, now: sampleNow, calendar: utcCalendar))
        #expect(line.kind == .next(Money(cents: 38_182), .monthly))
        let periods = ContributionPlan.periodsBetween(fund.createdAt, fund.deadline, frequency: .monthly, calendar: utcCalendar)
        let plan = ContributionPlan.progressivePlan(targetCents: fund.targetCents, periods: periods)
        let next = try #require(ContributionPlan.nextContribution(plan: plan, savedCents: fund.savedCents))
        #expect(next.index == 7)
        #expect(next.total == 10)
        #expect(line.rowText == "Next\u{00A0}$381.82 this\u{00A0}month")
        #expect(line.tileText == "Next\u{00A0}$381.82")
        #expect(line.spoken == "Next step 381.82 US dollars this month.")
    }

    @Test func newLaptopIsStep4Of7() throws {
        let laptop = try goal(1)
        let line = try #require(GoalNextStep.line(goal: laptop, figure: .shown, now: sampleNow, calendar: utcCalendar))
        #expect(line.kind == .next(Money(cents: 17_142), .monthly))
        let periods = ContributionPlan.periodsBetween(laptop.createdAt, laptop.deadline, frequency: .monthly, calendar: utcCalendar)
        let plan = ContributionPlan.progressivePlan(targetCents: laptop.targetCents, periods: periods)
        let next = try #require(ContributionPlan.nextContribution(plan: plan, savedCents: laptop.savedCents))
        #expect(next.index == 4)
        #expect(next.total == 7)
        #expect(line.rowText == "Next\u{00A0}$171.42 this\u{00A0}month")
    }

    @Test func reachedHasNoNextLine() throws {
        #expect(GoalNextStep.line(goal: try goal(saved: 300_000), figure: .shown, now: sampleNow, calendar: utcCalendar) == nil)
        #expect(GoalNextStep.line(goal: try goal(saved: 300_001), figure: .shown, now: sampleNow, calendar: utcCalendar) == nil)
    }

    @Test func pastTheTargetDateIsToGo() throws {
        let line = try #require(GoalNextStep.line(goal: try goal(), figure: .shown, now: utc("2027-05-01T00:00:00.000Z"), calendar: utcCalendar))
        #expect(line.kind == .toGo(Money(cents: 175_000)))
        #expect(line.rowText == "$1,750 to go")
        #expect(line.tileText == "$1,750 to go")
        #expect(line.spoken == "1,750.00 US dollars to go.")
        let cents = try #require(GoalNextStep.line(goal: try goal(saved: 124_950), figure: .shown, now: utc("2027-05-01T00:00:00.000Z"), calendar: utcCalendar))
        #expect(cents.rowText == "$1,750.50 to go")
    }

    @Test func onlyShownFiguresHaveANextLine() throws {
        #expect(GoalNextStep.line(goal: try goal(), figure: .shownStale, now: sampleNow, calendar: utcCalendar) == nil)
        #expect(GoalNextStep.line(goal: try goal(), figure: .unknown, now: sampleNow, calendar: utcCalendar) == nil)
    }

    /// U+00A0 after "Next", and between "this" and the period word (W10-SG-05).
    @Test func noBreakSpacesForEveryFrequency() {
        let amount = Money(cents: 2_500)
        #expect(GoalNextLine(.next(amount, .daily)).rowText == "Next\u{00A0}$25.00 today")
        #expect(GoalNextLine(.next(amount, .weekly)).rowText == "Next\u{00A0}$25.00 this\u{00A0}week")
        #expect(GoalNextLine(.next(amount, .monthly)).rowText == "Next\u{00A0}$25.00 this\u{00A0}month")
        #expect(GoalNextLine(.next(amount, .weekly)).tileText == "Next\u{00A0}$25.00")
        #expect(GoalNextLine(.next(amount, .daily)).spoken == "Next step 25.00 US dollars today.")
        #expect(GoalNextLine(.next(amount, .weekly)).spoken == "Next step 25.00 US dollars this week.")
    }
}

/// W10-SG-07 and W10-SG-23's figure values (SPEC §5.1), the words GoalCard
/// draws and reads (CP2-04).
@Suite("GoalWords.figureSpoken")
struct GoalFigureSpokenTests {
    private let saved = Money(cents: 125_000)
    private let target = Money(cents: 300_000)

    @Test func shownReadsTheFigureThePercentAndThePace() {
        #expect(GoalWords.figureSpoken(.shown, saved: saved, target: target, pace: .onTrack)
            == "1,250.00 US dollars saved of 3,000.00 US dollars. 41 percent. On track.")
    }

    @Test func staleKeepsTheTestedPrefixAndSaysMayBeOutOfDate() {
        #expect(GoalWords.figureSpoken(.shownStale, saved: saved, target: target, pace: .onTrack)
            == "1,250.00 US dollars saved of 3,000.00 US dollars. 41 percent. May be out of date.")
    }

    @Test func unknownReadsNoFigureAndNoPercent() {
        let spoken = GoalWords.figureSpoken(.unknown, saved: Money(cents: 0), target: target, pace: .onTrack)
        #expect(spoken == "Saved amount unavailable. Target 3,000.00 US dollars.")
        #expect(spoken.hasPrefix(GoalWords.savedAmountUnavailable))
        #expect(!spoken.contains("percent"))
    }

    @Test func theDrawnWordsAreTheW10Rows() {
        #expect(GoalWords.savedAmountUnavailable == "Saved amount unavailable")
        #expect(GoalWords.mayBeOutOfDate == "May be out of date")
    }
}

/// W10-SG-23's target date. These tests set the process's system time zone
/// (`TZ`, as a UI test launch does), so they run one at a time and restore it;
/// no other DomainTests test reads the device zone.
@Suite("GoalWords.targetDateSpoken", .serialized)
struct GoalTargetDateSpokenTests {
    @Test(arguments: ["America/New_York", "Pacific/Auckland"])
    func isTheUTCCalendarDayInEveryDeviceZone(_ zone: String) throws {
        let previous = getenv("TZ").map { String(cString: $0) }
        setenv("TZ", zone, 1)
        NSTimeZone.resetSystemTimeZone()
        defer {
            if let previous { setenv("TZ", previous, 1) } else { unsetenv("TZ") }
            NSTimeZone.resetSystemTimeZone()
        }
        try #require(TimeZone.current.identifier == zone)

        let deadline = utc("2027-04-21T00:00:00.000Z")
        #expect(GoalWords.targetDateSpoken(deadline, locale: Locale(identifier: "en_US")) == "Target date April 21, 2027.")
    }
}
