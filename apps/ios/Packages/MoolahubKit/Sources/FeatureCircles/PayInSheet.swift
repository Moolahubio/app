import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Pay in (DESIGN.md v2 J5, B4.25, B4.26): a review of the fixed contribution,
/// Face ID confirm, `POST /circles/{id}/contribute` (one attempt, never
/// retried), and a receipt whose status comes only from matching
/// `GET /activity`. Failures follow J0.7 (ruling 2): an ErrorBanner over the
/// confirm button, titled for a refusal, with "View activity" after an
/// uncertain outcome.
struct PayInSheet: View {
    private let services: AppServices
    private let group: CircleDetail

    private enum Step: Equatable {
        case review
        case receipt
    }

    @State private var step: Step = .review
    @State private var wallet: RemoteResource<WalletInfo>
    @State private var isConfirming = false
    /// Set synchronously on the first tap so a second tap can't start another
    /// pay-in while Face ID (or its `.unavailable` answer) is pending.
    @State private var isAuthorizing = false
    @State private var note: String?
    @State private var errorTitle: String?
    @State private var errorMessage: String?
    @State private var isUncertain = false
    #if DEBUG
    @State private var showsAddTestMoney = false
    #endif
    @State private var receipt = ActivityReceiptMatcher.Resolution()
    @State private var sentAt = Date()
    @State private var failureTick = 0
    @State private var sendTick = 0

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(services: AppServices, group: CircleDetail) {
        self.services = services
        self.group = group
        let api = services.api
        // The maximum is read when the sheet opens and never cached; a balance
        // the server couldn't read is a failed read, never $0.00 (J0.8).
        _wallet = State(initialValue: RemoteResource {
            try await api.walletForMoneyMove()
        })
    }

    private var contribution: Money { group.contribution }

    private var roundText: String { "\(group.currentRound) of \(group.totalRounds)" }

    /// nil while the balance is loading or failed: never assumed zero.
    private var hasEnough: Bool? {
        guard let wallet = wallet.value else { return nil }
        return wallet.available >= contribution
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .review:
                    review
                case .receipt:
                    receiptStep
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    // Hidden while confirming and on the receipt ("Done" is the exit).
                    if step == .review && !isConfirming && !isAuthorizing {
                        SheetCloseButton { dismiss() }
                    }
                }
            }
        }
        .sheetChrome([.large])
        .interactiveDismissDisabled(isConfirming || isAuthorizing)
        .sensoryFeedback(.error, trigger: failureTick)
        .sensoryFeedback(.impact(weight: .medium), trigger: sendTick)
        .task { await wallet.load() }
        #if DEBUG
        // Test money exists in Debug builds only (SPEC §8.2 item 9).
        .sheet(isPresented: $showsAddTestMoney, onDismiss: {
            Task { await wallet.refresh() }
        }) {
            // "View activity" in Add test money on top of this sheet closes
            // this one (and so both) before Activity is selected, so Pay in
            // never covers Activity (J0.7, A9.3).
            services.navigator.sheetView(for: .addTestMoney)
                .environment(\.viewActivityOverride, ViewActivityAction { viewActivity() })
        }
        #endif
    }

    // MARK: Review (B4.25)

    private var rows: [DetailRow] {
        var rows = [
            DetailRow("From", .text("Balance")),
            DetailRow("To", .text(group.name)),
            DetailRow("Round", .text(roundText)),
        ]
        if !group.feeRate.isZero {
            rows.append(DetailRow("Fee", .text("Included (\(group.feeRate.percentText))")))
        }
        return rows
    }

    /// The reserved reason slot (A8.15): loading, or the refusal in `redText`.
    /// A failed balance read shows its banner instead, which is the reason.
    private var reason: String? {
        switch wallet.phase {
        case .loading:
            return "Loading your balance\u{2026}"
        case .failed:
            return nil
        case .loaded:
            return hasEnough == false
                ? "You need \(contribution.formatted()) available to pay in. Add money first."
                : nil
        }
    }

    private var review: some View {
        let biometry = services.authenticator.biometryKind()
        let isShort = hasEnough == false
        return ReviewStep(
            title: "Pay in",
            subtitle: group.name,
            amount: contribution,
            rows: rows,
            footnote: "Pay-ins can't be undone.",
            confirmTitle: biometry.confirmTitle,
            confirmSystemImage: biometry.symbolName,
            isConfirming: isConfirming,
            note: note,
            reason: reason,
            reasonIsRefusal: isShort,
            reasonIdentifier: isShort ? "groups.payIn.insufficient" : nil,
            errorTitle: errorTitle,
            errorMessage: errorMessage,
            errorActionTitle: isUncertain ? "View activity" : nil,
            onErrorAction: isUncertain ? { viewActivity() } : nil,
            isConfirmDisabled: hasEnough != true || isUncertain,
            blocksGoingBack: isUncertain,
            identifierPrefix: "groups.payIn",
            onConfirm: { confirm() }
        ) {
            if case .failed(let error) = wallet.phase {
                // `groups.payIn.balanceError` (B4.25). ReviewStep's own banner
                // slot carries `groups.payIn.error`, so this banner sits in the
                // v1 slot under the confirm button to keep its identifier.
                ErrorBanner(error.message(for: .screen)) {
                    Task { await wallet.refresh() }
                }
                .accessibilityIdentifier("groups.payIn.balanceError")
                .padding(.top, dynamicTypeSize.isAccessibilitySize ? 0 : Spacing.space2)
            }
        } belowConfirm: {
            #if DEBUG
            if isShort && !isUncertain {
                MoolaButton("Add test money", kind: .secondary) {
                    showsAddTestMoney = true
                }
                .accessibilityIdentifier("groups.payIn.addTestMoney")
            }
            #endif
        }
    }

    private func viewActivity() {
        dismiss()
        services.navigator.select(.activity)
    }

    // MARK: Receipt (B4.26)

    private var receiptRows: [DetailRow] {
        rows + [DetailRow("Date", .text(MoolaDates.dateAndTime(receipt.matchedAt ?? sentAt)))]
    }

    private var receiptStep: some View {
        ReceiptStep(
            status: receipt.status,
            title: "Paid in to \(group.name)",
            amount: contribution,
            rows: receiptRows,
            onDone: { dismiss() }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("groups.payIn.receipt")
    }

    // MARK: Confirm (J0.3)

    private func confirm() {
        guard !isConfirming, !isAuthorizing, hasEnough == true, !isUncertain else { return }
        isAuthorizing = true
        note = nil
        errorTitle = nil
        errorMessage = nil
        Task {
            let result = await services.authenticator.authenticate(reason: DeviceAuthenticator.Reason.confirmMoneyMove)
            switch result {
            case .success, .unavailable:
                // `.unavailable`: no passcode on this device, so there is no
                // device gate; the server's session stays the authority.
                break
            case .cancelled, .failed:
                note = "Cancelled. Nothing was taken."
                isAuthorizing = false
                return
            }
            await send()
            isAuthorizing = false
        }
    }

    /// One request, never retried (J0.8).
    private func send() async {
        isConfirming = true
        let sent = Date()
        sentAt = sent
        sendTick += 1
        do throws(APIError) {
            _ = try await services.api.send(API.Groups.contribute(groupID: group.id))
            isConfirming = false
            receipt = ActivityReceiptMatcher.Resolution()
            step = .receipt
            receipt = await ActivityReceiptMatcher.resolve(
                api: services.api,
                type: "contribution",
                amountCents: -contribution.cents,
                sentAt: sent
            )
        } catch {
            isConfirming = false
            switch error {
            case .cancelled, .sessionExpired:
                return
            case .noResponse, .invalidResponse:
                // The request left the device and we can't tell whether it
                // landed (J0.7): never retry; point to Activity; tell Home.
                isUncertain = true
                errorMessage = APIError.Copy.uncertainMoneyMove
                AppSignals.postMoneyMoved()
            case .rejected, .rateLimited:
                // A clear refusal carries the server's own words under the
                // title; without them it is a plain message (J0.7).
                if let message = error.serverMessage, !message.isEmpty, message != "Invalid request" {
                    errorTitle = APIError.Copy.moneyMoveRefusedTitle
                    errorMessage = message
                } else {
                    errorMessage = error.message(for: .moneyMove)
                }
            default:
                errorMessage = error.message(for: .moneyMove)
            }
            failureTick += 1
        }
    }
}
