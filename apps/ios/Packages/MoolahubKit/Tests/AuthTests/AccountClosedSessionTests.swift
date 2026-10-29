import APIClient
import Auth
import Domain
import Foundation
import Persistence
import Testing

// `SessionStore.endSessionAfterAccountClosed(_:)` (SPEC §4.4, account.md §7,
// §17 item 9): no `POST /auth/logout`; the token, the cache and `lastUserID`
// go; deletion removes exactly this user's two per-user keys, deactivation
// keeps them.

@MainActor
@Suite("Account closed session")
struct AccountClosedSessionTests {
    private func seedKeys(_ env: AuthTestEnvironment) {
        for user in ["user-a", "user-b"] {
            env.defaults.set(["2026-q1"], forKey: PerUserKeys.badgesSeen(userID: user))
            env.defaults.set("Africa/Accra", forKey: PerUserKeys.timeZoneSent(userID: user))
        }
        env.defaults.set(true, forKey: "device.appLockEnabled")
    }

    @Test func deletionSendsNoLogoutAndRemovesOnlyThisUsersKeys() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo)
        seedKeys(env)
        await env.cache.save("cached", for: .dashboard)
        let requestsBefore = env.server.requests.count

        await env.session.endSessionAfterAccountClosed(.accountDeleted)

        #expect(env.session.state == .signedOut(.accountDeleted))
        #expect(env.requests("POST", "/auth/logout").isEmpty)
        #expect(env.server.requests.count == requestsBefore)
        #expect(try env.tokenStore.readToken() == nil)
        #expect(await env.api.hasSessionToken == false)
        #expect(env.defaults.string(forKey: "session.lastUserID") == nil)
        await env.cache.setUser("user-a")
        #expect(await env.cache.load(String.self, for: .dashboard) == nil)

        #expect(env.defaults.object(forKey: "session.streak.badgesSeen.user-a") == nil)
        #expect(env.defaults.object(forKey: "session.streak.timezoneSent.user-a") == nil)
        #expect(env.defaults.stringArray(forKey: "session.streak.badgesSeen.user-b") == ["2026-q1"])
        #expect(env.defaults.string(forKey: "session.streak.timezoneSent.user-b") == "Africa/Accra")
        // Device settings stay.
        #expect(env.defaults.bool(forKey: "device.appLockEnabled"))
    }

    @Test func deactivationSendsNoLogoutAndKeepsThisUsersKeys() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo)
        seedKeys(env)
        await env.cache.save("cached", for: .dashboard)

        await env.session.endSessionAfterAccountClosed(.accountDeactivated)

        #expect(env.session.state == .signedOut(.accountDeactivated))
        #expect(env.requests("POST", "/auth/logout").isEmpty)
        #expect(try env.tokenStore.readToken() == nil)
        #expect(env.defaults.string(forKey: "session.lastUserID") == nil)
        await env.cache.setUser("user-a")
        #expect(await env.cache.load(String.self, for: .dashboard) == nil)

        #expect(env.defaults.stringArray(forKey: "session.streak.badgesSeen.user-a") == ["2026-q1"])
        #expect(env.defaults.string(forKey: "session.streak.timezoneSent.user-a") == "Africa/Accra")
        #expect(env.defaults.stringArray(forKey: "session.streak.badgesSeen.user-b") == ["2026-q1"])
    }

    @Test func aSignOutStillSendsLogoutAndKeepsTheKeys() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [.http(status: 200, json: #"{"ok":true}"#)])
        seedKeys(env)

        await env.session.signOut()

        #expect(env.session.state == .signedOut(.userSignedOut))
        #expect(env.requests("POST", "/auth/logout").count == 1)
        #expect(env.defaults.stringArray(forKey: "session.streak.badgesSeen.user-a") == ["2026-q1"])
    }
}
