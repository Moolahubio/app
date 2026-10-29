import APIClient
import Auth
import DesignSystem
import Domain
import Observation
import SwiftUI

/// Move to balance (DESIGN.md v2 J3): amount → review with the fee preview →
/// "Confirm it's you" → receipt with the server's gross, fee and net.
@MainActor
@Observable
final class MoveToBalanceModel {
    enum Step: Hashable {
        case review
        case stepUp
        case receipt
    }

    struct Receipt {
        let result: ReleaseFromGoalResult
        let sentAt: Date
        let tracker: ReceiptStatusTracker
    }

    @ObservationIgnored let api: APIClient
    let goal: Goal
    var path: [Step] = []
    var buffer = AmountEntryBuffer()
    let stepUp = StepUpState()
    private(set) var isSending = false
    private(set) var failure: MoveFailure?
    private(set) var receipt: Receipt?
    /// Haptic triggers (A6): the step-up was submitted; it was refused or failed.
    private(set) var sendCount = 0
    private(set) var failureCount = 0

    init(api: APIClient, goal: Goal) {
        self.api = api
        self.goal = goal
    }

    var amount: Money? { buffer.money }
    var maximum: Money { goal.saved }

    var validationMessage: String? {
        AmountValidation.message(for: amount, minimum: Money(cents: 1), maximum: maximum, aboveMaximum: SavingsCopy.moreThanGoalHas)
    }

    var canReview: Bool {
        AmountValidation.isValid(amount, minimum: Money(cents: 1), maximum: maximum)
    }

    /// $10 · $25 · $50 · "All" (B3.22).
    var presets: [AmountPreset] {
        [1_000, 2_500, 5_000].map { AmountPreset.amount(Money(cents: Int64($0))) }
            + [AmountPreset(label: "All", money: maximum)]
    }

    /// Close asks first on every step after the amount, except the receipt.
    var isPastFirstStep: Bool {
        !path.isEmpty && path.last != .receipt
    }

    /// Preview with the goal's `feeBps` and the server's rounding
    /// (`floor(amount × feeBps / 10000)`, J0.8).
    var previewFee: Money { goal.feeRate.fee(on: amount ?? .zero) }
    var previewNet: Money { goal.feeRate.net(of: amount ?? .zero) }

    func review() {
        guard canReview else { return }
        failure = nil
        path.append(.review)
    }

    func continueToStepUp() {
        guard canReview else { return }
        failure = nil
        stepUp.fieldError = nil
        path.append(.stepUp)
    }

    func editAmount() {
        guard path.last == .review else { return }
        path.removeLast()
    }

    /// One `POST /goals/{id}/release` with the step-up proof. Never retried.
    /// A 401 is a wrong password or code: inline, never a sign-out (J0.4).
    func submit() async {
        guard !isSending, failure?.isUncertain != true, stepUp.canSubmit, let amount, amount.isPositive else { return }
        failure = nil
        stepUp.fieldError = nil
        isSending = true
        sendCount &+= 1
        let proof = stepUp.proof
        stepUp.clear()
        let sentAt = Date()
        let result: ReleaseFromGoalResult
        do throws(APIError) {
            result = try await api.send(API.Goals.release(goalID: goal.id, amount: amount, proof: proof))
        } catch {
            isSending = false
            if case .rejected(401, let message) = error {
                stepUp.fieldError = message ?? APIError.Copy.generic
                failureCount &+= 1
            } else {
                failure = MoveFailure(error)
                if failure != nil { failureCount &+= 1 }
                if failure?.isUncertain == true { SavingsEvents.shared.goalsChanged() }
            }
            return
        }
        isSending = false
        receipt = Receipt(
            result: result,
            sentAt: sentAt,
            tracker: ReceiptStatusTracker(
                api: api,
                expected: ExpectedActivity(type: "goal_release", amountCents: result.netCents),
                sentAt: sentAt
            )
        )
        SavingsEvents.shared.goalsChanged()
        path.append(.receipt)
    }
}

/// The Move to balance sheet content (J3).
struct MoveToBalanceFlow: View {
    let services: AppServices
    let finish: (SavingsSheetExit) -> Void

    @State private var model: MoveToBalanceModel

    init(services: AppServices, goal: Goal, finish: @escaping (SavingsSheetExit) -> Void) {
        self.services = services
        self.finish = finish
        _model = State(initialValue: MoveToBalanceModel(api: services.api, goal: goal))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            amountStep
                .navigationDestination(for: MoveToBalanceModel.Step.self) { step in
                    switch step {
                    case .review: reviewStep
                    case .stepUp: stepUpStep
                    case .receipt: receiptStep
                    }
                }
        }
        .savingsSheetChrome(blocksSwipeDown: model.isPastFirstStep || model.isSending)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.sendCount)
        .sensoryFeedback(.error, trigger: model.failureCount)
    }

    // MARK: Amount (B3.22)

    private var amountStep: some View {
        AmountStepView(
            title: "Move to balance",
            subtitle: model.goal.name,
            buffer: Binding(get: { model.buffer }, set: { model.buffer = $0 }),
            context: "In this goal \(model.goal.saved.formatted())",
            presets: model.presets,
            maximum: model.maximum,
            validationMessage: model.validationMessage,
            isEnabled: true,
            buttonTitle: "Review",
            canContinue: model.canReview,
            onContinue: { model.review() }
        )
        .savingsCloseButton(asksFirst: false, isRootStep: true) { finish(.close) }
    }

    // MARK: Review (B3.23)

    @ViewBuilder
    private var reviewStep: some View {
        if let amount = model.amount {
            let fee = model.goal.feeRate
            MoveReviewView(
                amount: amount,
                rows: [
                    DetailRow("From", .goal(name: model.goal.name, emoji: model.goal.emoji, colorKey: model.goal.color)),
                    DetailRow("To", .text("Balance")),
                    DetailRow("Fee", .fee(model.previewFee)),
                    DetailRow("You receive", .money(model.previewNet)),
                ],
                footnote: fee.isZero ? nil : "A \(fee.percentText) fee applies when you move money out of a goal.",
                confirmTitle: "Continue",
                confirmSystemImage: nil,
                isConfirming: false,
                note: nil,
                failure: nil,
                onConfirm: { model.continueToStepUp() },
                onEditAmount: { model.editAmount() },
                onViewActivity: { finish(.viewActivity) }
            )
            .savingsCloseButton(asksFirst: true, isRootStep: false) { finish(.close) }
        }
    }

    // MARK: Confirm it's you (B3.24)

    private var stepUpStep: some View {
        StepUpStepView(
            stepUp: model.stepUp,
            actionTitle: "Move to balance",
            isWorking: model.isSending,
            failure: model.failure,
            onSubmit: { Task { await model.submit() } },
            onRetryStatus: { Task { await model.stepUp.loadStatus(api: services.api) } },
            onViewActivity: { finish(.viewActivity) }
        )
        .savingsCloseButton(
            asksFirst: true,
            isHidden: model.isSending || model.failure?.isUncertain == true,
            isRootStep: false
        ) { finish(.close) }
        .task {
            if model.stepUp.needsCode == nil {
                await model.stepUp.loadStatus(api: services.api)
            }
        }
    }

    // MARK: Receipt (B3.25): the server's figures

    @ViewBuilder
    private var receiptStep: some View {
        if let receipt = model.receipt {
            TrackedReceiptView(
                title: "Moved to your balance",
                amount: Money(cents: receipt.result.grossCents),
                rows: [
                    DetailRow("Amount", .money(Money(cents: receipt.result.grossCents))),
                    DetailRow("Fee", .fee(Money(cents: receipt.result.feeCents))),
                    DetailRow("You received", .money(Money(cents: receipt.result.netCents))),
                ],
                sentAt: receipt.sentAt,
                tracker: receipt.tracker,
                secondaryTitle: nil,
                onDone: { finish(.close) },
                onSecondary: nil
            )
        }
    }
}
