import APIClient
import Domain
import Foundation
import Observation
import Persistence

/// A screen where the New badge sheet may appear while it is visible with
/// nothing of its own presented (streaks.md ST.1.4, ST.9).
public enum CelebrationHost: Hashable, Sendable {
    case homeRoot
    case streakScreen
}

/// The account's savings streak (streaks.md ST.1.4, SPEC §2.2): one store for
/// Home's row, the Streak screen, the frequency screen, Account's row and the
/// receipts, so they never disagree. `AppServices` holds it as `streaks` for
/// the app's lifetime, so `AppRootView` calls `reset()` on every sign-out and
/// when another user signs in.
///
/// Every live overview (a load, a refresh, `fetchFresh()`, the three writes;
/// never a cached snapshot) runs the badge check (R13): the first one for a
/// user on this device seeds the seen list silently; later ones set
/// `pendingBadge` to the newest unseen badge, which `AppRootView` presents.
@MainActor
@Observable
public final class StreakStore {
    /// How long a live overview is reused instead of refreshing again (Home's
    /// money-signal and reappear refreshes after a receipt's `fetchFresh()`;
    /// SPEC §1.9, D-29).
    public static let liveReuseInterval: TimeInterval = 5

    /// Cached snapshot first, then live (`SnapshotKey.streaks`). Read it; load
    /// and refresh through the store, so the badge check and the owner hold.
    public let overview: RemoteResource<StreakOverview>
    /// The user the held overview belongs to; set when a read starts.
    public private(set) var ownerUserID: String?
    /// When the store last took a live overview.
    public private(set) var lastLiveReadAt: Date?
    /// The newest badge this user has not seen yet; nil when there is none.
    public private(set) var pendingBadge: StreakBadge?
    /// The visible screens that allow the New badge sheet. Home's root and the
    /// Streak screen insert themselves on appear while they present nothing
    /// of their own, and remove themselves otherwise.
    public var celebrationHosts: Set<CelebrationHost> = []

    @ObservationIgnored private let api: APIClient
    /// One live `GET /streaks` (tests pass their own).
    @ObservationIgnored private let fetchOverview: @Sendable () async throws -> StreakOverview
    @ObservationIgnored private let session: SessionStore
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Bumped by every reset: an answer to a request started before it is dropped.
    @ObservationIgnored private var generation = 0

    public convenience init(
        api: APIClient,
        session: SessionStore,
        cache: SnapshotCache,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.init(api: api, session: session, cache: cache, defaults: defaults, now: now) {
            try await api.send(API.Streaks.overview())
        }
    }

    init(
        api: APIClient,
        session: SessionStore,
        cache: SnapshotCache,
        defaults: UserDefaults,
        now: @escaping @Sendable () -> Date,
        fetchOverview: @escaping @Sendable () async throws -> StreakOverview
    ) {
        self.api = api
        self.fetchOverview = fetchOverview
        self.session = session
        self.cache = cache
        self.defaults = defaults
        self.now = now
        overview = RemoteResource(cacheKey: .streaks, cache: cache, fetch: fetchOverview)
        overview.didApplyLiveValue = { [weak self] value in
            self?.didTakeLive(value)
        }
    }

    // MARK: Reads

    /// First appear: the cached snapshot, then live.
    public func load() async {
        adoptSessionUser()
        await overview.load()
    }

    /// Pull to refresh and the hosts' triggers. Joins a read already in flight.
    public func refresh() async {
        adoptSessionUser()
        await overview.refresh()
    }

    /// True when a live overview arrived less than `liveReuseInterval` ago.
    public func hasRecentLiveOverview(now: Date) -> Bool {
        guard let lastLiveReadAt else { return false }
        return now.timeIntervalSince(lastLiveReadAt) < Self.liveReuseInterval
    }

    /// `refresh()`, unless a live overview arrived in the last 5 s (SPEC §1.9:
    /// Home's money-signal and reappear refreshes).
    public func refreshUnlessRecent() async {
        guard !hasRecentLiveOverview(now: now()) else { return }
        await refresh()
    }

    /// One live `GET /streaks` with no cache read (the receipts, ST.8). On
    /// success it replaces the overview and saves the snapshot; on failure it
    /// returns nil and changes nothing.
    public func fetchFresh() async -> StreakOverview? {
        adoptSessionUser()
        let started = generation
        do {
            let fresh = try await fetchOverview()
            guard generation == started else { return nil }
            await take(fresh)
            return fresh
        } catch {
            return nil
        }
    }

    // MARK: Writes (ST.1.1's exact bodies; never retried)

    /// `POST /streaks/frequency`. Throws the `APIError` for the caller's banner.
    public func setFrequency(_ frequency: StreakFrequency) async throws(APIError) {
        try await write(API.Streaks.setFrequency(frequency))
    }

    /// `POST /streaks/vacation` (Take a break).
    public func startBreak(days: StreakBreakDays) async throws(APIError) {
        try await write(API.Streaks.startBreak(days: days))
    }

    /// `POST /streaks/vacation/end` (End break early).
    public func endBreak() async throws(APIError) {
        try await write(API.Streaks.endBreak())
    }

    private func write(_ request: APIRequest<StreakOverview>) async throws(APIError) {
        adoptSessionUser()
        let started = generation
        let fresh = try await api.send(request)
        guard generation == started else { return }
        await take(fresh)
    }

    // MARK: Badges

    /// The New badge sheet went away by any route: every current badge is
    /// seen, and nothing is pending.
    public func markBadgesSeen() {
        defer { pendingBadge = nil }
        guard let userID = ownerUserID else { return }
        let key = PerUserKeys.badgesSeen(userID: userID)
        var seen = defaults.stringArray(forKey: key) ?? []
        let current = (overview.value?.badges ?? []).map(\.badgeKey) + [pendingBadge?.badgeKey].compactMap { $0 }
        for badgeKey in current where !seen.contains(badgeKey) {
            seen.append(badgeKey)
        }
        defaults.set(seen, forKey: key)
    }

    // MARK: Lifecycle

    /// Sign-out (any reason) and a change of user: clears the overview, the
    /// owner, the pending badge, the hosts and the last live read, and drops
    /// the answers of requests started before it.
    public func reset() {
        clearUserData()
        celebrationHosts = []
    }

    // MARK: Private

    private func clearUserData() {
        generation += 1
        overview.reset()
        ownerUserID = nil
        pendingBadge = nil
        lastLiveReadAt = nil
    }

    /// The store holds one user's streak: a read for another user starts from
    /// nothing (the backstop to `AppRootView`'s reset on a change of user).
    private func adoptSessionUser() {
        let userID = session.currentUser?.id
        if let ownerUserID, ownerUserID != userID {
            clearUserData()
        }
        ownerUserID = userID
    }

    /// A live overview from `fetchFresh()` or a write.
    private func take(_ fresh: StreakOverview) async {
        overview.replace(with: fresh)
        didTakeLive(fresh)
        await cache.save(fresh, for: .streaks)
    }

    /// Every live overview: its time, then the badge check (R13).
    private func didTakeLive(_ fresh: StreakOverview) {
        lastLiveReadAt = now()
        guard let userID = ownerUserID, session.currentUser?.id == userID else { return }
        let key = PerUserKeys.badgesSeen(userID: userID)
        let seen = defaults.stringArray(forKey: key)
        let result = StreakBadgeSeen.evaluate(badges: fresh.badges, seen: seen)
        if seen == nil {
            defaults.set(result.seen, forKey: key)
        }
        pendingBadge = result.pending
    }
}
