import APIClient
import Domain
import Foundation
import Observation
import Persistence

/// Why the user is on the signed-out screens.
public enum SignedOutReason: Hashable, Sendable {
    /// The server said the session is no longer valid (401 Unauthorized).
    case sessionExpired
    /// The user signed out.
    case userSignedOut
    /// A password reset completed; show the jade "Sign in with your new password" banner.
    case passwordReset
    /// The API server address changed (Developer settings).
    case serverChanged
    /// The user deactivated their account (Welcome, with a toast).
    case accountDeactivated
    /// The user deleted their account (Welcome, with a toast).
    case accountDeleted
}

public enum SessionState: Equatable, Sendable {
    /// Launching: reading the Keychain and checking the session.
    case restoring
    case signedOut(SignedOutReason?)
    case signedIn(AuthUser)
    /// A token exists but the session couldn't be checked and there's no
    /// cached user to show (first launch offline). Offer "Try again".
    case restoreFailed(APIError)
}

/// What a sign-in step produced.
public enum SignInOutcome: Equatable, Sendable {
    case signedIn(AuthUser)
    case twoFactorRequired(challengeID: String)
    case emailVerificationRequired(email: String)
}

/// The signed-in session: the only place the session token is stored, sent to
/// the API client, or deleted.
///
/// - Token: Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`),
///   mirrored in memory in `APIClient`, never logged.
/// - 401 `{"error":"Unauthorized"}` from any authenticated call → the client
///   calls `handleSessionExpired()` → token deleted, caches cleared, back to
///   sign-in with "You've been signed out".
/// - Fresh install: a token left in the Keychain by a previous install is
///   deleted on first launch.
@MainActor
@Observable
public final class SessionStore {
    public private(set) var state: SessionState = .restoring
    /// True while the signed-in user is the cached copy (offline launch).
    public private(set) var isShowingCachedUser = false
    /// True right after an interactive sign-in (not a restore). AppFeature
    /// uses it to offer app lock once.
    public private(set) var didJustSignIn = false

    @ObservationIgnored private let api: APIClient
    @ObservationIgnored private let tokenStore: any SessionTokenStore
    @ObservationIgnored private let cache: SnapshotCache
    @ObservationIgnored private let defaults: UserDefaults

    private static let installMarkerKey = "session.installMarker"
    private static let sessionUserKey = SnapshotKey("session-user")
    private static let lastUserIDKey = "session.lastUserID"

    public init(api: APIClient, tokenStore: any SessionTokenStore, cache: SnapshotCache, defaults: UserDefaults = .standard) {
        self.api = api
        self.tokenStore = tokenStore
        self.cache = cache
        self.defaults = defaults
    }

    // MARK: Derived state

    public var currentUser: AuthUser? {
        if case .signedIn(let user) = state { return user }
        return nil
    }

    public var isSignedIn: Bool { currentUser != nil }

    public var signedOutReason: SignedOutReason? {
        if case .signedOut(let reason) = state { return reason }
        return nil
    }

    // MARK: Launch

    /// Call once at launch. Wires the expiry handler and restores the session.
    public func restore() async {
        await api.setSessionExpiredHandler { [weak self] in
            await self?.handleSessionExpired()
        }

        if defaults.string(forKey: Self.installMarkerKey) == nil {
            // First launch of this install: Keychain items survive app
            // deletion, so drop any token a previous install left behind.
            try? tokenStore.deleteToken()
            await cache.clearAll()
            defaults.set(UUID().uuidString, forKey: Self.installMarkerKey)
        }

        let stored: String?
        do {
            stored = try tokenStore.readToken()
        } catch {
            stored = nil
        }
        guard let stored, !stored.isEmpty else {
            state = .signedOut(nil)
            return
        }
        await api.setSessionToken(SessionToken(stored))
        await refreshUser(onLaunch: true)
    }

    /// Re-checks the session (also the "Try again" on `.restoreFailed`).
    public func retryRestore() async {
        state = .restoring
        await refreshUser(onLaunch: true)
    }

    /// Fetches `/auth/me` and updates the signed-in user. Returns the error
    /// when the refresh failed for any reason other than an expired session or
    /// a cancellation, so Account can show its refresh banner (DESIGN.md v2
    /// B5.1, U6); a 401 still ends the session and returns nil.
    @discardableResult
    public func refreshUser() async -> APIError? {
        await refreshUser(onLaunch: false)
    }

    @discardableResult
    private func refreshUser(onLaunch: Bool) async -> APIError? {
        do throws(APIError) {
            let user = try await api.send(API.Auth.me())
            defaults.set(user.id, forKey: Self.lastUserIDKey)
            await cache.setUser(user.id)
            await cache.save(user, for: Self.sessionUserKey)
            isShowingCachedUser = false
            state = .signedIn(user)
            return nil
        } catch {
            switch error {
            case .sessionExpired:
                // handleSessionExpired() already ran via the client's handler.
                if case .signedOut = state {} else { await endSession(reason: .sessionExpired) }
                return nil
            case .cancelled:
                return nil
            default:
                guard onLaunch else { return error }
                if let cached = await cachedUser() {
                    isShowingCachedUser = true
                    state = .signedIn(cached)
                } else {
                    state = .restoreFailed(error)
                }
                return error
            }
        }
    }

    private func cachedUser() async -> AuthUser? {
        // The cache is per user and we don't know the user yet, so the session
        // user lives in a well-known slot keyed by the last user id.
        guard let lastUserID = defaults.string(forKey: Self.lastUserIDKey) else { return nil }
        await cache.setUser(lastUserID)
        return await cache.load(AuthUser.self, for: Self.sessionUserKey)?.value
    }

    // MARK: Sign in / sign up

    /// `POST /auth/login`.
    public func signIn(email: String, password: String) async throws(APIError) -> SignInOutcome {
        let result = try await api.send(API.Auth.login(LoginInput(email: Validation.normalizedEmail(email), password: Secret(password))))
        return try await complete(result)
    }

    /// `POST /auth/register`; returns the email the code went to.
    /// `referralSource` ("How did you hear about MoolaHub?") is sent as its
    /// raw value and left out when nil.
    public func register(
        name: String, username: String, email: String, password: String, dateOfBirth: String,
        referralSource: ReferralSource? = nil
    ) async throws(APIError) -> String {
        let input = RegisterInput(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            email: Validation.normalizedEmail(email),
            password: Secret(password),
            dateOfBirth: dateOfBirth,
            referralSource: referralSource?.rawValue
        )
        return try await api.send(API.Auth.register(input)).email
    }

    /// `POST /auth/verify-email`.
    public func verifyEmail(email: String, code: String) async throws(APIError) -> SignInOutcome {
        let input = VerifyEmailInput(email: Validation.normalizedEmail(email), code: Secret(code))
        let result = try await api.send(API.Auth.verifyEmail(input))
        return try await complete(result)
    }

    /// `POST /auth/resend-code`.
    public func resendVerificationCode(email: String) async throws(APIError) {
        _ = try await api.send(API.Auth.resendCode(email: Validation.normalizedEmail(email)))
    }

    /// `POST /auth/2fa/login` with a TOTP or backup code.
    public func completeTwoFactor(challengeID: String, code: String) async throws(APIError) -> AuthUser {
        let input = TwoFactorLoginInput(challengeId: challengeID, code: Secret(code.trimmingCharacters(in: .whitespacesAndNewlines)))
        let result = try await api.send(API.Auth.twoFactorLogin(input))
        guard let token = result.sessionToken else { throw .invalidResponse }
        try await startSession(user: result.user, token: token)
        return result.user
    }

    /// `POST /auth/forgot-password` (always succeeds unless rate limited).
    public func requestPasswordReset(email: String) async throws(APIError) {
        _ = try await api.send(API.Auth.forgotPassword(email: Validation.normalizedEmail(email)))
    }

    /// `POST /auth/reset-password`. On success the user signs in again.
    public func resetPassword(email: String, code: String, newPassword: String) async throws(APIError) {
        let input = ResetPasswordInput(email: Validation.normalizedEmail(email), code: Secret(code), newPassword: Secret(newPassword))
        _ = try await api.send(API.Auth.resetPassword(input))
        state = .signedOut(.passwordReset)
    }

    /// `GET /auth/username-available`.
    public func isUsernameAvailable(_ username: String) async throws(APIError) -> UsernameAvailability {
        try await api.send(API.Auth.usernameAvailable(username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()))
    }

    private func complete(_ result: LoginResult) async throws(APIError) -> SignInOutcome {
        if result.twoFactorRequired {
            guard let challengeID = result.challengeId else { throw .invalidResponse }
            return .twoFactorRequired(challengeID: challengeID)
        }
        if result.emailVerificationRequired == true {
            return .emailVerificationRequired(email: result.email ?? "")
        }
        guard let user = result.user, let token = result.sessionToken else { throw .invalidResponse }
        try await startSession(user: user, token: token)
        return .signedIn(currentUser ?? user)
    }

    private func startSession(user: AuthUser, token: SessionToken) async throws(APIError) {
        do {
            try tokenStore.saveToken(token.rawValue)
        } catch {
            // Without the Keychain the session can't survive a relaunch; refuse
            // rather than pretend.
            throw .invalidResponse
        }
        await api.setSessionToken(token)
        defaults.set(user.id, forKey: Self.lastUserIDKey)
        await cache.setUser(user.id)
        didJustSignIn = true
        isShowingCachedUser = false
        state = .signedIn(user)
        // Pick up fields the login response doesn't carry (emailVerified, language).
        await refreshUser(onLaunch: false)
    }

    /// AppFeature calls this after it has shown (or skipped) the app lock offer.
    public func acknowledgeSignIn() {
        didJustSignIn = false
    }

    // MARK: Sign out

    /// Sign-out sequence (DESIGN.md §8.18): server logout (best effort, 5s),
    /// delete the token, clear cached data, back to Welcome. Device settings stay.
    public func signOut(reason: SignedOutReason = .userSignedOut) async {
        if await api.hasSessionToken {
            _ = try? await api.send(API.Auth.logout())
        }
        await endSession(reason: reason)
    }

    /// After a successful deactivation or deletion (account.md §7): the server
    /// already ended every session, so no `POST /auth/logout` is sent. The
    /// token, the cached data and `lastUserID` go as on sign-out, and
    /// AppFeature resets the shared stores on `.signedOut`. Deletion also
    /// removes this user's per-user keys; deactivation keeps them, so signing
    /// back in celebrates nothing again. Device settings stay.
    public func endSessionAfterAccountClosed(_ reason: SignedOutReason) async {
        // Captured first: `endSession` clears the user and `lastUserID`.
        let userID = currentUser?.id ?? defaults.string(forKey: Self.lastUserIDKey)
        await endSession(reason: reason)
        if reason == .accountDeleted, let userID {
            PerUserKeys.removeAll(for: userID, in: defaults)
        }
    }

    /// Called by the API client after a 401 `{"error":"Unauthorized"}`.
    public func handleSessionExpired() async {
        guard isSignedIn || state == .restoring else { return }
        await endSession(reason: .sessionExpired)
    }

    private func endSession(reason: SignedOutReason) async {
        try? tokenStore.deleteToken()
        await api.setSessionToken(nil)
        await cache.clearAll()
        defaults.removeObject(forKey: Self.lastUserIDKey)
        isShowingCachedUser = false
        didJustSignIn = false
        state = .signedOut(reason)
    }

    #if DEBUG
    /// Developer settings: whether a token is stored (never its value).
    public func hasStoredToken() -> Bool {
        ((try? tokenStore.readToken()) ?? nil) != nil
    }
    #endif
}
