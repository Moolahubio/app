import Auth
import DesignSystem
import Domain
import Observation
import SwiftUI

// What the Account screens share (DESIGN.md v2 B5.0). The rows, groups,
// fields and pinned bar are DesignSystem's (A8.21, A8.26, A8.30); this file
// only holds the tab's routes, the state its screens hand each other, and the
// header's initials.

/// Pushes inside the Account tab's `NavigationStack`. Registered by
/// `AccountRootView`.
enum AccountRoute: Hashable, Sendable {
    case profile
    case security
    case changePassword
    case notifications
    case technicalDetails
    case about
    case disclosure(AccountDisclosure)
    /// Delete account (B5.16): the pre-check before any password is asked.
    case deleteAccount
}

/// What the account step-up sheet confirms (B5.15). One sheet serves both;
/// its button carries the action's verb (AC-D6).
enum AccountStepUpAction: String, Hashable, Sendable {
    case deactivate
    case delete

    /// W10.9-acc3, W10.1-acc1.
    var submitTitle: String {
        switch self {
        case .deactivate: "Deactivate account"
        case .delete: "Delete account"
        }
    }

    /// W10.9-acc4; "Deleting…" exists.
    var loadingTitle: String {
        switch self {
        case .deactivate: "Deactivating\u{2026}"
        case .delete: "Deleting\u{2026}"
        }
    }

    /// How the session ends after the server says yes (account.md §7).
    var closedReason: SignedOutReason {
        switch self {
        case .deactivate: .accountDeactivated
        case .delete: .accountDeleted
        }
    }
}

/// Sheets the Account screens present themselves (not `AppSheet`: only
/// Account opens them). Account presents the deactivate step-up; Delete
/// account the delete one.
enum AccountSheet: Hashable, Identifiable {
    case stepUp(AccountStepUpAction)

    var id: String {
        switch self {
        case .stepUp(let action): "stepUp-\(action.rawValue)"
        }
    }
}

/// State the Account screens hand to each other across pushes: the
/// "Password updated." toast shows on Security after Change password pops,
/// and Change password starts from the two-factor status Security already
/// loaded, so its fields are final when it appears (B5.5).
@MainActor
@Observable
final class AccountFlowState {
    var securityToast: String?
    var twoFactorStatus: TwoFactorStatus?
}

/// Where content starts and how wide it runs on the Account screens (B5.0,
/// A3.2 ruling 10): pushed screens 16 pt below the inline bar, the tab root
/// 8 pt below the large title; rows are full width and carry their own
/// 16 pt gutter, everything else is inset by the gutter.
enum AccountLayout {
    /// First content below an inline navigation bar.
    static let pushedTop: CGFloat = Spacing.space4
    /// First content below the large title on the tab root.
    static let rootTop: CGFloat = Spacing.space2
    /// The status block (ErrorBanner, freshness line) to the first content (A3.2).
    static let statusToContent: CGFloat = Spacing.space6
}

/// Initials for the Account header avatar (B5.1): first letter of the first
/// and last words of `name` ("Ama Owusu" → "AO").
enum AccountInitials {
    static func of(_ name: String) -> String? {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        let first = words.first?.first(where: { $0.isLetter || $0.isNumber })
        let last = words.count > 1 ? words.last?.first(where: { $0.isLetter || $0.isNumber }) : nil
        let letters = [first, last].compactMap { $0 }
        return letters.isEmpty ? nil : String(letters).uppercased()
    }
}

/// Line breaking for an email shown on screen (B5.1, B5.3: emails wrap at
/// accessibility sizes). An address has no spaces, so a long one would break
/// mid-word ("moolahub.tes" / "t"); a zero-width space after "@" gives the
/// line a break point there. Display only: VoiceOver and the tests read the
/// address itself.
enum AccountEmail {
    static func breakable(_ email: String) -> String {
        email.replacingOccurrences(of: "@", with: "@\u{200B}")
    }
}

