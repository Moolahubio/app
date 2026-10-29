import Foundation

// "Circles" in the API are "groups" in the iOS UI (DESIGN.md §9.1).

/// `CircleSummary` (`GET /circles`, `POST /circles`, dashboard `activeCircles`).
public struct CircleSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let status: String
    public let type: String
    public let frequency: String
    public let contributionCents: Int64
    public let payoutCents: Int64
    /// Includes fees: never show it as what anyone receives.
    public let potCents: Int64
    public let memberCount: Int
    public let targetMembers: Int?
    public let feeBps: Int?
    public let myPayoutRound: Int?
    public let currentRound: Int
    public let totalRounds: Int
    public let nextPayoutDate: Date?
    public let imageUrl: String?

    public var kind: GroupKind { GroupKind(apiValue: type) }
    public var groupStatus: GroupStatus { GroupStatus(apiValue: status) }
    public var groupFrequency: GroupFrequency? { GroupFrequency(apiValue: frequency) }
    public var contribution: Money { Money(cents: contributionCents) }
    public var payout: Money { Money(cents: payoutCents) }
    public var feeRate: FeeRate { FeeRate(basisPoints: feeBps ?? 0) }
}

/// `CircleDetail` (`GET /circles/{id}`).
public struct CircleDetail: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let status: String
    public let type: String
    public let frequency: String
    public let contributionCents: Int64
    public let payoutCents: Int64
    public let potCents: Int64
    public let memberCount: Int?
    public let targetMembers: Int?
    public let currentRound: Int
    public let totalRounds: Int
    public let startDate: Date?
    /// Technical details only.
    public let contractAddress: String?
    public let feeBps: Int?
    public let explorerUrl: String?
    public let members: [CircleMember]
    public let history: [CircleContribution]?
    /// "paid" or "due".
    public let myContributionStatus: String?
    public let myPayoutRound: Int?
    public let imageUrl: String?
    public let isCreator: Bool?
    public let canInvite: Bool?
    public let canStart: Bool?
    public let canDelete: Bool?
    public let canContribute: Bool?
    public let pendingInvites: [CirclePendingInvite]?

    public var kind: GroupKind { GroupKind(apiValue: type) }
    public var groupStatus: GroupStatus { GroupStatus(apiValue: status) }
    public var groupFrequency: GroupFrequency? { GroupFrequency(apiValue: frequency) }
    public var contribution: Money { Money(cents: contributionCents) }
    public var payout: Money { Money(cents: payoutCents) }
    public var feeRate: FeeRate { FeeRate(basisPoints: feeBps ?? 0) }
}

/// `CircleMember`. `id` is a membership id, not a user id; `name` is the
/// member's username, or exactly `"Member"` when they have none.
public struct CircleMember: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let position: Int?
    public let payoutRound: Int
    public let state: String
    public let paidOut: Bool
    public let contributedThisRound: Bool?

    public var payoutState: MemberPayoutState { MemberPayoutState(apiValue: state) }

    /// True for the API's no-username fallback.
    public var isUnnamed: Bool { name == "Member" }

    /// Case-insensitive match against the signed-in user's username
    /// (DESIGN.md §4.9). A user without a username matches no one.
    public func isCurrentUser(username: String?) -> Bool {
        guard let username, !username.isEmpty, !isUnnamed else { return false }
        return name.caseInsensitiveCompare(username) == .orderedSame
    }
}

/// `CircleContribution` (the user's own pay-ins).
public struct CircleContribution: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let round: Int
    public let amountCents: Int64
    public let txHash: String?
    public let status: String
    public let createdAt: Date

    public var amount: Money { Money(cents: amountCents) }
    public var moveStatus: MoveStatus { MoveStatus(onchainStatus: status) }
}

/// `CirclePendingInvite`.
public struct CirclePendingInvite: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let email: String
}

/// `CircleInvite` (`GET /circles/invites`).
public struct CircleInvite: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let circleName: String
    public let inviterName: String
    public let contributionCents: Int64
    public let frequency: String

    public var contribution: Money { Money(cents: contributionCents) }
    public var groupFrequency: GroupFrequency? { GroupFrequency(apiValue: frequency) }
}

/// `CircleInput` (`POST /circles`). Use the two factory methods so the body
/// matches DESIGN.md §8.14 exactly.
public struct CircleInput: Encodable, Sendable {
    public var name: String
    public var type: String
    public var contributionCents: Int64?
    public var numRounds: Int?
    public var targetPayoutCents: Int64?
    public var groupSize: Int?
    public var frequency: String
    public var memberEmails: [String]

    /// Take turns: `{name, type: "rotation", targetPayoutCents: c × people, groupSize: people, frequency, memberEmails}`.
    public static func takeTurns(name: String, contribution: Money, people: Int, frequency: GroupFrequency, memberEmails: [String]) -> CircleInput {
        CircleInput(
            name: name, type: GroupKind.takeTurns.rawValue, contributionCents: nil, numRounds: nil,
            targetPayoutCents: contribution.cents * Int64(people), groupSize: people,
            frequency: frequency.rawValue, memberEmails: memberEmails
        )
    }

    /// Save together: `{name, type: "accumulation", contributionCents: c, numRounds: rounds, frequency, memberEmails}`.
    public static func saveTogether(name: String, contribution: Money, rounds: Int, frequency: GroupFrequency, memberEmails: [String]) -> CircleInput {
        CircleInput(
            name: name, type: GroupKind.saveTogether.rawValue, contributionCents: contribution.cents,
            numRounds: rounds, targetPayoutCents: nil, groupSize: nil,
            frequency: frequency.rawValue, memberEmails: memberEmails
        )
    }
}

/// `InviteInput` (`POST /circles/{id}/invite`).
public struct InviteInput: Encodable, Sendable {
    public var email: String
    public init(email: String) { self.email = email }
}
