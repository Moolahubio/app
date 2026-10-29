import APIClient
@testable import Auth
import Domain
import Foundation
import Persistence
import Testing

// `StreakStore` (streaks.md ST.1.4, SPEC §2.2, ST.15.1 item 15): reset drops
// in-flight results, a second user never sees the first user's overview, the
// 5 s reuse of a live overview, and the badge check under `PerUserKeys`, run
// on live overviews only.

@MainActor
@Suite("StreakStore", .timeLimit(.minutes(1)))
struct StreakStoreTests {
    @Test func loadTakesTheLiveOverviewForTheSignedInUserAndSavesIt() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [.http(status: 200, json: AuthTestEnvironment.streakOverviewJSON)])

        await env.streaks.load()

        #expect(env.streaks.ownerUserID == "user-a")
        #expect(env.streaks.overview.value?.hero?.count == 1)
        #expect(env.streaks.overview.value?.effectiveFrequency == .weekly)
        #expect(env.streaks.lastLiveReadAt != nil)
        #expect(env.requests("GET", "/streaks").count == 1)
        #expect(await env.cache.load(StreakOverview.self, for: .streaks)?.value.hero?.count == 1)
    }

    /// A store whose `GET /streaks` the test answers by hand.
    private func gatedStore(_ env: AuthTestEnvironment, _ gate: FetchGate<StreakOverview>) -> StreakStore {
        StreakStore(api: env.api, session: env.session, cache: env.cache, defaults: env.defaults, now: { Date() }) {
            try await gate.fetch()
        }
    }

    private func overview(count: Int, badgeKeys: [String] = []) throws -> StreakOverview {
        try APICoding.makeDecoder().decode(
            StreakOverview.self,
            from: Data(AuthTestEnvironment.streaksJSON(count: count, badgeKeys: badgeKeys).utf8)
        )
    }

    @Test func resetDropsTheAnswerOfARefreshStartedBeforeIt() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo)
        let gate = FetchGate<StreakOverview>()
        let streaks = gatedStore(env, gate)

        let refresh = Task { await streaks.refresh() }
        await gate.waitForCalls(1)
        streaks.reset()
        await refresh.value
        await gate.answer(call: 1, with: try overview(count: 3, badgeKeys: ["2026-q1"]))
        await settle()

        #expect(streaks.overview.value == nil)
        #expect(streaks.ownerUserID == nil)
        #expect(streaks.lastLiveReadAt == nil)
        #expect(streaks.pendingBadge == nil)
        // The dropped answer never reached the badge check or the cache.
        #expect(env.defaults.stringArray(forKey: PerUserKeys.badgesSeen(userID: "user-a")) == nil)
        #expect(await env.cache.load(StreakOverview.self, for: .streaks) == nil)

        // The next read is a new request, and its answer lands.
        let next = Task { await streaks.load() }
        await gate.waitForCalls(2)
        await gate.answer(call: 2, with: try overview(count: 1))
        await next.value
        #expect(streaks.overview.value?.hero?.count == 1)
        #expect(streaks.ownerUserID == "user-a")
    }

    @Test func resetDropsTheAnswerOfAFetchFreshStartedBeforeIt() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo)
        let gate = FetchGate<StreakOverview>()
        let streaks = gatedStore(env, gate)

        let fresh = Task { await streaks.fetchFresh() }
        await gate.waitForCalls(1)
        streaks.reset()
        await gate.answer(call: 1, with: try overview(count: 3, badgeKeys: ["2026-q1"]))

        #expect(await fresh.value == nil)
        #expect(streaks.overview.value == nil)
        #expect(streaks.lastLiveReadAt == nil)
        #expect(env.defaults.stringArray(forKey: PerUserKeys.badgesSeen(userID: "user-a")) == nil)
        #expect(await env.cache.load(StreakOverview.self, for: .streaks) == nil)
    }

    @Test func resetDropsTheAnswerOfAWriteStartedBeforeIt() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [.http(status: 200, json: AuthTestEnvironment.streaksJSON(count: 3, badgeKeys: ["2026-q1"]))])
        let gate = FetchGate<StreakOverview>()
        let streaks = gatedStore(env, gate)

        let write = Task { try await streaks.setFrequency(.monthly) }
        // The write takes its owner, then waits on the network.
        await yieldUntil { streaks.ownerUserID != nil }
        // Holding the main actor, so the answer can't land before the reset.
        blockUntil { !env.requests("POST", "/streaks/frequency").isEmpty }
        streaks.reset()
        try await write.value

        #expect(env.requests("POST", "/streaks/frequency").count == 1)
        #expect(streaks.overview.value == nil)
        #expect(streaks.lastLiveReadAt == nil)
        #expect(streaks.pendingBadge == nil)
        #expect(env.defaults.stringArray(forKey: PerUserKeys.badgesSeen(userID: "user-a")) == nil)
        #expect(await env.cache.load(StreakOverview.self, for: .streaks) == nil)
    }

    @Test func aSecondUserNeverSeesTheFirstUsersOverview() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(count: 7)),
            .http(status: 200, json: #"{"ok":true}"#),
            .http(status: 200, json: TestUser.other.loginJSON),
            .http(status: 200, json: TestUser.other.meJSON),
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(count: 1)),
        ])
        await env.streaks.load()
        #expect(env.streaks.overview.value?.hero?.count == 7)

        // Sign-out: `AppRootView` resets the store on `.signedOut`.
        await env.session.signOut()
        env.streaks.reset()
        #expect(env.streaks.overview.value == nil)

        _ = try await env.session.signIn(email: TestUser.other.email, password: "not-a-real-password")
        #expect(env.session.currentUser?.id == "user-b")
        // Before the second user's first load lands: nothing of the first user's.
        #expect(env.streaks.overview.value == nil)
        let load = Task { await env.streaks.load() }
        await yieldUntil { env.streaks.overview.isLoading }
        #expect(env.streaks.overview.value?.hero?.count != 7)
        await load.value

        #expect(env.streaks.ownerUserID == "user-b")
        #expect(env.streaks.overview.value?.hero?.count == 1)
    }

    @Test func aReadForAnotherUserStartsFromNothingEvenWithoutAReset() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(count: 7)),
            .http(status: 200, json: #"{"ok":true}"#),
            .http(status: 200, json: TestUser.other.loginJSON),
            .http(status: 200, json: TestUser.other.meJSON),
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(count: 1)),
        ])
        await env.streaks.load()
        await env.session.signOut()
        _ = try await env.session.signIn(email: TestUser.other.email, password: "not-a-real-password")

        let load = Task { await env.streaks.load() }
        await yieldUntil { env.streaks.overview.isLoading }
        #expect(env.streaks.ownerUserID == "user-b")
        #expect(env.streaks.overview.value?.hero?.count != 7)
        await load.value
        #expect(env.streaks.overview.value?.hero?.count == 1)
    }

    @Test func aLiveOverviewIsReusedForFiveSeconds() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        let clock = TestClock()
        let streaks = StreakStore(api: env.api, session: env.session, cache: env.cache, defaults: env.defaults, now: { clock.now })
        try await env.signIn(.demo, then: [.http(status: 200, json: AuthTestEnvironment.streakOverviewJSON)])

        // Nothing live yet: refresh.
        #expect(!streaks.hasRecentLiveOverview(now: clock.now))
        let fresh = await streaks.fetchFresh()
        #expect(fresh?.hero?.count == 1)
        #expect(streaks.lastLiveReadAt == clock.now)
        #expect(env.requests("GET", "/streaks").count == 1)

        clock.advance(by: 4.9)
        await streaks.refreshUnlessRecent()
        #expect(env.requests("GET", "/streaks").count == 1)

        clock.advance(by: 0.1)
        #expect(!streaks.hasRecentLiveOverview(now: clock.now))
        await streaks.refreshUnlessRecent()
        #expect(env.requests("GET", "/streaks").count == 2)
        #expect(streaks.lastLiveReadAt == clock.now)
    }

    @Test func fetchFreshFailingReturnsNilAndChangesNothing() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            .http(status: 200, json: AuthTestEnvironment.streakOverviewJSON),
            .http(status: 500, json: #"{"error":"Failed to load streaks"}"#),
        ])
        await env.streaks.load()
        let readAt = env.streaks.lastLiveReadAt

        let result = await env.streaks.fetchFresh()
        #expect(result == nil)
        #expect(env.streaks.overview.value?.hero?.count == 1)
        #expect(env.streaks.overview.error == nil)
        #expect(env.streaks.lastLiveReadAt == readAt)
    }

    @Test func theFirstLiveReadSeedsTheSeenListAndCelebratesNothing() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [.http(status: 200, json: AuthTestEnvironment.streaksJSON(badgeKeys: ["2026-q1"]))])

        await env.streaks.load()

        #expect(env.defaults.stringArray(forKey: "session.streak.badgesSeen.user-a") == ["2026-q1"])
        #expect(env.streaks.pendingBadge == nil)
    }

    @Test func aCachedSnapshotNeverRunsTheBadgeCheck() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo)
        let seenKey = PerUserKeys.badgesSeen(userID: "user-a")
        env.defaults.set(["2026-q1"], forKey: seenKey)
        let withNewBadge = try overview(count: 2, badgeKeys: ["2026-q1", "2026-q2"])
        await env.cache.save(withNewBadge, for: .streaks)
        let gate = FetchGate<StreakOverview>()
        let streaks = gatedStore(env, gate)

        let load = Task { await streaks.load() }
        await gate.waitForCalls(1)
        // The snapshot is shown, but only a live overview may celebrate.
        #expect(streaks.overview.isShowingCachedValue)
        #expect(streaks.overview.value?.badges.count == 2)
        #expect(streaks.pendingBadge == nil)
        #expect(streaks.lastLiveReadAt == nil)
        #expect(env.defaults.stringArray(forKey: seenKey) == ["2026-q1"])

        await gate.answer(call: 1, with: withNewBadge)
        await load.value
        #expect(streaks.pendingBadge?.badgeKey == "2026-q2")
        #expect(env.defaults.stringArray(forKey: seenKey) == ["2026-q1"])
    }

    @Test func theBadgeCheckWritesNothingOnceTheOwnerSignedOut() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [.http(status: 200, json: #"{"ok":true}"#)])
        let gate = FetchGate<StreakOverview>()
        let streaks = gatedStore(env, gate)

        // The read is in flight when its owner signs out, before any reset.
        let refresh = Task { await streaks.refresh() }
        await gate.waitForCalls(1)
        await env.session.signOut()
        await gate.answer(call: 1, with: try overview(count: 3, badgeKeys: ["2026-q1"]))
        await refresh.value

        #expect(streaks.pendingBadge == nil)
        #expect(env.defaults.stringArray(forKey: PerUserKeys.badgesSeen(userID: "user-a")) == nil)
    }

    @Test func aNewBadgeIsPendingUntilMarkedSeen() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(badgeKeys: ["2026-q1"])),
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(badgeKeys: ["2026-q1", "2026-q2", "2026-q3"])),
        ])
        await env.streaks.load()
        #expect(env.streaks.pendingBadge == nil)

        await env.streaks.refresh()
        // The newest unseen by (year, quarter); the seen list is unchanged until marked.
        #expect(env.streaks.pendingBadge?.badgeKey == "2026-q3")
        #expect(env.defaults.stringArray(forKey: PerUserKeys.badgesSeen(userID: "user-a")) == ["2026-q1"])

        env.streaks.markBadgesSeen()
        #expect(env.streaks.pendingBadge == nil)
        #expect(env.defaults.stringArray(forKey: PerUserKeys.badgesSeen(userID: "user-a")) == ["2026-q1", "2026-q2", "2026-q3"])

        // Nothing new on the next live read.
        await env.streaks.refresh()
        #expect(env.streaks.pendingBadge == nil)
    }

    @Test func theBadgeCheckRunsOnTheWritesToo() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(badgeKeys: [])),
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(badgeKeys: ["2026-q4"])),
        ])
        await env.streaks.load()
        #expect(env.defaults.stringArray(forKey: PerUserKeys.badgesSeen(userID: "user-a")) == [])

        try await env.streaks.setFrequency(.monthly)
        #expect(env.streaks.pendingBadge?.badgeKey == "2026-q4")
        #expect(env.streaks.overview.value?.badges.count == 1)
        let write = try #require(env.requests("POST", "/streaks/frequency").first)
        #expect(write.body.map { String(decoding: $0, as: UTF8.self) } == #"{"frequency":"monthly"}"#)
    }

    @Test func resetClearsHostsAndPendingBadge() async throws {
        let env = AuthTestEnvironment()
        defer { env.tearDown() }
        try await env.signIn(.demo, then: [
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(badgeKeys: [])),
            .http(status: 200, json: AuthTestEnvironment.streaksJSON(badgeKeys: ["2026-q4"])),
        ])
        await env.streaks.load()
        await env.streaks.refresh()
        env.streaks.celebrationHosts.insert(.homeRoot)
        #expect(env.streaks.pendingBadge != nil)

        env.streaks.reset()
        #expect(env.streaks.pendingBadge == nil)
        #expect(env.streaks.celebrationHosts.isEmpty)
        #expect(env.streaks.ownerUserID == nil)
        #expect(env.streaks.lastLiveReadAt == nil)
        #expect(env.streaks.overview.value == nil)
    }
}
