import Foundation

/// The toast Welcome shows after the account was closed on this device
/// (account.md §8). Auth holds no words: FeatureAuth maps `.deactivated` to
/// "Account deactivated." and `.deleted` to "Account deleted.".
public enum ClosedAccountToast: Equatable, Sendable {
    case deactivated
    case deleted
}

/// Where the signed-out flow starts for a `SignedOutReason` (SPEC §8.2 item
/// 5, D-43). `AuthFlowView` turns `.signIn` into the path `[.signIn]` and
/// `.welcome` into `[]`.
public enum SignedOutArrival: Equatable, Sendable {
    case welcome(toast: ClosedAccountToast?)
    case signIn

    public static func route(for reason: SignedOutReason?) -> SignedOutArrival {
        switch reason {
        case .sessionExpired, .passwordReset, .serverChanged:
            .signIn
        case .userSignedOut, nil:
            .welcome(toast: nil)
        case .accountDeactivated:
            .welcome(toast: .deactivated)
        case .accountDeleted:
            .welcome(toast: .deleted)
        }
    }
}
