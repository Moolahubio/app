import Foundation
import Testing
@testable import Domain

/// Redacted copies of `features/api-samples` (demo account, captured
/// 2026-10-25) in `Fixtures/`, with the fields the server added since where a
/// test needs them: the dashboard's `upcomingPayIn`, `targetMembers` and the
/// goals' `balanceUnavailable`.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    static func decode<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value {
        try APICoding.makeDecoder().decode(type, from: data(name))
    }

    /// The fixture as a JSON object, to change a field before decoding.
    static func object(_ name: String) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data(name)) as? [String: Any])
    }

    static func decode<Value: Decodable>(_ type: Value.Type, object: Any) throws -> Value {
        try APICoding.makeDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}

@Suite("API dates")
struct APIDateTests {
    @Test func parsesEveryShapeTheServerSends() throws {
        let withMillis = try #require(APIDate.parse("2026-10-23T03:13:00.123Z"))
        let plain = try #require(APIDate.parse("2026-10-23T03:13:00Z"))
        #expect(withMillis.timeIntervalSince(plain) > 0.12 && withMillis.timeIntervalSince(plain) < 0.124)
        let offset = try #require(APIDate.parse("2026-10-23T04:13:00+01:00"))
        #expect(offset == plain)
        let spaced = try #require(APIDate.parse("2026-10-23 03:13:00Z"))
        #expect(spaced == plain)
        let day = try #require(APIDate.parse("2027-03-01"))
        #expect(day == APIDate.parse("2027-03-01T00:00:00.000Z"))
    }

    @Test(arguments: ["", "garbage", "2026-02-31", "2026-13-01", "23/10/2026", "2026-1-1"])
    func rejectsNonsense(_ text: String) {
        #expect(APIDate.parse(text) == nil)
    }

    @Test func deadlineFormatsInUTC() {
        let deadline = APIDate.parse("2027-03-01T00:00:00.000Z")!
        let text = APIDate.formatUTCDay(deadline, locale: Locale(identifier: "en_GB"))
        #expect(text == "1 Mar 2027")
    }

    @Test func dayStringUsesTheGivenCalendar() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 2027-03-02 05:00 UTC is still 1 March in Los Angeles.
        let date = APIDate.parse("2027-03-02T05:00:00Z")!
        #expect(APIDate.dayString(from: date, calendar: calendar) == "2027-03-01")
    }
}

@Suite("DTO decoding")
struct DTODecodingTests {
    let decoder = APICoding.makeDecoder()

    @Test func goalWithHistory() throws {
        let json = """
        {"id":"g1","name":"Emergency fund","emoji":"☂️","color":"jade","targetCents":300000,"savedCents":125000,
         "balanceUnavailable":false,"deadline":"2027-03-01T00:00:00.000Z","frequency":"weekly","autoSaveCents":null,
         "createdAt":"2026-06-02T10:00:00.000Z","imageUrl":null,"onchain":false,"vaultAddress":null,"explorerUrl":null,
         "network":null,"feeBps":200,
         "history":[{"id":"h1","type":"goal_allocate","amountCents":5000,"txHash":null,"onchainStatus":"none","createdAt":"2026-10-01T09:00:00.000Z"}]}
        """
        let goal = try decoder.decode(Goal.self, from: Data(json.utf8))
        #expect(goal.icon == .emergencyFund)
        #expect(goal.saved == Money(cents: 125_000))
        #expect(goal.feeRate.percentText == "2%")
        #expect(goal.history?.first?.status == .done)
        #expect(goal.goalFrequency == .weekly)
    }

    @Test func dashboardIgnoresUnknownFieldsLikeYieldApy() throws {
        let json = """
        {"availableCents":152000,"totalCents":310000,"goalTotalCents":158000,"pendingCents":0,"balanceUnavailable":false,
         "circlePotCents":40000,"yieldApy":4.5,
         "recentActivity":[{"id":"a1","type":"deposit","description":"Test money added","amountCents":10000,"txHash":null,"onchainStatus":"none","createdAt":"2026-10-20T08:00:00.000Z"}],
         "activeGoals":[],"activeCircles":[],"lessonsCompleted":0,"totalLessons":12}
        """
        let summary = try decoder.decode(DashboardSummary.self, from: Data(json.utf8))
        #expect(summary.available.formatted() == "$1,520.00")
        #expect(summary.recentActivity.first?.kind == .deposit)
        #expect(summary.upcomingReminder == nil)
    }

    @Test func loginResultShapes() throws {
        let challenge = try decoder.decode(LoginResult.self, from: Data(#"{"twoFactorRequired":true,"challengeId":"c1"}"#.utf8))
        #expect(challenge.twoFactorRequired)
        #expect(challenge.user == nil)
        #expect(challenge.sessionToken == nil)

        let verify = try decoder.decode(LoginResult.self, from: Data(#"{"twoFactorRequired":false,"emailVerificationRequired":true,"email":"a@b.co"}"#.utf8))
        #expect(verify.emailVerificationRequired == true)
        #expect(verify.user == nil)

        let signedIn = try decoder.decode(LoginResult.self, from: Data(#"{"twoFactorRequired":false,"id":"u1","name":"Ama Owusu","email":"demo@moolahub.test","username":"ama","hasWallet":true,"sessionToken":"abc123"}"#.utf8))
        #expect(signedIn.user?.username == "ama")
        #expect(signedIn.sessionToken?.rawValue == "abc123")
    }

    @Test func twoFactorLoginResultCarriesUserAndToken() throws {
        let json = #"{"id":"u1","name":"Ama","email":"demo@moolahub.test","hasWallet":false,"sessionToken":"tok"}"#
        let result = try decoder.decode(TwoFactorLoginResult.self, from: Data(json.utf8))
        #expect(result.user.id == "u1")
        #expect(result.sessionToken?.rawValue == "tok")
    }

    @Test func secretsNeverPrint() throws {
        let token = SessionToken("super-secret-token")
        #expect(!String(describing: token).contains("super-secret"))
        #expect(!String(reflecting: token).contains("super-secret"))
        var dumped = ""
        dump(LoginInput(email: "a@b.co", password: "hunter22"), to: &dumped)
        #expect(!dumped.contains("hunter22"))
        // …but the request body carries the real value.
        let body = try JSONEncoder().encode(LoginInput(email: "a@b.co", password: "hunter22"))
        #expect(String(decoding: body, as: UTF8.self).contains("hunter22"))
    }

    @Test func circleInputBodies() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let takeTurns = CircleInput.takeTurns(name: "Family", contribution: Money(cents: 10_000), people: 4, frequency: .monthly, memberEmails: ["kofi@moolahub.test"])
        #expect(String(decoding: try encoder.encode(takeTurns), as: UTF8.self)
            == #"{"frequency":"monthly","groupSize":4,"memberEmails":["kofi@moolahub.test"],"name":"Family","targetPayoutCents":40000,"type":"rotation"}"#)
        let together = CircleInput.saveTogether(name: "Pot", contribution: Money(cents: 2_000), rounds: 6, frequency: .biweekly, memberEmails: [])
        #expect(String(decoding: try encoder.encode(together), as: UTF8.self)
            == #"{"contributionCents":2000,"frequency":"biweekly","memberEmails":[],"name":"Pot","numRounds":6,"type":"accumulation"}"#)
    }

    @Test func goalInputSendsEmojiAndJade() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let input = GoalInput(name: "Trip", icon: .travel, target: Money(cents: 120_000), deadline: "2027-03-01", frequency: .monthly)
        let json = String(decoding: try encoder.encode(input), as: UTF8.self)
        #expect(json == #"{"color":"jade","deadline":"2027-03-01","emoji":"\#u{2708}\#u{FE0F}","frequency":"monthly","name":"Trip","targetCents":120000}"#)
    }

    @Test func stepUpOmitsMissingTwoFactor() throws {
        let body = try JSONEncoder().encode(StepUpProof(currentPassword: "pw123456"))
        #expect(String(decoding: body, as: UTF8.self) == #"{"currentPassword":"pw123456"}"#)
    }
}

@Suite("Feature wave 1 DTOs")
struct WaveDTODecodingTests {
    @Test func dashboardFixtureCarriesTheNextPayIn() throws {
        let summary = try Fixture.decode(DashboardSummary.self, "GET_dashboard_summary")
        let payIn = try #require(summary.upcomingPayIn)
        #expect(payIn.circleName == "Family susu")
        #expect(payIn.amount == Money(cents: 10_000))
        #expect(payIn.amount.formatted() == "$100.00")
        #expect(payIn.round == 3)
        #expect(payIn.totalRounds == 4)
        #expect(summary.upcomingReminder?.amountCents == 1_000_000)
        #expect(summary.activeGoals.map(\.balanceUnavailable) == [false, false])
        #expect(summary.activeCircles.count == 3)
        #expect(summary.activeCircles.allSatisfy { $0.targetMembers == nil })
        #expect(summary.total.formatted() == "$3,030.12")
    }

    /// A server before B4 sends no key; today's server sends `null` when no
    /// pay-in is owed. Both mean no notice.
    @Test func absentOrNullNextPayInIsNil() throws {
        var object = try Fixture.object("GET_dashboard_summary")
        object["upcomingPayIn"] = NSNull()
        #expect(try Fixture.decode(DashboardSummary.self, object: object).upcomingPayIn == nil)
        object.removeValue(forKey: "upcomingPayIn")
        #expect(try Fixture.decode(DashboardSummary.self, object: object).upcomingPayIn == nil)
    }

    @Test func goalsFixtureCarriesThePerGoalFlag() throws {
        let goals = try Fixture.decode([Goal].self, "GET_goals")
        #expect(goals.map(\.name) == ["Emergency fund", "New laptop"])
        #expect(goals.map(\.balanceUnavailable) == [false, false])
        #expect(goals.map(\.saved) == [Money(cents: 125_000), Money(cents: 33_000)])
        #expect(goals.allSatisfy { $0.goalFrequency == .monthly })
    }

    @Test func lessonFixturesDecode() throws {
        let lessons = try Fixture.decode([LessonSummary].self, "GET_learn_lessons")
        #expect(lessons.count == 6)
        #expect(lessons.first?.slug == "what-is-a-susu")
        #expect(lessons.allSatisfy { !$0.completed })
        let lesson = try Fixture.decode(LessonDetail.self, "GET_learn_lessons_one")
        #expect(lesson.slug == "what-is-a-susu")
        #expect(lesson.body.count == 3)
        #expect(lesson.takeaways.count == 4)
    }

    @Test func profileTimeZoneIsOptional() throws {
        let decoder = APICoding.makeDecoder()
        let base = #""id":"u1","name":"Ama Owusu","email":"demo@moolahub.test","username":"ama","createdAt":"2026-06-05T03:29:24.928Z""#
        let withZone = try decoder.decode(UserProfile.self, from: Data(#"{\#(base),"timezone":"Africa/Accra"}"#.utf8))
        #expect(withZone.timezone == "Africa/Accra")
        let without = try decoder.decode(UserProfile.self, from: Data("{\(base)}".utf8))
        #expect(without.timezone == nil)
    }

    /// The time zone sender's body is the zone alone; Profile's Save never
    /// sends a zone.
    @Test func profileUpdateSendsOnlyWhatIsSet() throws {
        func body(_ update: ProfileUpdate) throws -> [String: String] {
            try #require(try JSONSerialization.jsonObject(with: APICoding.makeEncoder().encode(update)) as? [String: String])
        }
        #expect(try body(ProfileUpdate(timezone: "Africa/Accra")) == ["timezone": "Africa/Accra"])
        #expect(try body(ProfileUpdate(name: "Ama Owusu", username: "ama")) == ["name": "Ama Owusu", "username": "ama"])
    }

    @Test func referralSourceKeysAreTheServers() {
        #expect(ReferralSource.allCases.map(\.rawValue) == ["Twitter", "Telegram", "WhatsApp", "Discord", "LinkedIn", "Friends", "Others"])
    }

    @Test func registerInputSendsAReferralSourceOnlyWhenChosen() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let plain = RegisterInput(name: "Ama", username: "ama", email: "a@b.co", password: "pw123456", dateOfBirth: "2000-01-31")
        let plainJSON = String(decoding: try encoder.encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("referralSource"))
        #expect(!plainJSON.contains("referralCode"))
        let chosen = RegisterInput(
            name: "Ama", username: "ama", email: "a@b.co", password: "pw123456", dateOfBirth: "2000-01-31",
            referralSource: ReferralSource.telegram.rawValue
        )
        let chosenJSON = String(decoding: try encoder.encode(chosen), as: UTF8.self)
        #expect(chosenJSON.contains(#""referralSource":"Telegram""#))
        #expect(!chosenJSON.contains("referralCode"))
    }

    @Test func deleteAccountInputConfirmsAndOmitsMissingProof() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let password = DeleteAccountInput(proof: StepUpProof(currentPassword: "pw123456"))
        #expect(String(decoding: try encoder.encode(password), as: UTF8.self) == #"{"confirm":"DELETE","currentPassword":"pw123456"}"#)
        let codeOnly = DeleteAccountInput(proof: StepUpProof(currentPassword: nil, twoFactorCode: "123456"))
        let codeJSON = String(decoding: try encoder.encode(codeOnly), as: UTF8.self)
        #expect(codeJSON == #"{"confirm":"DELETE","twoFactorCode":"123456"}"#)
        #expect(!codeJSON.contains("reauthCode"))
    }
}
