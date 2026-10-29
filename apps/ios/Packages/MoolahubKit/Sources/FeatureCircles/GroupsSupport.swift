import APIClient
import Auth
import DesignSystem
import Domain
import Foundation
import Observation
import SwiftUI

// Feature-internal helpers for Groups: copy that depends on values, the
// cross-screen toast hand-off, the receipt's Activity match and the skeleton
// lines that stand in for text while a screen loads. The ordering is Domain's
// `GroupsOrdering`, shared with Home.

// MARK: - Copy (DESIGN.md v2 B4, W9.2, W9.3, W10)

enum GroupsCopy {
    static let howGroupsWorkTitle = "How groups work"
    /// B4.9: v1's body split at its sentence boundaries; the take-turns
    /// paragraph gains the payout-order note (moved from Group detail, 2.1).
    static let howGroupsWorkParagraphs = [
        "A group is a savings circle, sometimes called a Susu. Everyone pays in a fixed amount each round.",
        "In a take-turns group, one person receives the pot each round until everyone has had a turn. The payout order is set when the group starts, so everyone knows who receives the pot, and when.",
        "In a save-together group, everyone saves into one pot and gets their own savings back at the end.",
    ]

    static let loadingGroups = "Loading your groups\u{2026}"
    static let loadingGroup = "Loading group\u{2026}"
    static let listErrorTitle = "We couldn't load your groups"
    static let invitesFailed = "We couldn't load your invitations."
    static let detailErrorTitle = "We couldn't load this group"
    static let notFound = "We couldn't find that group."
    static let backToGroups = "Back to groups"

    static let emptyTitle = "No groups yet"
    static let emptyBody = "Save with people you trust. Everyone pays in each round."

    static let takeTurnsDescription = "Everyone pays in each round. One person receives the pot each round until everyone has had a turn."
    static let saveTogetherDescription = "Everyone pays into one shared pot and gets their own savings back at the end."

    static let notStartedYet = "This group hasn't started yet."
    static let inviteOneMore = "Invite at least one more person to start the group."
    static let noPayIns = "No pay-ins yet."

    /// Create group's disabled reasons (W10.4).
    static let createReasonIncomplete = "Add a name and an amount to continue."
    static let createReasonOverLimit = "Remove an invitation to continue."

    /// Invite people's disabled reasons (W10.4).
    static let inviteFull = "This group is full."
    static let inviteEmpty = "Enter an email to send an invite."

    /// W10.5 field error, reused for invitation emails.
    static let invalidEmail = "Please enter a valid email address."

    /// "{n} people" with the singular for one ("1 person").
    static func people(_ count: Int) -> String {
        count == 1 ? "1 person" : "\(count) people"
    }

    /// "You can invite up to {n} people for this group."
    static func inviteLimit(_ count: Int) -> String {
        "You can invite up to \(people(count)) for this group."
    }

    /// "{n} spots left" / "1 spot left" (B4.24).
    static func spotsLeft(_ count: Int) -> String {
        count == 1 ? "1 spot left" : "\(count) spots left"
    }

    /// Frequency word for sentences ("monthly"); the raw value when unknown.
    static func frequencyWord(_ frequency: GroupFrequency?, raw: String) -> String {
        frequency?.word ?? raw
    }

    /// The middle-dot separator that keeps the dot at a line end
    /// (DesignSystem's `String.lineEndMiddleDot`).
    private static let separator = String.lineEndMiddleDot

    /// A label whose words never split across lines ("Take turns",
    /// "Every 2 weeks"): its spaces become no-break spaces.
    private static func unbroken(_ label: String) -> String {
        label.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    /// "Take turns · Monthly"; the kind alone for an unknown frequency (W9.2).
    static func typeLine(kind: GroupKind, frequency: GroupFrequency?) -> String {
        guard let frequency else { return unbroken(kind.label) }
        return "\(unbroken(kind.label))\(separator)\(unbroken(frequency.label))"
    }

    /// Group detail's status line, "Active · Take turns · Monthly" (W9.2).
    /// At accessibility sizes it wraps only after a dot, keeping each part
    /// whole ("Active ·" over "Take turns · Monthly").
    static func statusLine(_ group: CircleDetail) -> String {
        "\(unbroken(group.groupStatus.label))\(separator)\(typeLine(kind: group.kind, frequency: group.groupFrequency))"
    }

    /// The payout label over the hero figure (B4.13).
    static func payoutLabel(_ kind: GroupKind) -> String {
        kind == .takeTurns ? "Payout each round" : "You get back"
    }

    /// "Build your group" body (B4.15, tested exactly).
    static func formingBody(_ detail: CircleDetail) -> String {
        let memberCount = detail.memberCount ?? detail.members.count
        if let target = detail.targetMembers {
            return "\(memberCount) of \(target) have joined. The group starts automatically when the last person joins."
        }
        switch detail.kind {
        case .takeTurns:
            return "Invite people by email. Everyone gets exactly one payout. Start the group once everyone's in."
        case .saveTogether:
            return "Invite people by email. Everyone saves into one pot for \(detail.totalRounds) rounds, then gets their savings back. Start the group once everyone's in."
        }
    }

    /// The finished line in a completed group's action slot (B4.21).
    static func completedBody(_ kind: GroupKind) -> String {
        switch kind {
        case .takeTurns: "This group has finished. Everyone has received their payout."
        case .saveTogether: "This group has finished. Savings returned."
        }
    }

    /// "Each pay-in includes a {pct}% fee." (B4.13, tested).
    static func feeNote(_ rate: FeeRate) -> String {
        "Each pay-in includes a \(rate.percentText) fee."
    }
}

// MARK: - Toast hand-off between screens

/// Toasts that belong to the screen the user lands on after an action
/// ("Group created." on the new group's detail, "Group deleted." on the list).
@MainActor
final class GroupsToastCenter {
    static let shared = GroupsToastCenter()

    enum Destination: Hashable {
        case list
        case detail(String)
    }

    private var pending: [Destination: String] = [:]

    func post(_ message: String, to destination: Destination) {
        pending[destination] = message
    }

    func take(for destination: Destination) -> String? {
        pending.removeValue(forKey: destination)
    }
}

// MARK: - Receipt status (J0.6)

/// Decides a receipt's status only by finding the move in `GET /activity`.
enum ActivityReceiptMatcher {
    /// The newest item of `type` with exactly `amountCents`, created no earlier
    /// than 5 seconds before the request was sent.
    static func match(in items: [ActivityItem], type: String, amountCents: Int64, sentAt: Date) -> ActivityItem? {
        let earliest = sentAt.addingTimeInterval(-5)
        return items
            .filter { $0.type == type && $0.amountCents == amountCents && $0.createdAt >= earliest }
            .max { $0.createdAt < $1.createdAt }
    }

    /// What the receipt shows: the matched item's status and date, or
    /// Processing with no date while nothing matched (never a guessed Done).
    struct Resolution: Sendable {
        var status: MoveStatus = .processing
        var matchedAt: Date?
    }

    /// Reads `GET /activity?limit=10` at 0 s, 1 s and 3 s. A failed read is
    /// skipped and the receipt keeps its last known status.
    static func resolve(api: APIClient, type: String, amountCents: Int64, sentAt: Date) async -> Resolution {
        var resolution = Resolution()
        for delay in [0, 1, 2] {
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return resolution
                }
            }
            do throws(APIError) {
                let items = try await api.send(API.Activity.list(limit: 10))
                if let item = match(in: items, type: type, amountCents: amountCents, sentAt: sentAt) {
                    resolution = Resolution(status: item.status, matchedAt: item.createdAt)
                    if item.status != .processing { return resolution }
                }
            } catch {
                // Keep the last known status: a failed check is not a result.
            }
        }
        return resolution
    }
}
