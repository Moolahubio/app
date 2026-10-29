import APIClient
import Auth
import Domain
import Foundation
import os
import Persistence
import Testing

// The AuthTests target's shared doubles (SPEC §8.2 item 8). A test target
// can't read another target's files or resources, so the stub server is a
// copy (`StubURLProtocol.swift`) and the JSON is inline, in the shapes of
// DomainTests' fixtures, redacted: no real ids, tokens or addresses.

/// Everything one test needs, built fresh: a stub server, an `APIClient` that
/// only talks to it, an in-memory token store, a snapshot cache in its own
/// temporary folder, a `UserDefaults` domain of its own, and the
/// `SessionStore`, `StreakStore` and `TimeZoneSync` built from them. Call
/// `tearDown()` when done (`defer { env.tearDown() }`).
@MainActor
struct AuthTestEnvironment {
    let server: StubServer
    let api: APIClient
    let tokenStore: InMemoryTokenStore
    let cacheDirectory: URL
    let cache: SnapshotCache
    let defaultsSuiteName: String
    let defaults: UserDefaults
    /// The zone `timeZoneSync` reads; set `deviceTimeZone.identifier` to move the device.
    let deviceTimeZone: TestTimeZone
    let session: SessionStore
    let streaks: StreakStore
    let timeZoneSync: TimeZoneSync

    init(timeZone: String = "Africa/Accra") {
        server = StubServer()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        api = APIClient(
            baseURL: server.baseURL,
            clientInfo: APIClient.ClientInfo(appVersion: "test", build: "1"),
            configuration: configuration
        )
        tokenStore = InMemoryTokenStore()
        let id = UUID().uuidString
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthTests-\(id)", isDirectory: true)
        cache = SnapshotCache(rootDirectory: cacheDirectory)
        defaultsSuiteName = "AuthTests-\(id)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        let zone = TestTimeZone(timeZone)
        deviceTimeZone = zone
        session = SessionStore(api: api, tokenStore: tokenStore, cache: cache, defaults: defaults)
        streaks = StreakStore(api: api, session: session, cache: cache, defaults: defaults)
        timeZoneSync = TimeZoneSync(api: api, session: session, defaults: defaults, currentIdentifier: { zone.identifier })
    }

    /// Removes the cache folder and the defaults domain.
    func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    /// Signs in through `POST /auth/login` and `GET /auth/me` (two replies),
    /// then queues `then` for the requests that follow. Replies are used in
    /// order and the last one repeats, so queue a whole test's replies here.
    func signIn(_ user: TestUser = .demo, then replies: [StubReply] = []) async throws {
        server.enqueue(.http(status: 200, json: user.loginJSON))
        server.enqueue(.http(status: 200, json: user.meJSON))
        for reply in replies { server.enqueue(reply) }
        _ = try await session.signIn(email: user.email, password: "not-a-real-password")
        #expect(session.currentUser?.id == user.id)
    }

    /// The requests the stub server saw for one method and API path ("/streaks").
    func requests(_ method: String, _ path: String) -> [RecordedRequest] {
        server.requests.filter { $0.method == method && $0.url.path == "/api\(path)" }
    }

    // MARK: Inline JSON (DomainTests fixtures' shapes)

    /// `GET /auth/me` (`AuthUser`), the seeded demo persona with a redacted id.
    static let authUserJSON = TestUser.demo.meJSON

    /// `GET /streaks` (`StreakOverview`), the captured sample's shape.
    static let streakOverviewJSON = streaksJSON()

    /// A `StreakOverview` with a chosen count and badges ("2026-q1" style keys).
    static func streaksJSON(count: Int = 1, badgeKeys: [String] = []) -> String {
        let badges = badgeKeys.map { key -> String in
            let parts = key.split(separator: "-q")
            let year = parts.first.map(String.init) ?? "2026"
            let quarter = parts.count > 1 ? String(parts[1]) : "1"
            return #"{"badgeKey":"\#(key)","year":\#(year),"quarterIndex":\#(quarter),"earnedAt":"2026-04-01T06:00:00.000Z"}"#
        }
        return """
        {"hero":{"count":\(count),"status":"active","commitmentName":null,"emoji":null},"frequency":"weekly",
         "canChangeFrequency":true,"nextChangeYear":null,"currentPeriodEnd":"2026-10-26T00:00:00.000Z",
         "currentPeriodSatisfied":true,"atRisk":false,"lifetimeBest":\(count),"totalPeriodsSaved":\(count),"commitments":[],
         "freezes":{"balance":1,"usedTotal":0},"badges":[\(badges.joined(separator: ","))],
         "badgeProgress":{"earnedQuarters":\(badgeKeys.count),"nextTier":"bronze","pct":0.025,"daysToNext":90},
         "reminderOptIn":false,"vacation":{"active":false,"start":null,"end":null,"usedThisYear":false}}
        """
    }
}

/// A signed-in user for the stub server.
struct TestUser: Sendable {
    let id: String
    let name: String
    let email: String
    let username: String

    /// The seeded demo persona (redacted id).
    static let demo = TestUser(id: "user-a", name: "Ama Owusu", email: "demo@moolahub.test", username: "ama")
    /// A second, throwaway-style user.
    static let other = TestUser(id: "user-b", name: "QA Second", email: "x-second@moolahub.test", username: "qasecond")

    var meJSON: String {
        #"{"id":"\#(id)","name":"\#(name)","email":"\#(email)","username":"\#(username)","avatarUrl":null,"hasWallet":true,"walletAddress":null,"hasPassword":true,"privyLinked":false,"emailVerified":true,"language":"en"}"#
    }

    /// `LoginResult` for a native client: the user plus a (fake) session token.
    var loginJSON: String {
        #"{"twoFactorRequired":false,"id":"\#(id)","name":"\#(name)","email":"\#(email)","username":"\#(username)","hasWallet":true,"sessionToken":"test-session-\#(id)"}"#
    }
}

/// The device time zone a test controls.
final class TestTimeZone: Sendable {
    private let state: OSAllocatedUnfairLock<String>

    init(_ identifier: String) {
        state = OSAllocatedUnfairLock(initialState: identifier)
    }

    var identifier: String {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// A clock a test moves by hand.
final class TestClock: Sendable {
    private let state: OSAllocatedUnfairLock<Date>

    init(_ start: Date = Date(timeIntervalSince1970: 1_793_000_000)) {
        state = OSAllocatedUnfairLock(initialState: start)
    }

    var now: Date { state.withLock { $0 } }

    func advance(by seconds: TimeInterval) {
        state.withLock { $0 = $0.addingTimeInterval(seconds) }
    }
}

/// Yields the main actor (never sleeping, so nothing queued behind this test
/// runs first) until `condition` holds; records an issue after 5 s.
@MainActor
func yieldUntil(_ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("condition not met within 5 s")
            return
        }
        await Task.yield()
    }
}

/// Blocks the calling thread, never suspending, so the main actor runs
/// nothing else meanwhile, until `condition` holds; records an issue after
/// 5 s. For holding back an answer that would land on the main actor.
func blockUntil(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() {
        guard Date() < deadline else {
            Issue.record("condition not met within 5 s")
            return
        }
        Thread.sleep(forTimeInterval: 0.01)
    }
}

/// A fetch the test answers by hand, call by call. It ignores cancellation,
/// like a response already on its way, so a dropped answer still arrives.
/// Every call must be answered: a call still unanswered after `patience`
/// records an issue and fails with `.noResponse`, and `waitForCalls` gives up
/// the same way, so a regression fails its test instead of hanging the run.
actor FetchGate<Value: Sendable> {
    static var patience: Duration { .seconds(5) }

    private var calls = 0
    private var pending: [Int: CheckedContinuation<Value, any Error>] = [:]
    private var callWaiters: [(id: Int, count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextWaiterID = 0

    var callCount: Int { calls }

    func fetch() async throws -> Value {
        calls += 1
        let call = calls
        let ready = callWaiters.filter { $0.count <= calls }
        callWaiters.removeAll { $0.count <= calls }
        for waiter in ready { waiter.continuation.resume() }
        Task {
            try? await Task.sleep(for: Self.patience)
            self.expire(call: call)
        }
        return try await withCheckedThrowingContinuation { pending[call] = $0 }
    }

    /// Returns once `count` fetches have started.
    func waitForCalls(_ count: Int) async {
        guard calls < count else { return }
        let id = nextWaiterID
        nextWaiterID += 1
        Task {
            try? await Task.sleep(for: Self.patience)
            self.giveUp(waiter: id)
        }
        await withCheckedContinuation { callWaiters.append((id, count, $0)) }
    }

    func answer(call: Int, with value: Value) {
        pending.removeValue(forKey: call)?.resume(returning: value)
    }

    func fail(call: Int, with error: APIError) {
        pending.removeValue(forKey: call)?.resume(throwing: error)
    }

    private func expire(call: Int) {
        guard let continuation = pending.removeValue(forKey: call) else { return }
        Issue.record("FetchGate call \(call) was never answered")
        continuation.resume(throwing: APIError.noResponse)
    }

    private func giveUp(waiter id: Int) {
        guard let index = callWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = callWaiters.remove(at: index)
        Issue.record("only \(calls) of \(waiter.count) FetchGate calls started")
        waiter.continuation.resume()
    }
}

/// Long enough for an answer a `FetchGate` released to reach its caller.
func settle() async {
    try? await Task.sleep(for: .milliseconds(200))
}
