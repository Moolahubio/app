import APIClient
import Domain
import Foundation
import Observation
import Persistence

/// Load-from-cache-then-network for one screen's data, with the states
/// DESIGN.md requires: skeleton while loading, error-with-retry when there's
/// nothing to show, data plus an error banner when a refresh fails, and the
/// snapshot age ("Updated 5 min ago") while showing cached data.
///
///     @State private var summary: RemoteResource<DashboardSummary>
///
///     init(services: AppServices) {
///         let api = services.api
///         _summary = State(initialValue: RemoteResource(cacheKey: .dashboard, cache: services.cache) {
///             try await api.send(API.Dashboard.summary())
///         })
///     }
///
///     .task { await summary.load() }
///     .refreshable { await summary.refresh() }
///
/// Never use this for money moves: they are one-shot requests, not resources.
///
/// One request at a time (SPEC §1.9, D-24): a `refresh()` while one is in
/// flight awaits the running one instead of sending a second request. A
/// caller whose task is cancelled (its view went away) returns at once; the
/// request is cancelled only when nobody else awaits it, as a lone caller's
/// request always was, so a resource shared by several screens
/// (`StreakStore`) never strands the others. A generation token drops answers
/// that arrive after `reset()`, `replace(with:)` or that cancellation, so an
/// older response never overwrites a newer value or a signed-out user's data.
@MainActor
@Observable
public final class RemoteResource<Value: Codable & Sendable> {
    public enum Phase: Equatable {
        /// Nothing to show yet: render the skeleton.
        case loading
        /// `value` is set (fresh or cached).
        case loaded
        /// Nothing to show and the load failed: render `ErrorState`.
        case failed(APIError)
    }

    /// The data, fresh or cached. Never a fabricated default.
    public private(set) var value: Value?
    /// When `value` was fetched (or cached).
    public private(set) var updatedAt: Date?
    /// True while `value` is the on-disk snapshot, not a fresh response.
    public private(set) var isShowingCachedValue = false
    public private(set) var isLoading = false
    /// The last load error. With a value: show an `ErrorBanner`. Without: `ErrorState`.
    public private(set) var error: APIError?

    @ObservationIgnored private let cacheKey: SnapshotKey?
    @ObservationIgnored private let cache: SnapshotCache?
    @ObservationIgnored private let fetch: @Sendable () async throws -> Value
    /// Bumped by `reset()`, `replace(with:)` and when the last caller of a
    /// fetch goes away: an answer to a request started in an older
    /// generation is dropped.
    @ObservationIgnored private var generation = 0
    /// The fetch running now (one per generation), and everyone awaiting it.
    @ObservationIgnored private var inFlight: Task<Void, Never>?
    @ObservationIgnored private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var nextWaiterID = 0
    /// Auth-internal: called with each live response this resource applies
    /// (never a cached snapshot or a dropped answer). `StreakStore` runs its
    /// badge check here.
    @ObservationIgnored var didApplyLiveValue: ((Value) -> Void)?

    /// - Parameter fetch: usually one `api.send(…)`. Errors that aren't
    ///   `APIError` (there shouldn't be any) count as `.invalidResponse`.
    public init(
        cacheKey: SnapshotKey? = nil,
        cache: SnapshotCache? = nil,
        fetch: @escaping @Sendable () async throws -> Value
    ) {
        self.cacheKey = cacheKey
        self.cache = cache
        self.fetch = fetch
    }

    public var phase: Phase {
        if value != nil { return .loaded }
        if let error, !isLoading { return .failed(error) }
        return .loading
    }

    /// "Updated 5 min ago" while showing cached data; nil when fresh.
    public func updatedText(now: Date = Date()) -> String? {
        guard isShowingCachedValue, let updatedAt else { return nil }
        return SnapshotAge.text(savedAt: updatedAt, now: now)
    }

    /// First load: shows the cached snapshot immediately (if any), then fetches.
    public func load() async {
        let started = generation
        if value == nil, let cache, let cacheKey,
           let snapshot = await cache.load(Value.self, for: cacheKey),
           generation == started, value == nil
        {
            value = snapshot.value
            updatedAt = snapshot.savedAt
            isShowingCachedValue = true
        }
        // A `reset()` during the snapshot read ends this load: the next owner loads again.
        guard generation == started else { return }
        await refresh()
    }

    /// Fetches from the API; on failure keeps whatever is shown. While a
    /// fetch is in flight, waits for it instead of sending another. A caller
    /// whose task is already cancelled returns at once and sends nothing, as
    /// `APIClient.send` never sends from a cancelled task.
    public func refresh() async {
        guard !Task.isCancelled else { return }
        if inFlight == nil {
            let started = generation
            isLoading = true
            inFlight = Task { await self.fetchAndApply(generation: started) }
        }
        let id = nextWaiterID
        nextWaiterID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor in self.callerWentAway(id) }
        }
    }

    /// A caller's task was cancelled: it returns now, and when nobody else
    /// awaits the fetch, the fetch is cancelled and its answer dropped.
    private func callerWentAway(_ id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.resume()
        if waiters.isEmpty { dropInFlight() }
    }

    private func fetchAndApply(generation started: Int) async {
        defer {
            if generation == started {
                isLoading = false
                inFlight = nil
                resumeWaiters()
            }
        }
        do {
            let fresh = try await fetch()
            guard generation == started else { return }
            value = fresh
            updatedAt = Date()
            isShowingCachedValue = false
            error = nil
            didApplyLiveValue?(fresh)
            if let cache, let cacheKey {
                await cache.save(fresh, for: cacheKey)
            }
        } catch APIError.cancelled {
            // Dropped by `reset()`, or the request was cancelled; nothing to report.
        } catch is CancellationError {
            // Same.
        } catch let apiError as APIError {
            if generation == started { error = apiError }
        } catch {
            if generation == started { self.error = .invalidResponse }
        }
    }

    /// Replaces the value after a mutation the screen already knows the
    /// result of (e.g. the server returned the updated object). A fetch still
    /// in flight is dropped, so its older answer never overwrites this one.
    public func replace(with value: Value) {
        dropInFlight()
        self.value = value
        updatedAt = Date()
        isShowingCachedValue = false
        error = nil
    }

    /// Back to nothing loaded (sign-out, another user): clears the value, its
    /// age and the error, and drops the answer of any fetch still in flight.
    /// The next `load()` starts from the cache and the network again.
    public func reset() {
        dropInFlight()
        value = nil
        updatedAt = nil
        isShowingCachedValue = false
        error = nil
    }

    /// Starts a new generation: the running fetch (if any) is cancelled, its
    /// answer will be dropped, and whoever awaits it returns now.
    private func dropInFlight() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        isLoading = false
        resumeWaiters()
    }

    private func resumeWaiters() {
        let waiting = waiters.values
        waiters = [:]
        for waiter in waiting { waiter.resume() }
    }

    #if DEBUG
    /// A resource that is already loaded, for SwiftUI previews.
    public static func preview(_ value: Value) -> RemoteResource<Value> {
        let resource = RemoteResource { value }
        resource.replace(with: value)
        return resource
    }

    /// Keeps the documented feature usage compiling.
    static func usageCompiles(api: APIClient, cache: SnapshotCache) -> RemoteResource<DashboardSummary> {
        RemoteResource<DashboardSummary>(cacheKey: .dashboard, cache: cache) {
            try await api.send(API.Dashboard.summary())
        }
    }
    #endif
}
