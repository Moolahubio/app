import Domain
import Foundation
import Testing
@testable import APIClient

// Feature wave 1's endpoints (SPEC §8.2 item 3): streaks (streaks.md ST.1.1,
// ST.15.1 item 13), Mark as done (SPEC §3.4), closing the account
// (account.md §15), the time zone sender's body (SPEC §4.5), and the
// `X-MH-Test-Run` header (D-36).

private func makeClient(_ server: StubServer, testRunID: String? = nil) async -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = APIClient(
        baseURL: server.baseURL,
        clientInfo: .init(appVersion: "1.2.3", build: "45", testRunID: testRunID),
        configuration: configuration
    )
    await client.setSessionToken(SessionToken("t"))
    return client
}

/// The captured `GET /streaks` sample's shape.
private let streaksJSON = """
{"hero":{"count":1,"status":"active","commitmentName":null,"emoji":null},"frequency":"weekly","canChangeFrequency":true,
 "nextChangeYear":null,"currentPeriodEnd":"2026-10-26T00:00:00.000Z","currentPeriodSatisfied":true,"atRisk":false,
 "lifetimeBest":1,"totalPeriodsSaved":1,"commitments":[],"freezes":{"balance":1,"usedTotal":0},"badges":[],
 "badgeProgress":{"earnedQuarters":0,"nextTier":"bronze","pct":0.025,"daysToNext":90},"reminderOptIn":false,
 "vacation":{"active":false,"start":null,"end":null,"usedThisYear":false}}
"""

private func bodyText(_ request: RecordedRequest?) -> String? {
    request?.body.map { String(decoding: $0, as: UTF8.self) }
}

private func bodyObject(_ request: RecordedRequest?) throws -> [String: Any] {
    let body = try #require(request?.body)
    return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
}

@Suite("Streak endpoints")
struct StreakEndpointTests {
    @Test func overviewIsAPlainGet() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: streaksJSON))
        let client = await makeClient(server)

        let overview = try await client.send(API.Streaks.overview())
        #expect(overview.hero?.count == 1)
        #expect(overview.effectiveFrequency == .weekly)

        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "\(server.baseURL.absoluteString)/streaks")
        #expect(request.header("Content-Type") == nil)
        #expect(request.body == nil || request.body?.isEmpty == true)
    }

    @Test(arguments: StreakFrequency.allCases)
    func setFrequencySendsTheExactBody(_ frequency: StreakFrequency) async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: streaksJSON))
        let client = await makeClient(server)

        _ = try await client.send(API.Streaks.setFrequency(frequency))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/streaks/frequency")
        #expect(request.header("Content-Type") == "application/json")
        #expect(bodyText(request) == #"{"frequency":"\#(frequency.rawValue)"}"#)
    }

    /// `days` is an integer, never a string or a decimal, and always 1 to 30.
    @Test func startBreakSendsWholeDays() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: streaksJSON))
        let client = await makeClient(server)

        _ = try await client.send(API.Streaks.startBreak(days: StreakBreakDays(14)))
        _ = try await client.send(API.Streaks.startBreak(days: StreakBreakDays(45)))
        #expect(server.requests.map(\.url.path) == ["/api/streaks/vacation", "/api/streaks/vacation"])
        #expect(server.requests.map(\.method) == ["POST", "POST"])
        #expect(bodyText(server.requests.first) == #"{"days":14}"#)
        #expect(bodyText(server.requests.last) == #"{"days":30}"#)
    }

    @Test func endBreakSendsAnEmptyObject() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: streaksJSON))
        let client = await makeClient(server)

        _ = try await client.send(API.Streaks.endBreak())
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/streaks/vacation/end")
        #expect(request.header("Content-Type") == "application/json")
        #expect(bodyText(request) == "{}")
    }

    /// A 400 refusal is shown verbatim; nothing is retried.
    @Test func refusalsAreVerbatimAndNeverRetried() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 400, json: #"{"error":"You can change your streak frequency once per calendar year."}"#))
        let client = await makeClient(server)
        do throws(APIError) {
            _ = try await client.send(API.Streaks.setFrequency(.monthly))
            Issue.record("expected an error")
        } catch {
            #expect(error.message(for: .action) == "You can change your streak frequency once per calendar year.")
        }
        #expect(server.requests.count == 1)
    }
}

@Suite("Learn endpoints")
struct LearnEndpointTests {
    /// SPEC §3.4.
    @Test func completeSendsJSONAndDecodesOk() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"ok":true}"#))
        let client = await makeClient(server)

        let result = try await client.send(API.Learn.complete("what-is-a-susu"))
        #expect(result.ok)
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/learn/lessons/what-is-a-susu/complete")
        #expect(request.header("Content-Type") == "application/json")
        #expect(bodyText(request) == "{}")
    }

    @Test func slugIsOnePathSegment() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"ok":true}"#))
        let client = await makeClient(server)

        _ = try await client.send(API.Learn.complete("a/b?c"))
        let url = try #require(server.requests.first?.url)
        #expect(url.absoluteString == "\(server.baseURL.absoluteString)/learn/lessons/a%2Fb%3Fc/complete")
        #expect(url.query == nil)
    }
}

@Suite("Account endpoints")
struct AccountEndpointTests {
    @Test func deactivateSendsTheStepUpProof() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"ok":true}"#))
        let client = await makeClient(server)

        _ = try await client.send(API.Account.deactivate(StepUpProof(currentPassword: "pw123456")))
        _ = try await client.send(API.Account.deactivate(StepUpProof(currentPassword: nil, twoFactorCode: "123456")))
        #expect(server.requests.map(\.method) == ["POST", "POST"])
        #expect(server.requests.map(\.url.path) == ["/api/account/deactivate", "/api/account/deactivate"])
        #expect(server.requests.allSatisfy { $0.header("Content-Type") == "application/json" })
        #expect(bodyText(server.requests.first) == #"{"currentPassword":"pw123456"}"#)
        #expect(bodyText(server.requests.last) == #"{"twoFactorCode":"123456"}"#)
    }

    @Test func deleteSendsConfirmAndTheProofAsJSON() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"ok":true}"#))
        let client = await makeClient(server)

        let result = try await client.send(API.Account.delete(DeleteAccountInput(proof: StepUpProof(currentPassword: "pw123456", twoFactorCode: "123456"))))
        #expect(result.ok)
        let request = try #require(server.requests.first)
        #expect(request.method == "DELETE")
        #expect(request.url.path == "/api/account")
        #expect(request.header("Content-Type") == "application/json")
        let body = try bodyObject(request)
        #expect(body.count == 3)
        #expect(body["confirm"] as? String == "DELETE")
        #expect(body["currentPassword"] as? String == "pw123456")
        #expect(body["twoFactorCode"] as? String == "123456")
    }

    /// The server's 409 sentences are never shown on iOS (account.md AC-D3),
    /// but the error keeps its status for the screen to re-check; one attempt.
    @Test func deleteRefusalIsOneAttempt() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 409, json: #"{"error":"Release your active goals first."}"#))
        let client = await makeClient(server)
        do throws(APIError) {
            _ = try await client.send(API.Account.delete(DeleteAccountInput(proof: StepUpProof(currentPassword: "pw123456"))))
            Issue.record("expected an error")
        } catch {
            #expect(error == .rejected(status: 409, message: "Release your active goals first."))
        }
        #expect(server.requests.count == 1)
    }
}

@Suite("Time zone body")
struct TimeZoneBodyTests {
    /// SPEC §4.5: `PATCH /profile` with exactly `{"timezone":"<IANA id>"}`.
    @Test func profileUpdateWithOnlyTheZone() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"id":"u1","name":"Ama Owusu","email":"demo@moolahub.test","createdAt":"2026-06-05T03:29:24.928Z","timezone":"Africa/Accra"}"#))
        let client = await makeClient(server)

        let profile = try await client.send(API.Profile.update(ProfileUpdate(timezone: "Africa/Accra")))
        #expect(profile.timezone == "Africa/Accra")
        let request = try #require(server.requests.first)
        #expect(request.method == "PATCH")
        #expect(request.url.path == "/api/profile")
        // JSONEncoder writes "/" as "\/"; the parsed body is the zone alone.
        #expect(try bodyObject(request) as? [String: String] == ["timezone": "Africa/Accra"])
    }
}

/// D-36: a Debug build launched for a counted UI test marks every request.
@Suite("X-MH-Test-Run")
struct TestRunHeaderTests {
    @Test func sentOnEveryRequestWhenSet() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: streaksJSON))
        server.enqueue(.http(status: 200, json: streaksJSON))
        server.enqueue(.http(status: 200, json: #"{"status":"ok"}"#))
        let client = await makeClient(server, testRunID: "run-2026-10-27-a1")

        _ = try await client.send(API.Streaks.overview())
        _ = try await client.send(API.Streaks.endBreak())
        _ = try await client.send(API.Health.check())
        #expect(server.requests.count == 3)
        #if DEBUG
        #expect(server.requests.allSatisfy { $0.header("X-MH-Test-Run") == "run-2026-10-27-a1" })
        #else
        #expect(server.requests.allSatisfy { $0.header("X-MH-Test-Run") == nil })
        #endif
    }

    @Test func absentWhenNil() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: streaksJSON))
        let client = await makeClient(server)

        _ = try await client.send(API.Streaks.overview())
        _ = try await client.send(API.Streaks.endBreak())
        #expect(server.requests.count == 2)
        #expect(server.requests.allSatisfy { $0.header("X-MH-Test-Run") == nil })
    }
}
