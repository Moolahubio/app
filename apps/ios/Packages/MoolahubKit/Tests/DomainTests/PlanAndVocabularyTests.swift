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

// The web's contribution-plan.ts has no test file; these pin the port's
// behaviour to the web algorithm's documented properties.
@Suite("Contribution plan (port of contribution-plan.ts)")
struct ContributionPlanTests {
    @Test func planSumsExactlyToTargetAndNeverDecreases() {
        for target in [Int64(0), 1, 7, 99, 100_000, 300_000, 123_457, 999_999_999] {
            for periods in [1, 2, 3, 7, 26, 52, 520] {
                let plan = ContributionPlan.progressivePlan(targetCents: target, periods: periods)
                #expect(plan.count == periods)
                #expect(plan.reduce(0, +) == target)
                #expect(zip(plan, plan.dropFirst()).allSatisfy { $0 <= $1 })
            }
        }
    }

    @Test func knownSchedule() {
        // target 1000, n = 4: floor(1000·2i/20) = 100, 200, 300, 400.
        #expect(ContributionPlan.progressivePlan(targetCents: 1000, periods: 4) == [100, 200, 300, 400])
        // target 10, n = 3: floor(10·2i/12) = 1, 3, 5 (sum 9); remainder 1 to the last.
        #expect(ContributionPlan.progressivePlan(targetCents: 10, periods: 3) == [1, 3, 6])
        #expect(ContributionPlan.progressivePlan(targetCents: 500, periods: 1) == [500])
        #expect(ContributionPlan.progressivePlan(targetCents: -5, periods: 3) == [0, 0, 0])
    }

    @Test func periodsBetween() {
        let start = utc("2026-01-01T00:00:00.000Z")
        #expect(ContributionPlan.periodsBetween(start, utc("2026-01-11T00:00:00.000Z"), frequency: .daily, calendar: utcCalendar) == 10)
        #expect(ContributionPlan.periodsBetween(start, utc("2026-01-11T12:00:00.000Z"), frequency: .daily, calendar: utcCalendar) == 11) // 10.5 rounds up
        #expect(ContributionPlan.periodsBetween(start, utc("2026-04-01T00:00:00.000Z"), frequency: .weekly, calendar: utcCalendar) == 13) // 90 days / 7 = 12.86
        #expect(ContributionPlan.periodsBetween(start, utc("2026-07-31T00:00:00.000Z"), frequency: .monthly, calendar: utcCalendar) == 6)
        #expect(ContributionPlan.periodsBetween(start, start, frequency: .weekly, calendar: utcCalendar) == 1)
        #expect(ContributionPlan.periodsBetween(start, utc("2025-01-01T00:00:00.000Z"), frequency: .daily, calendar: utcCalendar) == 1)
        #expect(ContributionPlan.periodsBetween(start, utc("2036-01-01T00:00:00.000Z"), frequency: .daily, calendar: utcCalendar) == ContributionPlan.maxPeriods)
    }

    @Test func nextContribution() {
        let plan: [Int64] = [100, 200, 300, 400]
        let first = ContributionPlan.nextContribution(plan: plan, savedCents: 0)
        #expect(first == .init(index: 1, total: 4, amountCents: 100, cumulativeAfterCents: 100))
        let third = ContributionPlan.nextContribution(plan: plan, savedCents: 300)
        #expect(third?.index == 3)
        #expect(third?.amountCents == 300)
        #expect(ContributionPlan.nextContribution(plan: plan, savedCents: 1000) == nil)
    }

    @Test func buildGoalPlanFirstAndLast() {
        let plan = ContributionPlan.buildGoalPlan(
            targetCents: 10, start: utc("2026-01-01T00:00:00Z"), deadline: utc("2026-01-04T00:00:00Z"),
            frequency: .daily, calendar: utcCalendar
        )
        #expect(plan.periods == 3)
        #expect(plan.firstCents == 1)
        #expect(plan.lastCents == 6)
    }

    @Test func unknownFrequencyIsWeekly() {
        #expect(GoalFrequency(apiValue: "fortnightly") == .weekly)
        #expect(GoalFrequency(apiValue: nil) == .weekly)
        #expect(GoalFrequency(apiValue: "monthly") == .monthly)
    }
}

@Suite("Goal pace (PlanPill)")
struct GoalPaceTests {
    let created = utc("2026-01-01T00:00:00.000Z")
    let deadline = utc("2026-01-29T00:00:00.000Z") // 4 weeks: plan [1000, 2000, 3000, 4000] for 10,000

    @Test func reachedBeatsEverything() {
        let pace = GoalPace.evaluate(targetCents: 10_000, savedCents: 10_000, createdAt: created, deadline: deadline,
                                     frequency: .weekly, now: utc("2027-01-01T00:00:00Z"), calendar: utcCalendar)
        #expect(pace == .reached)
        #expect(pace.label == "Goal reached")
    }

    @Test func pastTargetDate() {
        let pace = GoalPace.evaluate(targetCents: 10_000, savedCents: 0, createdAt: created, deadline: deadline,
                                     frequency: .weekly, now: utc("2026-02-01T00:00:00Z"), calendar: utcCalendar)
        #expect(pace == .pastTargetDate)
    }

    @Test func onTrackAtStart() {
        let pace = GoalPace.evaluate(targetCents: 10_000, savedCents: 0, createdAt: created, deadline: deadline,
                                     frequency: .weekly, now: utc("2026-01-03T00:00:00Z"), calendar: utcCalendar)
        #expect(pace == .onTrack)
    }

    @Test func behindByWeeks() {
        // 15 days in: 2 whole weeks elapsed, 1 step done (1000 ≤ 1500 < 3000).
        let pace = GoalPace.evaluate(targetCents: 10_000, savedCents: 1_500, createdAt: created, deadline: deadline,
                                     frequency: .weekly, now: utc("2026-01-16T00:00:00Z"), calendar: utcCalendar)
        #expect(pace == .behind(periods: 1, frequency: .weekly))
        #expect(pace.label == "1 week behind")
        #expect(GoalPace.behind(periods: 3, frequency: .daily).label == "3 days behind")
        #expect(GoalPace.behind(periods: 2, frequency: .monthly).label == "2 months behind")
    }
}

@Suite("Vocabulary mappings")
struct VocabularyTests {
    @Test func goalIconMatchesWithOrWithoutVariationSelector() {
        #expect(GoalIcon(emoji: "\u{2708}\u{FE0F}") == .travel)
        #expect(GoalIcon(emoji: "\u{2708}") == .travel)
        #expect(GoalIcon(emoji: "\u{1F3E0}") == .home)
        #expect(GoalIcon(emoji: "\u{1F984}") == .goal) // unicorn from the web
        #expect(GoalIcon(emoji: nil) == .goal)
        #expect(Set(GoalIcon.allCases.map(\.emoji)).count == 12)
    }

    @Test func moveStatusNeverGuessesDone() {
        #expect(MoveStatus(onchainStatus: "none") == .done)
        #expect(MoveStatus(onchainStatus: "confirmed") == .done)
        #expect(MoveStatus(onchainStatus: "pending") == .processing)
        #expect(MoveStatus(onchainStatus: "failed") == .failed)
        #expect(MoveStatus(onchainStatus: "something-new") == .processing)
        #expect(MoveStatus(onchainStatus: nil) == .processing)
    }

    @Test func activityKinds() {
        #expect(ActivityKind(type: "goal_allocate") == .goalAllocate)
        #expect(ActivityKind(type: "yield").spokenWord == "Earnings")
        #expect(ActivityKind(type: "referral_withdrawal") == .inviteReward)
        #expect(ActivityKind(type: "brand_new").symbolName == "arrow.left.arrow.right")
    }

    /// One symbol per meaning (DESIGN.md v2 A7.3, W9.4).
    @Test func activityKindSymbolsFollowW94() {
        #expect(ActivityKind(type: "deposit").symbolName == "plus.circle")
        #expect(ActivityKind(type: "contribution").symbolName == "arrow.turn.up.right")
        #expect(ActivityKind(type: "goal_allocate").symbolName == "tray.and.arrow.down")
        #expect(ActivityKind(type: "goal_release").symbolName == "tray.and.arrow.up")
        #expect(ActivityKind(type: "payout").symbolName == "arrow.down.left")
        #expect(ActivityKind(type: "withdrawal").symbolName == "arrow.up.right")
        #expect(ActivityKind(type: "fee").symbolName == "percent")
        #expect(ActivityKind(type: "referral_earning").symbolName == "gift")
    }

    /// Tab symbols each have a `.fill` variant (DESIGN.md v2 A7.2).
    @Test func tabSymbolsFollowA72() {
        #expect(AppTab.allCases.map(\.symbolName) == ["house", "flag", "person.3", "list.bullet.rectangle.portrait", "person.crop.circle"])
        #expect(AppTab.allCases.map(\.title) == ["Home", "Savings", "Groups", "Activity", "Account"])
    }

    @Test func groupVocabulary() {
        #expect(GroupKind(apiValue: "accumulation") == .saveTogether)
        #expect(GroupKind(apiValue: "rotation") == .takeTurns)
        #expect(GroupKind(apiValue: "anything") == .takeTurns)
        #expect(GroupFrequency(apiValue: "biweekly")?.word == "every 2 weeks")
        #expect(GroupStatus(apiValue: "forming") == .forming)
    }

    @Test func validationMirrorsTheServer() {
        #expect(Validation.isValidUsername("ama_owusu"))
        #expect(!Validation.isValidUsername("am"))
        #expect(!Validation.isValidUsername("ama-owusu"))
        #expect(!Validation.isValidUsername("amá"))
        #expect(!Validation.isValidUsername(String(repeating: "a", count: 31)))
        #expect(Validation.isValidEmail(" Demo@MoolaHub.test "))
        #expect(!Validation.isValidEmail("demo@moolahub"))
        #expect(!Validation.isValidEmail("demo@@moolahub.test"))
        #expect(!Validation.isValidEmail("de mo@moolahub.test"))
        #expect(!Validation.isValidEmail("demo@.test"))
        #expect(Validation.isValidEmail("a@b.c"))
        #expect(Validation.isValidPassword("12345678"))
        #expect(!Validation.isValidPassword("1234567"))
        #expect(Validation.isSixDigitCode("123456"))
        #expect(!Validation.isSixDigitCode("12345a"))
    }

    @Test func firstName() {
        let user = AuthUser(id: "1", name: "Ama Owusu", email: "demo@moolahub.test")
        #expect(user.firstName == "Ama")
        #expect(AuthUser(id: "1", name: "  ", email: "x@y.z").firstName == "")
    }

    @Test func memberIsCurrentUser() throws {
        let json = #"{"id":"m1","name":"ama","payoutRound":2,"state":"upcoming","paidOut":false}"#
        let member = try APICoding.makeDecoder().decode(CircleMember.self, from: Data(json.utf8))
        #expect(member.isCurrentUser(username: "Ama"))
        #expect(!member.isCurrentUser(username: nil))
        #expect(member.payoutState == .upcoming)
    }
}
