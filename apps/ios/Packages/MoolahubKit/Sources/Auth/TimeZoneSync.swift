import APIClient
import Domain
import Foundation

/// Sends the device's time zone so the server counts streak periods in it
/// (SPEC §4.5, the single owner; streaks.md ST.1.5, account.md §12). Held by
/// `AppServices` as `timeZoneSync`.
///
/// Triggers: `AppRootView` calls `sync()` when the scene becomes active while
/// signed in and when the session enters `.signedIn`; this type's own
/// observer calls it on `NSSystemTimeZoneDidChange` while signed in and the
/// scene is active (`AppRootView` keeps `isSceneActive` current).
///
/// A sync sends `PATCH /profile` with exactly `{"timezone":"<IANA id>"}` when
/// `TimeZoneSyncRule.shouldSend` says so, at most one at a time, and stores
/// the zone under `PerUserKeys.timeZoneSent(userID:)` only when the answer
/// echoes it. A failure stores nothing and shows nothing; the next trigger
/// tries again.
@MainActor
public final class TimeZoneSync {
    /// Whether the app's scene is active. Set by `AppRootView` from `scenePhase`.
    public var isSceneActive = false
    /// True while a `PATCH /profile` is in flight; a trigger meanwhile is ignored.
    private(set) var isSyncing = false

    private let session: SessionStore
    private let defaults: UserDefaults
    /// The zone the sync compares and sends: the device's, or in Debug the
    /// launch environment's `MH_TIME_ZONE` (AppComposition). Dates on screen
    /// always use the device zone.
    private let currentIdentifier: @Sendable () -> String
    /// One `PATCH /profile` (tests pass their own).
    private let sendUpdate: @Sendable (ProfileUpdate) async throws -> UserProfile
    nonisolated(unsafe) private var zoneChangeObserver: (any NSObjectProtocol)?

    public convenience init(
        api: APIClient,
        session: SessionStore,
        defaults: UserDefaults = .standard,
        currentIdentifier: @escaping @Sendable () -> String = { TimeZone.current.identifier }
    ) {
        self.init(session: session, defaults: defaults, currentIdentifier: currentIdentifier) { update in
            try await api.send(API.Profile.update(update))
        }
    }

    init(
        session: SessionStore,
        defaults: UserDefaults,
        currentIdentifier: @escaping @Sendable () -> String,
        sendUpdate: @escaping @Sendable (ProfileUpdate) async throws -> UserProfile
    ) {
        self.session = session
        self.defaults = defaults
        self.currentIdentifier = currentIdentifier
        self.sendUpdate = sendUpdate
        zoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemTimeZoneDidChange() }
        }
    }

    deinit {
        if let zoneChangeObserver {
            NotificationCenter.default.removeObserver(zoneChangeObserver)
        }
    }

    /// Sends the zone when it differs from the one last sent for this user.
    /// Does nothing while signed out or while a send is in flight. Never
    /// throws and never retries: the next trigger tries again.
    public func sync() async {
        guard !isSyncing, let userID = session.currentUser?.id else { return }
        let zone = currentIdentifier()
        let key = PerUserKeys.timeZoneSent(userID: userID)
        guard TimeZoneSyncRule.shouldSend(current: zone, lastSent: defaults.string(forKey: key)) else { return }

        isSyncing = true
        defer { isSyncing = false }
        let echoed: String?
        do {
            echoed = try await sendUpdate(ProfileUpdate(timezone: zone)).timezone
        } catch {
            // 400 "That time zone isn't supported.", a 500, offline: nothing
            // stored, nothing shown.
            return
        }
        // Stored only for the user it was sent for, while still signed in, so
        // an answer landing after a sign-out or a deletion leaves no key.
        guard TimeZoneSyncRule.shouldStore(sent: zone, echoed: echoed),
              session.currentUser?.id == userID
        else { return }
        defaults.set(zone, forKey: key)
    }

    private func systemTimeZoneDidChange() {
        guard isSceneActive, session.isSignedIn else { return }
        Task { await sync() }
    }
}
