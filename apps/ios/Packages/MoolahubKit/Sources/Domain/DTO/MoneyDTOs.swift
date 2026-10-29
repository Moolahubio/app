import Foundation

// MARK: - Dashboard and wallet

/// `DashboardSummary` (`GET /dashboard/summary`). `yieldApy` (if a server still
/// sends it) is deliberately not decoded: it was a hard-coded number.
public struct DashboardSummary: Codable, Hashable, Sendable {
    public let availableCents: Int64
    public let totalCents: Int64
    public let goalTotalCents: Int64
    /// Outflows still settling.
    public let pendingCents: Int64?
    /// True when a balance read failed, so figures may be understated.
    public let balanceUnavailable: Bool?
    public let circlePotCents: Int64
    public let recentActivity: [ActivityItem]
    public let activeGoals: [Goal]
    public let activeCircles: [CircleSummary]
    public let lessonsCompleted: Int
    public let totalLessons: Int
    /// Decoded, never shown (home.md HD3): `upcomingPayIn` replaces it on iOS.
    public let upcomingReminder: Reminder?
    /// The pay-in the person owes now, or nil (an absent key, from a server
    /// before it was added, and `null` both mean no notice).
    public let upcomingPayIn: UpcomingPayIn?

    public var available: Money { Money(cents: availableCents) }
    public var total: Money { Money(cents: totalCents) }
    public var inGoals: Money { Money(cents: goalTotalCents) }
    public var pending: Money { Money(cents: pendingCents ?? 0) }
}

/// `Reminder`.
public struct Reminder: Codable, Hashable, Sendable {
    public let title: String
    public let amountCents: Int64
    public let dueDate: Date
}

/// `UpcomingPayIn` (dashboard `upcomingPayIn`): the group whose round the
/// person still owes a pay-in for. No date is sent, derived or shown.
public struct UpcomingPayIn: Codable, Hashable, Sendable {
    public let circleId: String
    public let circleName: String
    public let amountCents: Int64
    public let round: Int
    public let totalRounds: Int

    public var amount: Money { Money(cents: amountCents) }
}

/// `WalletInfo` (`GET /wallet`). Address, network and custody are technical
/// details: show them only on the Technical details screen.
public struct WalletInfo: Codable, Hashable, Sendable {
    public let availableCents: Int64
    public let totalCents: Int64
    public let goalAllocatedCents: Int64
    public let pendingCents: Int64?
    public let balanceUnavailable: Bool?
    public let address: String?
    public let network: String
    public let onchainEnabled: Bool
    public let hasWallet: Bool
    public let faucetEnabled: Bool
    public let syncEnabled: Bool
    public let custody: String?
    public let usdcAddress: String?

    public var available: Money { Money(cents: availableCents) }
    public var total: Money { Money(cents: totalCents) }
    public var inGoals: Money { Money(cents: goalAllocatedCents) }
}

/// `AmountInput` (`/wallet/deposit`, `/goals/{id}/allocate`).
public struct AmountInput: Encodable, Hashable, Sendable {
    public var amountCents: Int64

    public init(amount: Money) {
        self.amountCents = amount.cents
    }
}

// MARK: - Goals

/// `Goal` (`GET /goals`, `GET /goals/{id}`, `POST /goals`).
public struct Goal: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let emoji: String
    public let color: String
    public let targetCents: Int64
    public let savedCents: Int64
    /// True when this goal's balance read failed ("May be out of date").
    public let balanceUnavailable: Bool?
    /// UTC-midnight instant. Format with `APIDate.formatUTCDay`.
    public let deadline: Date
    public let frequency: String
    public let autoSaveCents: Int64?
    public let createdAt: Date
    public let imageUrl: String?
    public let onchain: Bool?
    public let vaultAddress: String?
    public let explorerUrl: String?
    public let network: String?
    public let feeBps: Int?
    /// Latest moves (at most 25), newest first. Only on `GET /goals/{id}`.
    public let history: [GoalHistoryItem]?

    public var target: Money { Money(cents: targetCents) }
    public var saved: Money { Money(cents: savedCents) }
    public var icon: GoalIcon { GoalIcon(emoji: emoji) }
    public var goalFrequency: GoalFrequency { GoalFrequency(apiValue: frequency) }
    public var feeRate: FeeRate { FeeRate(basisPoints: feeBps ?? 0) }

    public func pace(now: Date = Date(), calendar: Calendar = .current) -> GoalPace {
        GoalPace.evaluate(
            targetCents: targetCents, savedCents: savedCents, createdAt: createdAt,
            deadline: deadline, frequency: goalFrequency, now: now, calendar: calendar
        )
    }
}

/// `GoalHistoryItem`. Amounts are signed relative to the goal
/// (positive = moved in).
public struct GoalHistoryItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let amountCents: Int64
    public let txHash: String?
    public let onchainStatus: String
    public let createdAt: Date

    public var amount: Money { Money(cents: amountCents) }
    public var status: MoveStatus { MoveStatus(onchainStatus: onchainStatus) }
}

/// `GoalInput` (`POST /goals`). `deadline` is `yyyy-MM-dd`
/// (`APIDate.dayString(from:)`); `color` is always `"jade"`.
public struct GoalInput: Encodable, Sendable {
    public var name: String
    public var emoji: String
    public var color: String
    public var targetCents: Int64
    public var deadline: String
    public var frequency: String

    public init(name: String, icon: GoalIcon, target: Money, deadline: String, frequency: GoalFrequency) {
        self.name = name
        self.emoji = icon.emoji
        self.color = GoalIcon.apiColor
        self.targetCents = target.cents
        self.deadline = deadline
        self.frequency = frequency.rawValue
    }
}

/// `ReleaseFromGoalInput` (`POST /goals/{id}/release`).
public struct ReleaseFromGoalInput: Encodable, Sendable {
    public var amountCents: Int64
    public var currentPassword: Secret?
    public var twoFactorCode: Secret?

    public init(amount: Money, proof: StepUpProof) {
        self.amountCents = amount.cents
        self.currentPassword = proof.currentPassword
        self.twoFactorCode = proof.twoFactorCode
    }
}

/// `ReleaseFromGoalResult`. Show the server's numbers on the receipt.
public struct ReleaseFromGoalResult: Codable, Hashable, Sendable {
    public let ok: Bool
    public let grossCents: Int64
    public let netCents: Int64
    public let feeCents: Int64
}

/// `DeleteGoalResult`.
public struct DeleteGoalResult: Codable, Hashable, Sendable {
    public let ok: Bool
    public let withdrawnGrossCents: Int64
    public let withdrawnNetCents: Int64
    public let feeCents: Int64
}

// MARK: - Activity

/// `ActivityItem` (`GET /activity`, dashboard `recentActivity`). Amounts are
/// signed relative to the user's balance (positive = money in).
public struct ActivityItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let type: String
    /// Plain-language title written by the server ("Test money added").
    public let description: String
    public let amountCents: Int64?
    public let txHash: String?
    public let onchainStatus: String?
    public let createdAt: Date

    public var amount: Money? { amountCents.map { Money(cents: $0) } }
    public var kind: ActivityKind { ActivityKind(type: type) }
    public var status: MoveStatus { MoveStatus(onchainStatus: onchainStatus) }
}
