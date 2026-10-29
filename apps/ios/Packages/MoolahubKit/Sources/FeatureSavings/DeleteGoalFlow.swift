import APIClient
import Auth
import DesignSystem
import Domain
import Observation
import SwiftUI

/// Delete goal (DESIGN.md v2 J4): confirm with the step-up fields inline,
/// then a receipt only when money moved back to the balance (B3.27);
/// otherwise the sheet closes and the Savings list shows "Goal deleted." (B3.28).
@MainActor
@Observable
final class DeleteGoalModel {
    enum Step: Hashable {
        case receipt
    }

    struct Receipt {
        let result: DeleteGoalResult
        let sentAt: Date
        let tracker: ReceiptStatusTracker
    }

    @ObservationIgnored let api: APIClient
    let goal: Goal
    var path: [Step] = []
    let stepUp = StepUpState()
    private(set) var isDeleting = false
    private(set) var failure: MoveFailure?
    private(set) var receipt: Receipt?
    /// Haptic triggers (A6): the delete was submitted; it was refused or failed.
    private(set) var submitCount = 0
    private(set) var failureCount = 0

    init(api: APIClient, goal: Goal) {
        self.api = api
        self.goal = goal
    }

    /// One `POST /goals/{id}/delete` with the step-up proof (the server wants
    /// it even for an empty goal). Never retried. Returns true when the goal
    /// was deleted and nothing moved (the caller closes and shows the toast).
    func submit() async -> Bool {
        guard !isDeleting, failure?.isUncertain != true, stepUp.canSubmit else { return false }
        failure = nil
        stepUp.fieldError = nil
        isDeleting = true
        submitCount &+= 1
        let proof = stepUp.proof
        stepUp.clear()
        let sentAt = Date()
        let result: DeleteGoalResult
        do throws(APIError) {
            result = try await api.send(API.Goals.delete(goalID: goal.id, proof: proof))
        } catch {
            isDeleting = false
            if case .rejected(401, let message) = error {
                stepUp.fieldError = message ?? APIError.Copy.generic
                failureCount &+= 1
            } else {
                failure = MoveFailure(error)
                if failure != nil { failureCount &+= 1 }
                if failure?.isUncertain == true { SavingsEvents.shared.goalsChanged() }
            }
            return false
        }
        isDeleting = false
        guard result.withdrawnGrossCents > 0 else { return true }
        receipt = Receipt(
            result: result,
            sentAt: sentAt,
            tracker: ReceiptStatusTracker(
                api: api,
                expected: ExpectedActivity(type: "goal_release", amountCents: result.withdrawnNetCents),
                sentAt: sentAt
            )
        )
        path.append(.receipt)
        return false
    }
}

/// The Delete goal sheet content (J4).
struct DeleteGoalFlow: View {
    let services: AppServices
    let finish: (SavingsSheetExit) -> Void

    @State private var model: DeleteGoalModel

    init(services: AppServices, goal: Goal, finish: @escaping (SavingsSheetExit) -> Void) {
        self.services = services
        self.finish = finish
        _model = State(initialValue: DeleteGoalModel(api: services.api, goal: goal))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            confirmStep
                .navigationDestination(for: DeleteGoalModel.Step.self) { _ in
                    receiptStep
                }
        }
        // Swipe-down is blocked while deleting and on the receipt, whose
        // "Done" also pops to Savings (B3.1 item 4).
        .savingsSheetChrome(blocksSwipeDown: model.isDeleting || !model.path.isEmpty)
        .sensoryFeedback(.impact(weight: .heavy), trigger: model.submitCount)
        .sensoryFeedback(.error, trigger: model.failureCount)
        .task { await model.stepUp.loadStatus(api: services.api) }
    }

    // MARK: Confirm (B3.26)

    /// Title "Delete goal", the goal's name, 16 pt, the consequence
    /// (`callout` `textPrimary`, `savings.delete.body`), 16 pt, the step-up
    /// instruction and fields (no second title). Pinned: the failure banner
    /// and the tonal destructive "Delete goal" (loading "Deleting…").
    private var confirmStep: some View {
        @Bindable var stepUp = model.stepUp
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetStepTitle("Delete goal", subtitle: model.goal.name)
                Text(SavingsCopy.deleteBody(saved: model.goal.saved, fee: model.goal.feeRate))
                    .textStyle(.callout)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("savings.delete.body")
                    .padding(.top, Spacing.space4)
                StepUpFields(
                    password: $stepUp.password,
                    code: $stepUp.code,
                    needsCode: stepUp.needsCode,
                    error: stepUp.fieldError,
                    showsTitle: false
                )
                .padding(.top, Spacing.space4)
                if let statusError = stepUp.statusError {
                    ErrorBanner(statusError.message(for: .screen)) {
                        Task { await model.stepUp.loadStatus(api: services.api) }
                    }
                    .padding(.top, Spacing.space4)
                }
                StepUpScrollFooter(failure: model.failure) { finish(.viewActivity) }
            }
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            StepUpBar(failure: model.failure, onViewActivity: { finish(.viewActivity) }) {
                MoolaButton("Delete goal", kind: .destructive, loadingTitle: "Deleting\u{2026}", isLoading: model.isDeleting) {
                    Task {
                        if await model.submit() {
                            finish(.goalDeleted(showToast: true))
                        }
                    }
                }
                .disabled(!stepUp.canSubmit || model.failure?.isUncertain == true)
                .accessibilityIdentifier("savings.delete.submit")
            }
        })
        .savingsCloseButton(asksFirst: false, isHidden: model.isDeleting, isRootStep: true) { finish(.close) }
    }

    // MARK: Receipt (B3.27)

    @ViewBuilder
    private var receiptStep: some View {
        if let receipt = model.receipt {
            TrackedReceiptView(
                title: "Goal deleted",
                amount: Money(cents: receipt.result.withdrawnGrossCents),
                rows: [
                    DetailRow("Amount", .money(Money(cents: receipt.result.withdrawnGrossCents))),
                    DetailRow("Fee", .fee(Money(cents: receipt.result.feeCents))),
                    DetailRow("You received", .money(Money(cents: receipt.result.withdrawnNetCents))),
                ],
                sentAt: receipt.sentAt,
                tracker: receipt.tracker,
                secondaryTitle: nil,
                onDone: { finish(.goalDeleted(showToast: false)) },
                onSecondary: nil
            )
        }
    }
}
