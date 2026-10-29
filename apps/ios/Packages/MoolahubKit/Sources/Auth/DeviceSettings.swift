import Foundation
import Observation

/// Per-device preferences (not per account). Survive sign-out; wiped by
/// Developer settings "Reset" and by reinstalling.
@MainActor
@Observable
public final class DeviceSettings {
    private enum Key {
        static let appLockEnabled = "device.appLockEnabled"
        static let appLockOffered = "device.appLockOffered"
        static let showTechnicalDetails = "device.showTechnicalDetails"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Face ID / passcode lock on launch and after time in the background.
    public var appLockEnabled: Bool {
        didSet { defaults.set(appLockEnabled, forKey: Key.appLockEnabled) }
    }

    /// The one-time "Use Face ID to open MoolaHub" offer has been shown.
    public var appLockOffered: Bool {
        didSet { defaults.set(appLockOffered, forKey: Key.appLockOffered) }
    }

    /// Technical details toggle (Account → Technical details). Off by default.
    public var showTechnicalDetails: Bool {
        didSet { defaults.set(showTechnicalDetails, forKey: Key.showTechnicalDetails) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appLockEnabled = defaults.bool(forKey: Key.appLockEnabled)
        appLockOffered = defaults.bool(forKey: Key.appLockOffered)
        showTechnicalDetails = defaults.bool(forKey: Key.showTechnicalDetails)
    }

    /// Back to first-launch values.
    public func reset() {
        appLockEnabled = false
        appLockOffered = false
        showTechnicalDetails = false
    }
}
