import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// The Activity receipt (DESIGN.md v2 B2.7, J7): a move reopened from an
/// Activity or Home row, drawn as the receipt the person saw when it happened.
/// AppFeature presents it for `AppSheet.activityReceipt(item)`; rows open it
/// with `services.navigator.present(.activityReceipt(item))`.
///
/// Data: the tapped item itself. When it opens on a Processing item it reads
/// `GET /activity?limit=100` once; if an item with the same `id` is in the
/// response its status replaces the shown one, otherwise nothing changes. No
/// polling and never a guess. `txHash` is never shown.
public struct ActivityReceiptSheet: View {
    private let item: ActivityItem
    private let services: AppServices

    @Environment(\.dismiss) private var dismiss
    @State private var status: MoveStatus

    public init(item: ActivityItem, services: AppServices) {
        self.item = item
        self.services = services
        _status = State(initialValue: item.status)
    }

    private var direction: MoneyDirection {
        guard let cents = item.amountCents else { return .none }
        return cents > 0 ? .moneyIn : (cents < 0 ? .moneyOut : .none)
    }

    /// The amount's magnitude; the sign comes from `direction` (A1.8 rule 3).
    private var magnitude: Money? {
        item.amountCents.map { Money(cents: $0 == .min ? .max : abs($0)) }
    }

    public var body: some View {
        NavigationStack {
            ReceiptStep(
                status: status,
                title: item.description,
                amount: magnitude,
                amountDirection: direction,
                amountIdentifier: "activity.receipt.amount",
                rows: [
                    DetailRow("Type", .text(item.kind.spokenWord)),
                    DetailRow("Date", .text(MoolaDates.dateAndTime(item.createdAt))),
                ],
                processingNote: "This can take a few minutes.",
                failedTitle: nil,
                onDone: { dismiss() }
            )
            // One container element carries the sheet's identifier, so it is not
            // copied onto the rows and the "Done" button inside.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("activity.receipt")
        }
        .sheetChrome([.large])
        .task { await refreshOnceIfProcessing() }
    }

    private func refreshOnceIfProcessing() async {
        guard item.status == .processing else { return }
        let api = services.api
        let id = item.id
        do throws(APIError) {
            let items = try await api.send(API.Activity.list(limit: 100))
            if let match = items.first(where: { $0.id == id }) {
                status = match.status
            }
        } catch {
            // A failed read changes nothing: the sheet already says Processing.
        }
    }
}
