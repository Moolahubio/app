import Foundation
import Observation

/// Face ID / passcode app lock (DESIGN.md §8.7). Locks on cold launch and when
/// the app returns after more than `relockAfter` seconds in the background.
/// A device-side privacy gate only; the server session is unaffected.
@MainActor
@Observable
public final class AppLock {
    /// DESIGN.md §8.7 / §8.20: "after a minute in the background".
    public static let defaultRelockAfter: TimeInterval = 60

    public private(set) var isLocked = false
    public private(set) var isAuthenticating = false

    @ObservationIgnored private let settings: DeviceSettings
    @ObservationIgnored private let authenticator: DeviceAuthenticator
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored public var relockAfter: TimeInterval

    public init(
        settings: DeviceSettings,
        authenticator: DeviceAuthenticator,
        relockAfter: TimeInterval = AppLock.defaultRelockAfter,
        now: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.authenticator = authenticator
        self.relockAfter = relockAfter
        self.now = now
    }

    public var isEnabled: Bool { settings.appLockEnabled }

    /// Cold launch: lock if the user turned app lock on.
    public func lockOnLaunchIfEnabled() {
        if isEnabled && authenticator.biometryKind().isAvailable {
            isLocked = true
        }
    }

    public func sceneDidEnterBackground() {
        backgroundedAt = now()
    }

    public func sceneDidBecomeActive() {
        defer { backgroundedAt = nil }
        guard isEnabled, let backgroundedAt else { return }
        if now().timeIntervalSince(backgroundedAt) > relockAfter {
            isLocked = true
        }
    }

    /// Runs the system prompt; unlocks on success.
    @discardableResult
    public func unlock() async -> DeviceAuthResult {
        guard isLocked, !isAuthenticating else { return .cancelled }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let result = await authenticator.authenticate(reason: DeviceAuthenticator.Reason.unlock)
        if result == .success || result == .unavailable {
            // No passcode any more: the lock can't be satisfied, so don't trap the user.
            isLocked = false
        }
        return result
    }

    /// Turns app lock on after one successful prompt (DESIGN.md §8.7, §8.20).
    @discardableResult
    public func enable() async -> DeviceAuthResult {
        let result = await authenticator.authenticate(reason: DeviceAuthenticator.Reason.enableAppLock)
        if result == .success {
            settings.appLockEnabled = true
        }
        settings.appLockOffered = true
        return result
    }

    public func disable() {
        settings.appLockEnabled = false
        isLocked = false
    }

    /// Sign-out: never leave a lock screen over the Welcome screen.
    public func reset() {
        isLocked = false
        backgroundedAt = nil
    }
}
