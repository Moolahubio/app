import Foundation

// Words for groups that DesignSystem's group components draw (W9.2, W9.3,
// W10-SG). DesignSystem has no test target, so they are built and tested here.

public enum GroupWords {
    /// The card's type line: "Take turns · Monthly · 4 members" for active and
    /// completed groups; "Take turns · Monthly" for forming groups (and any
    /// unknown status), whose footer already counts who joined. A missing
    /// frequency drops its part.
    public static func typeLine(kind: GroupKind, frequency: GroupFrequency?, status: GroupStatus, memberCount: Int) -> String {
        var parts = [kind.label]
        if let frequency { parts.append(frequency.label) }
        switch status {
        case .active, .completed: parts.append(Self.memberCount(memberCount))
        case .forming, .other: break
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "1 member" / "4 members" (W10-SG-11).
    public static func memberCount(_ count: Int) -> String {
        count == 1 ? "1 member" : "\(count) members"
    }

    /// A member row's second line. Save together: "Savings returned" once the
    /// member is paid out (W10-SG-13), else "Saving" (`state` is not read).
    /// Take turns: from the payout order.
    public static func memberSecondary(kind: GroupKind, state: MemberPayoutState, payoutRound: Int, paidOut: Bool) -> String {
        guard kind == .takeTurns else { return paidOut ? "Savings returned" : "Saving" }
        switch state {
        case .paid: return "Received payout"
        case .current: return "Receiving this round"
        case .upcoming, .other: return "Payout in round \(payoutRound)"
        }
    }
}

/// A pay-in's status on Group detail: the matching Activity move's status, or
/// unavailable when no move matches (never a guessed "Done").
public enum PayInStatus: Hashable, Sendable {
    case known(MoveStatus)
    case unavailable

    /// "Status unavailable" (W10-SG-14), otherwise the move status's words.
    public var accessibilityLabel: String {
        switch self {
        case .known(let status): status.accessibilityLabel
        case .unavailable: "Status unavailable"
        }
    }
}
