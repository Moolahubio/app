import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

#if DEBUG
/// "Add test money" (DESIGN.md v2 B2.3, B2.4, J1), presented by AppFeature for
/// `AppSheet.addTestMoney` (from Home's "Add money" tile and from the Groups
/// Pay-in flow). Keep the name and initializer.
///
/// Amount → `POST /wallet/deposit` → receipt. No review and no Face ID:
/// nothing leaves the user's money. The request is sent once and never
/// retried; the receipt decides Done vs Processing only by matching Activity.
/// Debug builds only: Release has no test money (SPEC §8.2 item 9, D-37).
public struct AddTestMoneySheet: View {
    static let minimum = Money(cents: 1)
    static let maximum = Money(cents: 100_000)
    static let presets: [AmountPreset] = [5_000, 10_000, 25_000, 50_000].map { AmountPreset.amount(Money(cents: $0)) }

    private let services: AppServices
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.viewActivityOverride) private var viewActivityOverride

    @State private var buffer = AmountEntryBuffer()
    @State private var isSubmitting = false
    @State private var failure: Failure?
    @State private var failureCount = 0
    @State private var sendCount = 0
    @State private var receipt: MoneyMoveReceipt?
    /// VoiceOver lands on the step title when the sheet opens.
    @AccessibilityFocusState private var titleFocused: Bool

    /// Why the last attempt didn't complete (J0.7, W6).
    enum Failure: Equatable {
        /// The server said no: the title "Didn't go through. Nothing was taken." over its message.
        case refused(String)
        /// Sent, but the outcome is unknown: "View activity", and no second attempt.
        case uncertain(String)
        /// Nothing was sent, or the server failed (offline, 5xx, …): the message alone.
        case other(String)
    }

    private static let failureID = "home.addMoney.failure"
    private static let contentEndID = "home.addMoney.contentEnd"

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let receipt {
                    receiptStep(receipt)
                } else {
                    amountStep
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if receipt == nil {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCloseButton(identifier: "home.addMoney.close") { dismiss() }
                            .disabled(isSubmitting)
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .sensoryFeedback(.impact(weight: .medium), trigger: sendCount)
        .sensoryFeedback(.error, trigger: failureCount)
        .sheetChrome([.large])
    }

    // MARK: Step 1: amount (B2.3)

    private var amount: Money? { buffer.money }

    private var validationMessage: String? {
        guard let amount, amount.cents > 0 else { return nil }
        if amount < Self.minimum {
            return "Enter at least \(Self.minimum.formatted())."
        }
        if amount > Self.maximum {
            return "You can add up to $1,000.00 of test money at a time."
        }
        return nil
    }

    private var canSubmit: Bool {
        guard let amount, amount >= Self.minimum, amount <= Self.maximum else { return false }
        // After an unknown outcome the move may have gone through: check
        // Activity first, never a second attempt from here (J0.7).
        if case .uncertain = failure { return false }
        return true
    }

    private var amountStep: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Add test money")
                        .textStyle(.title1)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                        .padding(.top, Spacing.space2)
                    NoticeBanner(
                        "This is a test version of MoolaHub. Test money isn't real and can't be cashed out.",
                        title: "Test money",
                        systemImage: "testtube.2",
                        tone: .amber
                    )
                    .padding(.top, Spacing.space6)
                    AmountEntry(
                        buffer: $buffer,
                        context: "Up to \(Self.maximum.formatted()) at a time",
                        presets: Self.presets,
                        maximum: Self.maximum,
                        validationMessage: validationMessage,
                        isEnabled: !isSubmitting
                    )
                    .padding(.top, Spacing.space6)
                    .onChange(of: buffer) { _, _ in
                        // A new amount is a new attempt, so a refusal no longer
                        // applies. An unknown outcome stays: check Activity first.
                        switch failure {
                        case .refused, .other: failure = nil
                        case .uncertain, nil: break
                        }
                    }
                    if accessibilitySize, failure != nil {
                        // At accessibility sizes the bar holds only the button;
                        // the banner sits in the content (J0.10).
                        failureBanner
                            .id(Self.failureID)
                            .padding(.top, Spacing.space6)
                    }
                    Color.clear
                        .frame(height: 0)
                        .id(Self.contentEndID)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.sheetPadding)
                .padding(.bottom, Spacing.space6)
            }
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: failureCount) { _, _ in
                guard failure != nil else { return }
                withAnimation(Motion.animation(Motion.standard, reduceMotion: reduceMotion)) {
                    if accessibilitySize {
                        proxy.scrollTo(Self.failureID, anchor: .center)
                    } else {
                        // The banner makes the pinned bar taller than the room
                        // under the keypad: scroll so the keypad's last row
                        // clears the bar instead of sitting under its edge.
                        proxy.scrollTo(Self.contentEndID, anchor: .bottom)
                    }
                }
            }
        }
        // On a home-button iPhone the keypad's last rows rest under the bar
        // (ruling 5): a hard edge, so they don't show through around the button.
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet, hardEdge: PinnedBarMetrics.amountStepHardEdge) {
            VStack(spacing: 0) {
                if !accessibilitySize, failure != nil {
                    failureBanner
                        .padding(.bottom, Spacing.space3)
                        .transition(.opacity)
                }
                MoolaButton("Add test money", loadingTitle: "Adding\u{2026}", isLoading: isSubmitting) {
                    submit()
                }
                .disabled(!canSubmit)
                .accessibilityIdentifier("home.addMoney.submit")
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: failure)
        })
        .task { await focusTitle() }
    }

    @ViewBuilder
    private var failureBanner: some View {
        switch failure {
        case .refused(let message):
            ErrorBanner(message, title: APIError.Copy.moneyMoveRefusedTitle)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .uncertain(let message):
            ErrorBanner(message, retryTitle: "View activity") {
                if let viewActivityOverride {
                    // Opened on top of another sheet (Pay in, A9.3): that
                    // sheet closes, and this one with it (J0.7).
                    viewActivityOverride()
                } else {
                    dismiss()
                    services.navigator.select(.activity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .other(let message):
            ErrorBanner(message)
                .frame(maxWidth: .infinity, alignment: .leading)
        case nil:
            EmptyView()
        }
    }

    /// Moves VoiceOver to the title once the sheet has finished presenting.
    private func focusTitle() async {
        try? await Task.sleep(for: .milliseconds(400))
        titleFocused = true
    }

    /// One attempt; never retried (no idempotency key on the server yet).
    private func submit() {
        guard canSubmit, !isSubmitting, let amount else { return }
        isSubmitting = true
        failure = nil
        let sentAt = Date()
        let api = services.api
        sendCount += 1
        Task {
            do throws(APIError) {
                _ = try await api.send(API.Wallet.addTestMoney(amount))
                isSubmitting = false
                receipt = MoneyMoveReceipt(
                    amount: amount, sentAt: sentAt, expectedType: "deposit", expectedAmountCents: amount.cents
                )
                AppSignals.postMoneyMoved()
            } catch {
                isSubmitting = false
                show(error)
            }
        }
    }

    /// Maps a failed attempt to its banner (J0.7).
    private func show(_ error: APIError) {
        switch error {
        case .sessionExpired, .cancelled:
            // Signed out (the root swaps to Sign in) or nothing to report.
            return
        case .noResponse, .invalidResponse:
            // The request left and no readable answer came back: it may have
            // gone through. Send the person to Activity; let Home catch up.
            failure = .uncertain(APIError.Copy.uncertainMoneyMove)
            AppSignals.postMoneyMoved()
        case .rejected(_, let message?) where !message.isEmpty && message != "Invalid request":
            failure = .refused(message)
        case .rateLimited(let message?) where !message.isEmpty:
            failure = .refused(message)
        default:
            // Offline before sending, 5xx, 429 or 400 without a message.
            failure = .other(error.message(for: .moneyMove))
        }
        failureCount += 1
    }

    // MARK: Step 2: receipt (B2.4)

    private func receiptStep(_ receipt: MoneyMoveReceipt) -> some View {
        ReceiptStep(
            status: receipt.status,
            title: "Test money added",
            amount: receipt.amount,
            rows: [
                DetailRow("To", .text("Balance")),
                DetailRow("Date", .text(MoolaDates.dateAndTime(receipt.date))),
            ],
            onDone: {
                AppSignals.postMoneyMoved()
                dismiss()
            }
        )
        .navigationBarBackButtonHidden(true)
        .task { await receipt.resolve(using: services.api) }
    }
}
#endif

/// "Cash out" (DESIGN.md v2 B2.5, J6): not available in this build. The info
/// sheet pattern: the title 24 pt below the sheet's top edge, one sentence 16
/// pt below it, a pinned "Done". Presented by AppFeature for `AppSheet.cashOut`.
public struct CashOutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleFocused: Bool

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Cash out")
                    .textStyle(.title2)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text("Cashing out isn't available yet. We'll let you know when it is.")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.headingToContent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.top, Spacing.space6)
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            MoolaButton("Done") { dismiss() }
        })
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            titleFocused = true
        }
        .sheetChrome([.medium])
    }
}
