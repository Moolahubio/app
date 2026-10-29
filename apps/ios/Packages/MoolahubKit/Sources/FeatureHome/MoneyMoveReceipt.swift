import APIClient
import Domain
import Foundation
import Observation

/// Finds the Activity item a money move produced (DESIGN.md v2 J0.6): the newest
/// item with the expected `type` and signed `amountCents` whose `createdAt` is
/// no earlier than 5 seconds before the request was sent.
enum ActivityMatcher {
    static let clockAllowance: TimeInterval = 5

    static func newestMatch(
        in items: [ActivityItem],
        type: String,
        amountCents: Int64,
        sentAt: Date
    ) -> ActivityItem? {
        let earliest = sentAt.addingTimeInterval(-clockAllowance)
        return items
            .filter { $0.type == type && $0.amountCents == amountCents && $0.createdAt >= earliest }
            .max { $0.createdAt < $1.createdAt }
    }
}

/// The receipt's status, decided only by matching `GET /activity?limit=10`
/// at 0s, 1s and 3s after the move succeeded (DESIGN.md v2 J0.6). Until a
/// matching item says otherwise it is "Processing…"; it never guesses "Done".
@MainActor
@Observable
final class MoneyMoveReceipt {
    let amount: Money
    /// When the request was sent (the matching window starts 5s before).
    let sentAt: Date
    let expectedType: String
    /// Signed relative to the balance, as Activity reports it.
    let expectedAmountCents: Int64

    private(set) var status: MoveStatus = .processing
    /// The matched item's time, once found.
    private(set) var matchedAt: Date?

    /// Seconds after the receipt opens at which Activity is checked.
    static let checkOffsets: [Int] = [0, 1, 3]

    init(amount: Money, sentAt: Date, expectedType: String, expectedAmountCents: Int64) {
        self.amount = amount
        self.sentAt = sentAt
        self.expectedType = expectedType
        self.expectedAmountCents = expectedAmountCents
    }

    /// The receipt's "Date" row: the matched item's time, else when it was sent.
    var date: Date { matchedAt ?? sentAt }

    /// Runs the three checks. Read-only requests, so a failed check just moves
    /// on to the next one. Stops early once the move is settled (done or failed).
    func resolve(using api: APIClient) async {
        let clock = ContinuousClock()
        let start = clock.now
        for offset in Self.checkOffsets {
            do {
                try await clock.sleep(until: start.advanced(by: .seconds(offset)))
            } catch {
                return // the receipt went away
            }
            let items: [ActivityItem]
            do {
                items = try await api.send(API.Activity.list(limit: 10))
            } catch {
                continue
            }
            if let item = ActivityMatcher.newestMatch(
                in: items, type: expectedType, amountCents: expectedAmountCents, sentAt: sentAt
            ) {
                status = item.status
                matchedAt = item.createdAt
                if item.status != .processing { return }
            }
        }
    }
}
