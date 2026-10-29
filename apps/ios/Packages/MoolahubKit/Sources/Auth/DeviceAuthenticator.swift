import Foundation
import LocalAuthentication

/// What the device can use for `.deviceOwnerAuthentication`.
public enum BiometryKind: Hashable, Sendable {
    case faceID
    case touchID
    case opticID
    /// A passcode is set but no biometry is enrolled.
    case passcode
    /// No passcode: app lock and confirm prompts are unavailable.
    case unavailable

    /// "Face ID", "Touch ID", "Optic ID", "passcode".
    public var name: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode, .unavailable: "passcode"
        }
    }

    /// SF Symbol for buttons: `faceid`, `touchid`, `opticid`, `lock`.
    public var symbolName: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode, .unavailable: "lock"
        }
    }

    public var isAvailable: Bool { self != .unavailable }

    /// Review step button (DESIGN.md §4.13): "Confirm with Face ID", …,
    /// "Confirm" when the device has no passcode.
    public var confirmTitle: String {
        self == .unavailable ? "Confirm" : "Confirm with \(name)"
    }

    /// Lock screen button: "Unlock with Face ID".
    public var unlockTitle: String { "Unlock with \(name)" }
}

public enum DeviceAuthResult: Hashable, Sendable {
    case success
    /// The user cancelled (or the system did, e.g. the app went to background).
    case cancelled
    /// No passcode / biometry locked out with no fallback.
    case unavailable
    case failed
}

/// Face ID / Touch ID / passcode prompts (`LAPolicy.deviceOwnerAuthentication`).
/// This is a device-side convenience gate: the server's session and step-up
/// checks stay the authority.
public struct DeviceAuthenticator: Sendable {
    public init() {}

    public func biometryKind() -> BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        // `biometryType` names the hardware even when no face or finger is
        // enrolled; iOS then falls back to the passcode, so say "passcode"
        // (DESIGN.md §4.13: "Confirm with passcode", lock symbol).
        var biometricsError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricsError) else {
            return .passcode
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        case .none: return .passcode
        @unknown default: return .passcode
        }
    }

    /// Shows the system prompt. `reason` appears under the prompt (Touch ID and
    /// passcode); Face ID shows `NSFaceIDUsageDescription` the first time.
    public func authenticate(reason: String) async -> DeviceAuthResult {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            let ok = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return ok ? .success : .failed
        } catch let laError as LAError {
            switch laError.code {
            case .userCancel, .systemCancel, .appCancel, .userFallback:
                return .cancelled
            case .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
                return .unavailable
            default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Reason strings (DESIGN.md §4.13, §8.7).
    public enum Reason {
        public static let confirmMoneyMove = "Confirm this money move"
        public static let unlock = "Unlock MoolaHub"
        public static let enableAppLock = "Turn on app lock"
    }
}
