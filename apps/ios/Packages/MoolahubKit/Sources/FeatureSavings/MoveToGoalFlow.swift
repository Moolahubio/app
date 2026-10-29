import APIClient
import Auth
import DesignSystem
import Domain
import Observation
import SwiftUI

/// Move to goal (DESIGN.md v2 J2): choose a goal (Home only) → amount →
/// review (Face ID) → receipt.
@MainActor
@Observable
final class MoveToGoalModel {
    enum Start {
        /// From Home: starts at "Choose a goal".
        case choose
        /// A goal the caller already has (Goal detail).
        case goal(Goal)
        /// Only an id: the goal is fetched.
        case goalID(String)
    }

    enum Origin {
        /// Goal detail's "Move to goal": no "View goal" on the receipt.
        case goalDetail
        /// Home (or anywhere else): the receipt offers "View goal".
        case elsewhere
    }

    enum Step: Hashable {
        case amount
        case review
        case receipt
    }

    struct Receipt {
        let goalID: String
        let goalName: String
        let goalEmoji: String
        let goalColor: String
        let amount: Money
        let sentAt: Date
        let tracker: ReceiptStatusTracker
    }

    @ObservationIgnored let api: APIClient
    let origin: Origin
    let startsAtChoose: Bool
    var path: [Step] = []
    var buffer = AmountEntryBuffer()
    /// Face ID cancelled: "Cancelled. Nothing was taken." (the review's reason slot).
    var note: String?
    private(set) var chosenGoal: Goal?
    /// Set synchronously on the first tap of the confirm, before Face ID: a
    /// second tap while the prompt is up must neither start a second prompt
    /// (iOS cancels it at once, which used to show "Cancelled. Nothing was
    /// taken." while the first prompt went on to send) nor a second move.
    private(set) var isAuthorizing = false
    private(set) var isSending = false
    private(set) var failure: MoveFailure?
    private(set) var receipt: Receipt?
    /// Haptic triggers (A6): a request left; a move failed.
    private(set) var sendCount = 0
    private(set) var failureCount = 0

    /// For `.choose`: `GET /goals`, fresh (not the Savings cache).
    let goals: RemoteResource<[Goal]>?
    /// For `.goalID`.
    let goalByID: RemoteResource<Goal>?
    /// `GET /wallet`, fresh when the sheet opens (never cached: it is the maximum).
    let wallet: RemoteResource<WalletInfo>

    init(api: APIClient, start: Start, origin: Origin) {
        self.api = api
        self.origin = origin
        // A balance the server couldn't read is a failed read, never $0.00 (J0.8).
        wallet = RemoteResource { try await savingsRead { try await api.walletForMoneyMove() } }
        switch start {
        case .choose:
            startsAtChoose = true
            goals = RemoteResource { try await savingsRead { try await api.send(API.Goals.list()) } }
            goalByID = nil
        case .goal(let goal):
            startsAtChoose = false
            chosenGoal = goal
            goals = nil
            goalByID = nil
        case .goalID(let id):
            startsAtChoose = false
            goals = nil
            goalByID = RemoteResource { try await savingsRead { try await api.send(API.Goals.get(id)) } }
        }
    }

    var goal: Goal? {
        chosenGoal ?? goalByID?.value
    }

    var available: Money? {
        wallet.value?.available
    }

    var amount: Money? {
        buffer.money
    }

    /// Close asks "Discard this?" on every step after the sheet's first one,
    /// except the receipt (B3.1 item 4).
    var isPastFirstStep: Bool {
        guard let last = path.last else { return false }
        return last != .receipt && (startsAtChoose || last != .amount)
    }

    var validationMessage: String? {
        AmountValidation.message(for: amount, minimum: Money(cents: 1), maximum: available, aboveMaximum: SavingsCopy.notEnoughAvailable)
    }

    var canReview: Bool {
        available != nil && goal != nil && AmountValidation.isValid(amount, minimum: Money(cents: 1), maximum: available)
    }

    /// The context line (B3.19): "Available {amount}" once the wallet is
    /// known. While it loads, a skeleton read as "Loading your balance…"
    /// holds its place (the keypad is disabled and no maximum is ever
    /// assumed, J0.8).
    var context: String? {
        available.map { "Available \($0.formatted())" }
    }

    var contextLoadingLabel: String? {
        available == nil ? SavingsCopy.loadingBalance : nil
    }

    /// "Next step {amount}" on its own row (only when it exists, is positive
    /// and is at most available), then $10 · $25 · $50 · "All". "All" and
    /// "Next step" appear only once the maximum is known (B3.19).
    var presets: [AmountPreset] {
        var list: [AmountPreset] = []
        if let goal, let available, let next = Self.nextStep(for: goal), next.isPositive, next <= available {
            list.append(AmountPreset(label: "Next step \(next.formatted())", money: next, isSuggested: true))
        }
        list += [1_000, 2_500, 5_000].map { AmountPreset.amount(Money(cents: Int64($0))) }
        if let available {
            list.append(AmountPreset(label: "All", money: available))
        }
        return list
    }

    static func nextStep(for goal: Goal) -> Money? {
        let periods = ContributionPlan.periodsBetween(goal.createdAt, goal.deadline, frequency: goal.goalFrequency)
        let plan = ContributionPlan.progressivePlan(targetCents: goal.targetCents, periods: periods)
        return ContributionPlan.nextContribution(plan: plan, savedCents: goal.savedCents).map { Money(cents: $0.amountCents) }
    }

    func choose(_ goal: Goal) {
        chosenGoal = goal
        buffer = AmountEntryBuffer()
        note = nil
        failure = nil
        path.append(.amount)
    }

    func review() {
        guard canReview else { return }
        note = nil
        failure = nil
        path.append(.review)
    }

    /// The confirm shows its in-button progress and ignores taps; Close, Back
    /// and "Edit amount" hide (J0.3 step 4).
    var isConfirming: Bool { isAuthorizing || isSending }

    func editAmount() {
        guard !isConfirming, failure?.isUncertain != true, path.last == .review else { return }
        path.removeLast()
    }

    /// Face ID (or nothing on a device without a passcode), then one
    /// `POST /goals/{id}/allocate`. Never retried (J0.8).
    func confirm(authenticator: DeviceAuthenticator) async {
        guard !isConfirming, failure?.isUncertain != true, let goal, let amount, amount.isPositive else { return }
        isAuthorizing = true
        note = nil
        failure = nil
        switch await authenticator.authenticate(reason: DeviceAuthenticator.Reason.confirmMoneyMove) {
        case .success, .unavailable:
            break
        case .cancelled, .failed:
            note = SavingsCopy.cancelledNothingTaken
            isAuthorizing = false
            return
        }
        isSending = true
        isAuthorizing = false
        sendCount &+= 1
        let sentAt = Date()
        do throws(APIError) {
            _ = try await api.send(API.Goals.allocate(goalID: goal.id, amount: amount))
        } catch {
            isSending = false
            failure = MoveFailure(error)
            if failure != nil { failureCount &+= 1 }
            if failure?.isUncertain == true { SavingsEvents.shared.goalsChanged() }
            return
        }
        isSending = false
        receipt = Receipt(
            goalID: goal.id,
            goalName: goal.name,
            goalEmoji: goal.emoji,
            goalColor: goal.color,
            amount: amount,
            sentAt: sentAt,
            tracker: ReceiptStatusTracker(
                api: api,
                expected: ExpectedActivity(type: "goal_allocate", amountCents: -amount.cents),
                sentAt: sentAt
            )
        )
        SavingsEvents.shared.goalsChanged()
        path.append(.receipt)
    }
}

/// The Move to goal sheet content (J2).
struct MoveToGoalFlow: View {
    let services: AppServices
    let finish: (SavingsSheetExit) -> Void

    @State private var model: MoveToGoalModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices, start: MoveToGoalModel.Start, origin: MoveToGoalModel.Origin, finish: @escaping (SavingsSheetExit) -> Void) {
        self.services = services
        self.finish = finish
        _model = State(initialValue: MoveToGoalModel(api: services.api, start: start, origin: origin))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            root
                .navigationDestination(for: MoveToGoalModel.Step.self) { step in
                    switch step {
                    case .amount: amountStep(isRoot: false)
                    case .review: reviewStep
                    case .receipt: receiptStep
                    }
                }
        }
        .savingsSheetChrome(blocksSwipeDown: model.isPastFirstStep || model.isConfirming)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.sendCount)
        .sensoryFeedback(.error, trigger: model.failureCount)
        .task { await model.wallet.load() }
        .task {
            if let goals = model.goals { await goals.load() }
            if let goalByID = model.goalByID { await goalByID.load() }
        }
    }

    @ViewBuilder
    private var root: some View {
        if model.startsAtChoose {
            chooseStep
        } else {
            amountStep(isRoot: true)
        }
    }

    // MARK: Choose (B3.17, B3.18)

    @ViewBuilder
    private var chooseStep: some View {
        if let goals = model.goals {
            ChooseGoalStep(
                goals: goals,
                onPick: { model.choose($0) },
                onCreateGoal: { finish(.createGoal) }
            )
            .savingsCloseButton(asksFirst: false, isRootStep: true) { finish(.close) }
        }
    }

    // MARK: Amount (B3.19)

    @ViewBuilder
    private func amountStep(isRoot: Bool) -> some View {
        Group {
            if let goalByID = model.goalByID, let failedGoal = goalByID.error, model.goal == nil {
                failedStep {
                    if failedGoal.status == 404 {
                        // B3.19: no "Back to savings" in a sheet; Close is the way out.
                        EmptyState(title: "We couldn't find that goal.", message: failedGoal.message(for: .screen))
                    } else {
                        ErrorState(message: failedGoal.message(for: .screen), isRetrying: goalByID.isLoading) {
                            Task { await goalByID.refresh() }
                        }
                    }
                }
            } else if model.wallet.value == nil, let walletError = model.wallet.error {
                // Never assumes $0.00 (J0.8); stays while "Try again" retries.
                failedStep {
                    ErrorState(
                        title: "We couldn't load your balance",
                        message: walletError.message(for: .screen),
                        isRetrying: model.wallet.isLoading
                    ) {
                        Task { await model.wallet.refresh() }
                    }
                }
            } else {
                AmountStepView(
                    title: "Move to goal",
                    subtitle: model.goal?.name,
                    subtitleIsLoading: model.goal == nil,
                    buffer: Binding(get: { model.buffer }, set: { model.buffer = $0 }),
                    context: model.context,
                    contextLoadingLabel: model.contextLoadingLabel,
                    presets: model.presets,
                    maximum: model.available,
                    validationMessage: model.validationMessage,
                    isEnabled: model.available != nil && model.goal != nil,
                    buttonTitle: "Review",
                    canContinue: model.canReview,
                    onContinue: { model.review() }
                )
                // "Next step" and "All" fade in when the wallet loads, while
                // the keypad is still disabled (B3.19).
                .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: model.available)
            }
        }
        .savingsCloseButton(asksFirst: model.isPastFirstStep, isRootStep: isRoot) { finish(.close) }
    }

    /// The step title with an error block 24 pt under it (B3.19 errors).
    private func failedStep<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetStepTitle("Move to goal", subtitle: model.goal?.name)
                content()
                    .padding(.top, Spacing.space6)
            }
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    // MARK: Review (B3.20)

    @ViewBuilder
    private var reviewStep: some View {
        if let goal = model.goal, let amount = model.amount {
            let confirm = ConfirmButtonSpec(services.authenticator.biometryKind())
            MoveReviewView(
                amount: amount,
                rows: [
                    DetailRow("From", .text("Balance")),
                    DetailRow("To", .goal(name: goal.name, emoji: goal.emoji, colorKey: goal.color)),
                    DetailRow("Fee", .fee(.zero)),
                ],
                footnote: nil,
                confirmTitle: confirm.title,
                confirmSystemImage: confirm.systemImage,
                isConfirming: model.isConfirming,
                note: model.note,
                failure: model.failure,
                onConfirm: {
                    Task { await model.confirm(authenticator: services.authenticator) }
                },
                onEditAmount: { model.editAmount() },
                onViewActivity: { finish(.viewActivity) }
            )
            .savingsCloseButton(asksFirst: true, isHidden: model.isConfirming, isRootStep: false) { finish(.close) }
        }
    }

    // MARK: Receipt (B3.21)

    @ViewBuilder
    private var receiptStep: some View {
        if let receipt = model.receipt {
            TrackedReceiptView(
                title: "Moved to \(receipt.goalName)",
                amount: receipt.amount,
                rows: [
                    DetailRow("From", .text("Balance")),
                    DetailRow("To", .goal(name: receipt.goalName, emoji: receipt.goalEmoji, colorKey: receipt.goalColor)),
                ],
                sentAt: receipt.sentAt,
                tracker: receipt.tracker,
                secondaryTitle: model.origin == .elsewhere ? "View goal" : nil,
                onDone: { finish(.close) },
                onSecondary: model.origin == .elsewhere ? { finish(.viewGoal(id: receipt.goalID)) } : nil
            )
        }
    }
}

/// "Choose a goal" (B3.17, B3.18): the step title "Move to goal" with the
/// subtitle "Choose a goal", then the goals as GoalCard rows (52 pt emoji
/// tile at the sheet's 20 pt inset, text at x 84) pressing full width, with a
/// divider between rows from the text column to the trailing inset. Empty,
/// loading and error blocks sit 24 pt under the subtitle.
struct ChooseGoalStep: View {
    let goals: RemoteResource<[Goal]>
    let onPick: (Goal) -> Void
    let onCreateGoal: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// GoalCard's row pads 16; inside a sheet the inset is 20 (A3.1).
    private static let extraInset = Spacing.sheetPadding - Spacing.screenGutter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetStepTitle("Move to goal", subtitle: "Choose a goal")
                    .padding(.horizontal, Spacing.sheetPadding)
                if let list = goals.value {
                    if list.isEmpty {
                        EmptyState(
                            title: "No goals yet",
                            message: "Create a goal first, then move money into it.",
                            actionTitle: "Create goal",
                            action: onCreateGoal
                        )
                        .padding(.horizontal, Spacing.sheetPadding)
                        .padding(.top, Spacing.space6)
                    } else {
                        rows(list)
                            .padding(.top, Spacing.space2)
                    }
                } else if let error = goals.error {
                    // Stays while "Try again" retries ("Trying again…").
                    ErrorState(title: "We couldn't load your goals", message: error.message(for: .screen), isRetrying: goals.isLoading) {
                        Task { await goals.refresh() }
                    }
                    .padding(.horizontal, Spacing.sheetPadding)
                    .padding(.top, Spacing.space6)
                } else {
                    loadingRows
                        .padding(.top, Spacing.space2)
                }
            }
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func rows(_ list: [Goal]) -> some View {
        let now = Date()
        let dividerLeading = dynamicTypeSize.isAccessibilitySize
            ? Spacing.sheetPadding
            : Spacing.sheetPadding + EmojiTileSize.s52.rawValue + Spacing.space3
        return VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, goal in
                if index > 0 {
                    Rectangle()
                        .fill(Palette.divider)
                        .frame(height: Size.hairline)
                        .padding(.leading, dividerLeading)
                        .padding(.trailing, Spacing.sheetPadding)
                        .accessibilityHidden(true)
                }
                Button {
                    onPick(goal)
                } label: {
                    GoalCard(GoalCardModel(goal, now: now), layout: .row, hint: "Chooses this goal.")
                        .padding(.horizontal, Self.extraInset)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("savings.choose.goal.\(goal.id)")
            }
        }
    }

    /// Three goal-row skeletons (B3.18) at the sheet's 20 pt inset, stacked
    /// at accessibility sizes like the rows they stand in for (ruling 26).
    private var loadingRows: some View {
        LoadingPlaceholder(label: SavingsCopy.loadingGoals) {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { _ in
                    GoalRowSkeleton(inset: Spacing.sheetPadding)
                }
            }
        }
    }
}
