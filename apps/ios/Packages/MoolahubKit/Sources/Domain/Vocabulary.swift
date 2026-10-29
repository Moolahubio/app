import Foundation

// Mappings from raw API strings to the app's vocabulary. Raw values stay
// strings on the DTOs so a new server value never breaks decoding; these
// types interpret them.

// MARK: - Goal icons (DESIGN.md §5)

/// The 12 goal icons. The API stores a goal's icon in `emoji` (the web shows
/// emoji); iOS shows the SF Symbol and sends the paired emoji so the web keeps
/// working. Unmatched emoji (goals made on the web) show `target`.
public enum GoalIcon: String, CaseIterable, Hashable, Sendable {
    case goal, home, car, travel, education, emergencyFund, wedding, gift, business, health, pets, tech

    public var symbolName: String {
        switch self {
        case .goal: "target"
        case .home: "house.fill"
        case .car: "car.fill"
        case .travel: "airplane"
        case .education: "graduationcap.fill"
        case .emergencyFund: "umbrella.fill"
        case .wedding: "heart.fill"
        case .gift: "gift.fill"
        case .business: "briefcase.fill"
        case .health: "cross.case.fill"
        case .pets: "pawprint.fill"
        case .tech: "laptopcomputer"
        }
    }

    /// Exact string sent as `emoji` on create, including variation selectors.
    public var emoji: String {
        switch self {
        case .goal: "\u{1F3AF}"
        case .home: "\u{1F3E0}"
        case .car: "\u{1F697}"
        case .travel: "\u{2708}\u{FE0F}"
        case .education: "\u{1F393}"
        case .emergencyFund: "\u{2602}\u{FE0F}"
        case .wedding: "\u{2764}\u{FE0F}"
        case .gift: "\u{1F381}"
        case .business: "\u{1F4BC}"
        case .health: "\u{1F3E5}"
        case .pets: "\u{1F43E}"
        case .tech: "\u{1F4BB}"
        }
    }

    /// Picker label and VoiceOver label.
    public var label: String {
        switch self {
        case .goal: "Goal"
        case .home: "Home"
        case .car: "Car"
        case .travel: "Travel"
        case .education: "Education"
        case .emergencyFund: "Emergency fund"
        case .wedding: "Wedding"
        case .gift: "Gift"
        case .business: "Business"
        case .health: "Health"
        case .pets: "Pets"
        case .tech: "Tech"
        }
    }

    /// Matches an API `emoji` after removing U+FE0F from both sides.
    public init(emoji: String?) {
        let wanted = Self.strippingVariationSelector(emoji ?? "")
        self = Self.allCases.first { Self.strippingVariationSelector($0.emoji) == wanted } ?? .goal
    }

    private static func strippingVariationSelector(_ text: String) -> [Unicode.Scalar] {
        text.unicodeScalars.filter { $0.value != 0xFE0F }
    }

    /// Goals are created with this color (DESIGN.md §5).
    public static let apiColor = "jade"
}

// MARK: - Activity (DESIGN.md §4.17)

public enum ActivityKind: Hashable, Sendable {
    case deposit, payout, earnings, contribution, goalAllocate, goalRelease, withdrawal, fee, inviteReward, other

    public init(type: String) {
        switch type {
        case "deposit": self = .deposit
        case "payout": self = .payout
        case "yield": self = .earnings
        case "contribution": self = .contribution
        case "goal_allocate": self = .goalAllocate
        case "goal_release": self = .goalRelease
        case "withdrawal": self = .withdrawal
        case "fee": self = .fee
        case "referral_earning", "referral_withdrawal": self = .inviteReward
        default: self = .other
        }
    }

    /// One symbol per meaning (DESIGN.md v2 A7.3, W9.4).
    public var symbolName: String {
        switch self {
        case .deposit: "plus.circle"
        case .payout: "arrow.down.left"
        case .earnings: "chart.line.uptrend.xyaxis"
        case .contribution: "arrow.turn.up.right"
        case .goalAllocate: "tray.and.arrow.down"
        case .goalRelease: "tray.and.arrow.up"
        case .withdrawal: "arrow.up.right"
        case .fee: "percent"
        case .inviteReward: "gift"
        case .other: "arrow.left.arrow.right"
        }
    }

    /// The word VoiceOver reads first ("Money added. Test money added. …").
    public var spokenWord: String {
        switch self {
        case .deposit: "Money added"
        case .payout: "Your payout"
        case .earnings: "Earnings"
        case .contribution: "Paid in"
        case .goalAllocate: "Moved to goal"
        case .goalRelease: "Moved to balance"
        case .withdrawal: "Cash out"
        case .fee: "Fee"
        case .inviteReward: "Invite reward"
        case .other: "Money moved"
        }
    }
}

/// Status of a money move, from `onchainStatus` (DESIGN.md §4.15).
/// `none` means the move settled on the ledger with nothing left to do, so it
/// is done. Unknown values are never shown as done.
public enum MoveStatus: Hashable, Sendable {
    case done
    case processing
    case failed

    public init(onchainStatus: String?) {
        switch onchainStatus {
        case "none", "confirmed": self = .done
        case "failed": self = .failed
        default: self = .processing
        }
    }

    public var label: String {
        switch self {
        case .done: "Done"
        case .processing: "Processing\u{2026}"
        case .failed: "Didn't go through"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .done: "Done"
        case .processing: "Processing"
        case .failed: "Didn't go through, nothing was taken"
        }
    }
}

// MARK: - Groups (circles)

/// "Take turns" (`rotation`) or "Save together" (`accumulation`). The server
/// treats anything that isn't `accumulation` as rotation.
public enum GroupKind: String, Hashable, Sendable, CaseIterable {
    case takeTurns = "rotation"
    case saveTogether = "accumulation"

    public init(apiValue: String) {
        self = apiValue == "accumulation" ? .saveTogether : .takeTurns
    }

    public var label: String {
        switch self {
        case .takeTurns: "Take turns"
        case .saveTogether: "Save together"
        }
    }
}

public enum GroupStatus: Hashable, Sendable {
    case forming, active, completed, other(String)

    public init(apiValue: String) {
        switch apiValue {
        case "forming": self = .forming
        case "active": self = .active
        case "completed": self = .completed
        default: self = .other(apiValue)
        }
    }

    public var label: String {
        switch self {
        case .forming: "Forming"
        case .active: "Active"
        case .completed: "Completed"
        case .other: "Pending"
        }
    }
}

public enum GroupFrequency: String, Hashable, Sendable, CaseIterable {
    case weekly
    case biweekly
    case monthly

    public init?(apiValue: String) {
        self.init(rawValue: apiValue)
    }

    /// Segmented control label: "Weekly", "Every 2 weeks", "Monthly".
    public var label: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Every 2 weeks"
        case .monthly: "Monthly"
        }
    }

    /// In-sentence word: "weekly", "every 2 weeks", "monthly".
    public var word: String {
        switch self {
        case .weekly: "weekly"
        case .biweekly: "every 2 weeks"
        case .monthly: "monthly"
        }
    }
}

/// A member's place in a take-turns payout order.
public enum MemberPayoutState: Hashable, Sendable {
    case paid, current, upcoming, other(String)

    public init(apiValue: String) {
        switch apiValue {
        case "paid": self = .paid
        case "current": self = .current
        case "upcoming": self = .upcoming
        default: self = .other(apiValue)
        }
    }
}

// MARK: - Notification preferences

public enum NotificationPreferenceLevel: String, CaseIterable, Hashable, Sendable {
    case everything, essential, minimal, custom
}
