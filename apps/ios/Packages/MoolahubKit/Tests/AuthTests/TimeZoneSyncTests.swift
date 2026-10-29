import APIClient
@testable import Auth
import Domain
import Foundation
import Testing

// The time zone sender (SPEC §4.5; account.md §12 and §17 item 7, streaks.md
// ST.1.5): one PATCH per change, stored only when echoed, nothing stored on a
// failure, no request while one is in flight, nothing sent while signed out.
// Serialized: the zone change test posts a process-wide notification.

@MainActor
@Suite("TimeZoneSync", .serialized, .timeLimit(.minutes(1)))
struct TimeZoneSyncTests {
    // MARK: Helpers

    /// `PATCH /profile`'s answer (`UserProfile`); `timezone` absent when nil,
    /// as a server before C3 answers.
    private static func profileJSON(timezone: String?) -> String {
        let zone = timezone.map { #","timezone":"\#($0)""# } ?? ""
        return #"{"id":"user-a","name":"Ama Owusu","email":"demo@moolahub.test","username":"ama","createdAt":"2026-06-05T03:29:24.928Z","language":"en"\#(zone)}"#
    }

    private static func echo(_ zone: String) -> StubReply {
        .http(status: 200, json: profileJSON(timezone: zone))
    }

    private func profile(timezone: String?) throws -> UserProfile {
        try APICoding.makeDecoder().decode(UserProfile.self, from: Data(Self.profileJSON(timezone: timezone).utf8))
    }

    private func patches(_ env: AuthTestEnvironment) -> [RecordedRequest] {
        env.requests("PATCH", "/profile")
    }

    /// A PATCH's parsed body (JSONEncoder writes "/" as "\/").
    private func body(_ request: RecordedRequest) throws -> [String: String] {
        let data = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func stored(_ env: AuthTestEnvironment, for userID: String = "user-a") -> String? {
        env.defaults.string(forKey: PerUserKeys.timeZoneSent(userID: userID))
    }

    /// Posts the system's zone change off the main thread, as the system
    /// does; the observer runs on the main queue.
    private func postSystemTimeZoneChange() async {
        await Task.detached {
            NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        }.value
    }

    // MARK: Sends once per change

    @Test func sendsOncePerChange() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [Self.echo("Africa/Accra"), Self.echo("Europe/London")])

        await env.timeZoneSync.sync()
        #expect(patches(env).count == 1)
        #expect(try body(patches(env)[0]) == ["timezone": "Africa/Accra"])
        #expect(stored(env) == "Africa/Accra")

        // Later triggers in the same zone send nothing.
        await env.timeZoneSync.sync()
        await env.timeZoneSync.sync()
        #expect(patches(env).count == 1)

        // The device moves: one PATCH with the new zone alone, then nothing.
        env.deviceTimeZone.identifier = "Europe/London"
        await env.timeZoneSync.sync()
        await env.timeZoneSync.sync()
        #expect(patches(env).count == 2)
        #expect(try body(patches(env)[1]) == ["timezone": "Europe/London"])
        #expect(stored(env) == "Europe/London")
        // Sign-in's two requests and the two PATCHes, nothing else.
        #expect(env.server.requests.count == 4)
    }

    /// AC-26: a second launch in the same zone sends nothing; the key is
    /// what survives the launch.
    @Test func aSecondLaunchInTheSameZoneSendsNothing() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [Self.echo("Africa/Accra")])
        await env.timeZoneSync.sync()
        #expect(patches(env).count == 1)

        let relaunched = TimeZoneSync(api: env.api, session: env.session, defaults: env.defaults, currentIdentifier: { "Africa/Accra" })
        await relaunched.sync()
        #expect(patches(env).count == 1)
    }

    /// The key is per user: another user on the same device sends their own.
    @Test func eachUserSendsTheirOwnZone() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            Self.echo("Africa/Accra"),
            .http(status: 200, json: #"{"ok":true}"#),
            .http(status: 200, json: TestUser.other.loginJSON),
            .http(status: 200, json: TestUser.other.meJSON),
            Self.echo("Africa/Accra"),
        ])
        await env.timeZoneSync.sync()
        await env.session.signOut()
        _ = try await env.session.signIn(email: TestUser.other.email, password: "not-a-real-password")
        #expect(env.session.currentUser?.id == "user-b")

        await env.timeZoneSync.sync()
        #expect(patches(env).count == 2)
        #expect(stored(env, for: "user-a") == "Africa/Accra")
        #expect(stored(env, for: "user-b") == "Africa/Accra")
    }

    /// Trigger 3: the system zone change sends only while signed in and the
    /// scene is active.
    @Test func aSystemZoneChangeSendsWhileTheSceneIsActive() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [Self.echo("Africa/Accra"), Self.echo("Europe/London")])
        await env.timeZoneSync.sync()
        env.deviceTimeZone.identifier = "Europe/London"

        env.timeZoneSync.isSceneActive = false
        await postSystemTimeZoneChange()
        await settle()
        #expect(patches(env).count == 1)

        env.timeZoneSync.isSceneActive = true
        await postSystemTimeZoneChange()
        await yieldUntil { stored(env) == "Europe/London" }
        #expect(patches(env).count == 2)
        #expect(try body(patches(env)[1]) == ["timezone": "Europe/London"])
    }

    // MARK: Stores only an echoed value

    @Test func storesOnlyAnEchoedValue() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            // A server before C3 answers without `timezone`; another kept its own.
            .http(status: 200, json: Self.profileJSON(timezone: nil)),
            Self.echo("UTC"),
            Self.echo("Africa/Accra"),
        ])

        await env.timeZoneSync.sync()
        #expect(patches(env).count == 1)
        #expect(stored(env) == nil)

        await env.timeZoneSync.sync()
        #expect(patches(env).count == 2)
        #expect(stored(env) == nil)

        await env.timeZoneSync.sync()
        #expect(patches(env).count == 3)
        #expect(stored(env) == "Africa/Accra")

        await env.timeZoneSync.sync()
        #expect(patches(env).count == 3)
    }

    // MARK: Failures store nothing

    /// A 400 ("That time zone isn't supported."), a 500 and a dropped
    /// connection: one request each (no retry loop), nothing stored, still
    /// signed in; the next trigger tries again.
    @Test func a400Or500StoresNothing() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            .http(status: 400, json: #"{"error":"That time zone isn't supported."}"#),
            .http(status: 500, json: #"{"error":"Internal server error"}"#),
            .failure(.notConnectedToInternet),
            Self.echo("Africa/Accra"),
        ])

        for expected in 1...3 {
            await env.timeZoneSync.sync()
            #expect(patches(env).count == expected)
            #expect(stored(env) == nil)
            #expect(!env.timeZoneSync.isSyncing)
        }
        #expect(env.session.isSignedIn)

        await env.timeZoneSync.sync()
        #expect(patches(env).count == 4)
        #expect(stored(env) == "Africa/Accra")
    }

    // MARK: At most one in flight

    @Test func noRequestWhileOneIsInFlight() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [Self.echo("Africa/Accra")])
        let sync = env.timeZoneSync

        let first = Task { await sync.sync() }
        await yieldUntil { sync.isSyncing }
        // Holding the main actor until the server has the PATCH, so its
        // answer can't land before the triggers below.
        blockUntil { !patches(env).isEmpty }

        // Triggers while it runs, in the same zone and in another: ignored.
        await sync.sync()
        env.deviceTimeZone.identifier = "Europe/London"
        await sync.sync()
        env.deviceTimeZone.identifier = "Africa/Accra"
        #expect(patches(env).count == 1)

        await first.value
        #expect(!sync.isSyncing)
        #expect(stored(env) == "Africa/Accra")
        await settle()
        #expect(patches(env).count == 1)
    }

    /// An answer that lands after the account closed leaves no key behind
    /// (a deletion removes the user's keys first).
    @Test(arguments: [SignedOutReason.accountDeleted, .accountDeactivated])
    func anAnswerAfterTheSessionEndedStoresNothing(reason: SignedOutReason) async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }
        try await env.signIn(.demo)
        let gate = FetchGate<UserProfile>()
        let sync = TimeZoneSync(session: env.session, defaults: env.defaults, currentIdentifier: { "Africa/Accra" }) { update in
            #expect(update.timezone == "Africa/Accra" && update.name == nil && update.username == nil)
            return try await gate.fetch()
        }

        let running = Task { await sync.sync() }
        await gate.waitForCalls(1)
        await env.session.endSessionAfterAccountClosed(reason)
        await gate.answer(call: 1, with: try profile(timezone: "Africa/Accra"))
        await running.value

        #expect(stored(env) == nil)
        #expect(!sync.isSyncing)
    }

    // MARK: Nothing sent while signed out

    @Test func nothingSentWhileSignedOut() async throws {
        let env = AuthTestEnvironment(timeZone: "Africa/Accra")
        defer { env.tearDown() }

        // Before any sign-in.
        await env.timeZoneSync.sync()
        #expect(env.server.requests.isEmpty)

        // After a sign-out, by every trigger, even with the zone changed.
        try await env.signIn(.demo, then: [.http(status: 200, json: #"{"ok":true}"#)])
        await env.session.signOut()
        let afterSignOut = env.server.requests.count
        env.deviceTimeZone.identifier = "Europe/London"
        await env.timeZoneSync.sync()
        env.timeZoneSync.isSceneActive = true
        await postSystemTimeZoneChange()
        await settle()

        #expect(env.server.requests.count == afterSignOut)
        #expect(patches(env).isEmpty)
        #expect(stored(env) == nil)
    }

    // MARK: Profile never sends a zone (account.md §12, AC-26)

    /// Each `ProfileUpdate(…)` call in `text`, as its argument text. Calls
    /// may span lines; comment lines are dropped.
    private static func profileUpdateCalls(in text: String) -> [Substring] {
        let code = text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        var calls: [Substring] = []
        var rest = code[...]
        while let open = rest.range(of: "ProfileUpdate(") {
            var depth = 1
            var index = open.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 } else if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            calls.append(rest[open.upperBound..<index])
            rest = rest[index...]
        }
        return calls
    }

    @Test func profilesSaveBodyNeverCarriesAZone() throws {
        let encoder = APICoding.makeEncoder()
        for update in [ProfileUpdate(name: "Ama Owusu"), ProfileUpdate(username: "ama"), ProfileUpdate(name: "Ama Owusu", username: "ama")] {
            let object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(update)) as? [String: String])
            #expect(object["timezone"] == nil)
        }

        // The update Profile's Save builds (FeatureAccount/ProfileView.swift):
        // across MoolahubKit's sources, only the sender's own update has a zone.
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let paths = FileManager.default.enumerator(atPath: sources.path)?
            .compactMap { $0 as? String }
            .filter { $0.hasSuffix(".swift") } ?? []
        var builders: Set<String> = []
        var withAZone: [String] = []
        for path in paths {
            let text = try String(contentsOf: sources.appendingPathComponent(path), encoding: .utf8)
            let calls = Self.profileUpdateCalls(in: text)
            if !calls.isEmpty { builders.insert(path) }
            if calls.contains(where: { $0.contains("timezone:") }) { withAZone.append(path) }
        }
        // The scan reaches both builders, so it can't pass by finding nothing.
        #expect(builders.isSuperset(of: ["FeatureAccount/ProfileView.swift", "Auth/TimeZoneSync.swift"]), "found \(builders.sorted()) under \(sources.path)")
        #expect(withAZone == ["Auth/TimeZoneSync.swift"])

        // The scan reads a call across lines, as Profile's is written.
        let multiline = "let update = ProfileUpdate(\n    name: nil,\n    username: f(x),\n    timezone: zone\n)\nlet other = ProfileUpdate(name: \"a\")"
        #expect(Self.profileUpdateCalls(in: multiline).map { $0.contains("timezone:") } == [true, false])
    }
}
