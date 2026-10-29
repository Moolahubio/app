import Foundation

// Account and sign-in rules (account.md §5, §10, §11; SPEC §4.3, §4.6, D-14,
// D-16, D-17, D-43). Pure, so `AccountRulesTests` covers them; FeatureAccount
// and FeatureAuth only draw what these return. The send warning's sentences
// name USDC, so they stay in `FeatureAccount/TechnicalDetailsView.swift` (on
// the copy check's allow-list); `SendWarningRule` returns booleans only.

/// Delete account's pre-check (B5.16): what still stands in the way, in the
/// server's order of refusals (balance, then groups, then goals), from the
/// screen's three uncached reads. A met condition draws no row.
public enum DeleteAccountPrecheck {
    /// One unmet condition: one row on the Delete account screen.
    public enum Blocker: Hashable, Sendable {
        /// `totalCents > 0`: the exact total (goal money is part of it).
        case balance(Money)
        /// `balanceUnavailable == true`: blocks, with no figure.
        case balanceUnknown
        /// Groups whose status is "forming" or "active".
        case groups(count: Int)
        /// Active goals. `afterBalance` while a balance row shows above it:
        /// deleting a funded goal moves its money into the balance, which
        /// keeps blocking (D-17).
        case goals(count: Int, afterBalance: Bool)
    }

    /// The screen's state after its three reads.
    public enum Outcome: Hashable, Sendable {
        /// Nothing in the way: "Delete account" is enabled.
        case clear
        case blocked([Blocker])
        /// A read failed. Never `.clear`: the person must not reach step-up
        /// on a guess.
        case error

        /// The rows to draw; none for `.clear` and `.error`.
        public var blockers: [Blocker] {
            if case .blocked(let blockers) = self { return blockers }
            return []
        }
    }

    /// Group statuses that block deletion (the server's `deletionBlocker`).
    /// "completed" and any other value do not.
    public static let blockingGroupStatuses: Set<String> = ["forming", "active"]

    /// The unmet conditions, in the server's order. `circleStatuses` are the
    /// `status` of every group in `GET /circles`; `goalCount` is the length of
    /// `GET /goals` (active goals only).
    public static func blockers(
        totalCents: Int64,
        balanceUnavailable: Bool?,
        circleStatuses: [String],
        goalCount: Int
    ) -> [Blocker] {
        var blockers: [Blocker] = []
        if balanceUnavailable == true {
            blockers.append(.balanceUnknown)
        } else if totalCents > 0 {
            blockers.append(.balance(Money(cents: totalCents)))
        }
        let hasBalanceRow = !blockers.isEmpty
        let groups = circleStatuses.filter { blockingGroupStatuses.contains($0) }.count
        if groups > 0 {
            blockers.append(.groups(count: groups))
        }
        if goalCount > 0 {
            blockers.append(.goals(count: goalCount, afterBalance: hasBalanceRow))
        }
        return blockers
    }

    /// The outcome of `GET /dashboard/summary`, `GET /circles` and
    /// `GET /goals`: `.error` when any of them failed, else `.clear` or the
    /// blockers.
    public static func outcome<Failure: Error>(
        summary: Result<DashboardSummary, Failure>,
        circles: Result<[CircleSummary], Failure>,
        goals: Result<[Goal], Failure>
    ) -> Outcome {
        guard case .success(let summary) = summary,
              case .success(let circles) = circles,
              case .success(let goals) = goals
        else { return .error }
        let blockers = blockers(
            totalCents: summary.totalCents,
            balanceUnavailable: summary.balanceUnavailable,
            circleStatuses: circles.map(\.status),
            goalCount: goals.count
        )
        return blockers.isEmpty ? .clear : .blocked(blockers)
    }
}

extension DeleteAccountPrecheck.Blocker {
    /// The row's title (W10.9-acc9, W10.9-acc11; "Total balance" exists).
    public var title: String {
        switch self {
        case .balance, .balanceUnknown: "Total balance"
        case .groups: "Forming or active groups"
        case .goals: "Goals"
        }
    }

    /// The trailing value: the exact amount or the count. Nil for an unknown
    /// balance, which never shows a figure (never $0.00).
    public var value: String? {
        switch self {
        case .balance(let total): total.formatted()
        case .balanceUnknown: nil
        case .groups(let count), .goals(let count, _): "\(count)"
        }
    }

    /// The sub-line under the title (W10.9-acc7, acc8, acc10, acc12, acc17).
    /// "$0.00" comes from `Money`, never typed.
    public var subline: String {
        switch self {
        case .balance:
            "Needs to be \(Money.zero.formatted()). Cashing out isn't available yet."
        case .balanceUnknown:
            "We couldn't read your balance just now. Try again in a few minutes."
        case .groups:
            "Leaving a group isn't available yet. You can delete a group you started before anyone joins."
        case .goals(_, let afterBalance):
            afterBalance ? "Money in a goal counts toward your balance." : "Delete them first."
        }
    }

    /// The row's VoiceOver value (D-14): the value, then the sub-line, so a
    /// person with hints off still hears why. Money in words; an unknown
    /// balance says W10.8-acc3 "Not available".
    public var accessibilityValue: String {
        switch self {
        case .balance(let total):
            "\(total.accessibilityText()). Needs to be \(Money.zero.accessibilityText()). Cashing out isn't available yet."
        case .balanceUnknown:
            "Not available. \(subline)"
        case .groups(let count), .goals(let count, _):
            "\(count). \(subline)"
        }
    }
}

/// The names Sign up shows for the seven server keys of "How did you hear
/// about MoolaHub?" (W10.9-acc16, B1.14 amended). The keys never change.
public enum ReferralSourceNames {
    public static func displayName(_ source: ReferralSource) -> String {
        switch source {
        case .twitter: "X (Twitter)"
        case .telegram: "Telegram"
        case .whatsApp: "WhatsApp"
        case .discord: "Discord"
        case .linkedIn: "LinkedIn"
        case .friends: "Friends or family"
        case .others: "Somewhere else"
        }
    }

    /// The eighth choice, after a divider: clears an earlier pick and sends
    /// nothing.
    public static let preferNotToSay = "Prefer not to say"
}

/// One choice in Sign up's referral menu: a server key, or "Prefer not to
/// say". No choice at all (the placeholder "Choose one") is `nil`.
public enum ReferralChoice: Hashable, Sendable {
    case source(ReferralSource)
    case preferNotToSay

    /// The seven keys in the server's order; "Prefer not to say" follows them
    /// after a divider.
    public static let sources: [ReferralChoice] = ReferralSource.allCases.map { .source($0) }

    public var displayName: String {
        switch self {
        case .source(let source): ReferralSourceNames.displayName(source)
        case .preferNotToSay: ReferralSourceNames.preferNotToSay
        }
    }

    /// What `POST /auth/register` sends: the key, or nothing for "Prefer not
    /// to say".
    public var sentSource: ReferralSource? {
        if case .source(let source) = self { return source }
        return nil
    }
}

/// Technical details' send-only warning (A12, B5.7 amended). The banner shows
/// exactly when the account address shows with its Copy button, so no Copy
/// ever appears without the warning.
public enum SendWarningRule {
    /// True when the address is present and not empty: the address row then
    /// shows it with Copy, and the warning shows.
    public static func showsSendWarning(address: String?) -> Bool {
        guard let address else { return false }
        return !address.isEmpty
    }

    /// The warning's third sentence ("isn't added to your balance yet") shows
    /// only while the server does not credit deposits to this address.
    public static func includesNotAddedSentence(syncEnabled: Bool) -> Bool {
        !syncEnabled
    }
}
