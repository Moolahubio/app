import APIClient
import Auth
import DesignSystem
import Domain
import Observation
import SwiftUI

/// Create a goal (DESIGN.md v2 B3.8, B3.9).
@MainActor
@Observable
final class CreateGoalModel {
    enum Step: Hashable {
        case target
    }

    static let maxNameLength = 40
    static let counterFrom = 30
    static let minimumTarget = Money(cents: 100)
    static let maximumTarget = Money(cents: 999_999_999)

    @ObservationIgnored let api: APIClient
    var path: [Step] = []
    var name = ""
    var icon: GoalIcon = .goal
    var deadline: Date
    var frequency: GoalFrequency = .weekly
    private(set) var target: Money?
    var targetBuffer = AmountEntryBuffer()
    private(set) var isCreating = false
    private(set) var errorMessage: String?
    /// Haptic trigger (A6, ruling 24): a submitted create failed.
    private(set) var failureCount = 0

    let deadlineRange: ClosedRange<Date>

    init(api: APIClient, now: Date = Date(), calendar: Calendar = .current) {
        self.api = api
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let tenYears = calendar.date(byAdding: .year, value: 10, to: today) ?? tomorrow
        deadlineRange = tomorrow...max(tomorrow, tenYears)
        let sixMonths = calendar.date(byAdding: .month, value: 6, to: today) ?? tomorrow
        deadline = min(max(sixMonths, tomorrow), deadlineRange.upperBound)
    }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "32/40" from 30 characters (B3.8, W10.5).
    var nameCounter: String? {
        name.count >= Self.counterFrom ? "\(name.count)/\(Self.maxNameLength)" : nil
    }

    var canCreate: Bool {
        !trimmedName.isEmpty && trimmedName.count <= Self.maxNameLength && target != nil && !isCreating
    }

    /// True once the user has typed or picked anything (closing then asks first).
    var hasEdits: Bool {
        !name.isEmpty || target != nil
    }

    var plan: ContributionPlan.GoalPlan? {
        guard let target else { return nil }
        return ContributionPlan.buildGoalPlan(targetCents: target.cents, start: Date(), deadline: deadline, frequency: frequency)
    }

    // Target amount step (AmountEntry, min $1.00, max $9,999,999.99).

    /// B3.9 has no above-the-maximum copy for a target, and none is needed: the keypad stops at 7 whole digits, so $9,999,999.99 (the
    /// maximum) can't be exceeded. `canSetTarget` still checks it.
    var targetValidationMessage: String? {
        AmountValidation.message(
            for: targetBuffer.money, minimum: Self.minimumTarget, maximum: Self.maximumTarget,
            aboveMaximum: nil
        )
    }

    var canSetTarget: Bool {
        AmountValidation.isValid(targetBuffer.money, minimum: Self.minimumTarget, maximum: Self.maximumTarget)
    }

    var targetPresets: [AmountPreset] {
        [50_000, 100_000, 500_000, 1_000_000].map { AmountPreset.amount(Money(cents: Int64($0))) }
    }

    func editTarget() {
        targetBuffer = target.map { AmountEntryBuffer(money: $0) } ?? AmountEntryBuffer()
        path.append(.target)
    }

    func setTarget() {
        guard canSetTarget, let money = targetBuffer.money else { return }
        target = money
        path.removeAll()
    }

    func setName(_ value: String) {
        name = value.count > Self.maxNameLength ? String(value.prefix(Self.maxNameLength)) : value
    }

    /// `POST /goals` with the picked emoji exactly as A7.6 lists it and
    /// `color: "jade"` (A1.5).
    func create() async -> Goal? {
        guard canCreate, let target else { return nil }
        errorMessage = nil
        isCreating = true
        defer { isCreating = false }
        let input = GoalInput(
            name: trimmedName,
            icon: icon,
            target: target,
            deadline: APIDate.dayString(from: deadline),
            frequency: frequency
        )
        do throws(APIError) {
            return try await api.send(API.Goals.create(input))
        } catch {
            if error != .cancelled && error != .sessionExpired {
                errorMessage = error.message(for: .action)
                failureCount &+= 1
            }
            return nil
        }
    }
}

/// The Create goal sheet content (B3.8): a task sheet whose first step is
/// the form and whose pushed step is the target amount (B3.9).
struct CreateGoalFlow: View {
    let services: AppServices
    let close: () -> Void
    let created: (Goal) -> Void

    @State private var model: CreateGoalModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices, close: @escaping () -> Void, created: @escaping (Goal) -> Void) {
        self.services = services
        self.close = close
        self.created = created
        _model = State(initialValue: CreateGoalModel(api: services.api))
    }

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $model.path) {
            form
                .navigationDestination(for: CreateGoalModel.Step.self) { _ in
                    targetStep
                }
        }
        // Blocked where Close asks (B3.1 item 4): once something is entered,
        // on the target step (its Close always asks) and while creating.
        .savingsSheetChrome(blocksSwipeDown: model.hasEdits || model.isCreating || !model.path.isEmpty)
        .sensoryFeedback(.error, trigger: model.failureCount)
    }

    // MARK: Form (B3.8)

    private var reason: String? {
        model.canCreate || model.isCreating ? nil : "Add a goal name and a target amount to continue."
    }

    private var form: some View {
        @Bindable var model = model
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        // The bar is stacked under the scroll view rather than laid over it
        // (`PinnedActionBar` uses iOS 26 `safeAreaBar`, under which the scroll
        // view runs on): this form's controls below the fold ("How often you'll
        // save", the date picker) must scroll to above the bar, or a tap meant
        // for them lands on "Create goal" (measured with XCUITest on iOS 26.5).
        // The look is the hard bottom edge B3.8 asks for: content stops at the bar.
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    SheetStepTitle("Create a goal")
                    MoolaTextField(
                        "Goal name",
                        text: Binding(get: { model.name }, set: { model.setName($0) }),
                        placeholder: "e.g. Emergency fund",
                        hint: model.nameCounter,
                        autocapitalization: .sentences
                    )
                    .submitLabel(.done)
                    .padding(.top, Spacing.space6)
                    iconPicker
                        .padding(.top, Spacing.fieldToNextLabel)
                    PickerField(
                        label: "Target amount",
                        value: model.target.map { $0.formatted(.wholeIfRound) },
                        placeholder: "e.g. $1,000",
                        accessibilityValue: model.target.map { $0.accessibilityText() },
                        identifier: "savings.create.target"
                    ) {
                        SavingsKeyboard.dismiss()
                        model.editTarget()
                    }
                    .accessibilityHint("Opens the amount.")
                    .padding(.top, Spacing.fieldToNextLabel)
                    fieldLabel("Target date")
                        .padding(.top, Spacing.fieldToNextLabel)
                    // No container and no jade tint: the app's ink tint selects the day (A1.6, B3.8).
                    DatePicker("Target date", selection: $model.deadline, in: model.deadlineRange, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                        .padding(.top, Spacing.labelToField)
                    fieldLabel("How often you'll save")
                        .padding(.top, Spacing.fieldToNextLabel)
                    Picker("How often you'll save", selection: $model.frequency) {
                        ForEach(GoalFrequency.allCases, id: \.self) { frequency in
                            Text(frequency.label).tag(frequency)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, Spacing.labelToField)
                    if let plan = model.plan {
                        Text("Your plan")
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.top, Spacing.space6)
                        Text(SavingsCopy.planPreview(plan))
                            .textStyle(.body)
                            .monospacedDigit()
                            .foregroundStyle(Palette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("savings.create.planText")
                            .padding(.top, Spacing.space1)
                    }
                    if accessibilitySize {
                        // At accessibility sizes the bar keeps only its button (A8.30):
                        // the banner and the reason line follow the last field.
                        VStack(alignment: .leading, spacing: Spacing.space3) {
                            if let errorMessage = model.errorMessage {
                                ErrorBanner(errorMessage)
                            }
                            if let reason {
                                Text(reason)
                                    .textStyle(.footnote)
                                    .foregroundStyle(Palette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.top, Spacing.space6)
                    }
                }
                .padding(.horizontal, Spacing.sheetPadding)
                .padding(.bottom, Spacing.space6)
            }
            .scrollDismissesKeyboard(.interactively)
            VStack(spacing: 0) {
                if !accessibilitySize, let errorMessage = model.errorMessage {
                    ErrorBanner(errorMessage)
                        .transition(.opacity)
                        .padding(.bottom, Spacing.space3)
                }
                MoolaButton("Create goal", loadingTitle: "Creating\u{2026}", isLoading: model.isCreating) {
                    Task {
                        if let goal = await model.create() {
                            created(goal)
                        }
                    }
                }
                .disabled(!model.canCreate)
                .accessibilityHint(reason ?? "")
                .accessibilityIdentifier("savings.create.submit")
                if !accessibilitySize {
                    // Reserved: the slot keeps its line while the button is enabled (A9.9).
                    DisabledReasonLine(text: "Add a goal name and a target amount to continue.", isShown: reason != nil)
                        .padding(.top, Spacing.space2)
                }
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: model.errorMessage)
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.top, Spacing.space3)
            .padding(.bottom, PinnedBarMetrics.bottomPadding(
                bottomSafeArea: PinnedBarMetrics.windowBottomSafeArea, endsWithFooterRow: false
            ))
        }
        .savingsCloseButton(asksFirst: model.hasEdits, isHidden: model.isCreating, isRootStep: true, close: close)
    }

    /// A label over a system control that already speaks the same words
    /// ("Target date", "How often you'll save"): `body` `textPrimary`, hidden
    /// from VoiceOver so it is not read twice.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .textStyle(.body)
            .foregroundStyle(Palette.textPrimary)
            .accessibilityHidden(true)
    }

    /// "Icon" (A7.6): the 12 curated emoji as 56 pt jade tiles in a 4-column
    /// grid (3 at accessibility sizes), 12 pt gaps; selection is a 2 pt ink
    /// ring plus `.isSelected`, with `.selection` haptics.
    private var iconPicker: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Spacing.gridGap),
            count: dynamicTypeSize.isAccessibilitySize ? 3 : 4
        )
        return VStack(alignment: .leading, spacing: 0) {
            Text("Icon")
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: columns, spacing: Spacing.gridGap) {
                ForEach(GoalIcon.allCases, id: \.self) { icon in
                    EmojiPickerCell(
                        emoji: icon.emoji,
                        label: icon.label,
                        identifier: "savings.create.icon.\(icon.rawValue)",
                        isSelected: model.icon == icon
                    ) {
                        model.icon = icon
                    }
                }
            }
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: model.icon)
            .sensoryFeedback(.selection, trigger: model.icon)
            .padding(.top, Spacing.labelToField)
        }
    }

    // MARK: Target step (B3.9)

    private var targetStep: some View {
        AmountStepView(
            title: "Target amount",
            subtitle: nil,
            buffer: Binding(get: { model.targetBuffer }, set: { model.targetBuffer = $0 }),
            context: nil,
            presets: model.targetPresets,
            maximum: CreateGoalModel.maximumTarget,
            validationMessage: model.targetValidationMessage,
            isEnabled: true,
            buttonTitle: "Done",
            canContinue: model.canSetTarget,
            onContinue: { model.setTarget() }
        )
        .savingsCloseButton(asksFirst: true, isRootStep: false, close: close)
    }
}
