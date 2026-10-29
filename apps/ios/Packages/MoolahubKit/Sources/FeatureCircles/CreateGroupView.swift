import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Create group (DESIGN.md v2 B4.10 to B4.12). Presented as the app-level
/// `AppSheet.createGroup` through `CreateGroupSheet`: a task sheet with the
/// form on the sheet ground (no boxes), the main button pinned with its
/// reserved reason line, and "Discard this?" on Close once anything changed.
struct CreateGroupForm: View {
    private let services: AppServices

    static let nameLimit = 40
    static let minimumContribution = Money(cents: 100)
    static let maximumContribution = Money(cents: 1_000_000)
    static let peopleRange = 2...20
    static let roundsRange = 2...52
    static let defaultPeople = 5
    static let defaultRounds = 10
    static let defaultFrequency = GroupFrequency.monthly
    /// Save together: up to 19 invitations (20 members including you).
    static let saveTogetherInviteLimit = 19

    @State private var name = ""
    @State private var kind: GroupKind = .takeTurns
    @State private var buffer = AmountEntryBuffer()
    @State private var people = Self.defaultPeople
    @State private var rounds = Self.defaultRounds
    @State private var frequency = Self.defaultFrequency
    @State private var emailText = ""
    @State private var emails: [String] = []
    @State private var emailError: String?
    @State private var isCreating = false
    @State private var errorMessage: String?
    @State private var confirmsDiscard = false
    @State private var failureTick = 0
    @AccessibilityFocusState private var titleFocused: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices) {
        self.services = services
    }

    // MARK: Derived state

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var contribution: Money? {
        guard let money = buffer.money, money.isPositive else { return nil }
        return money
    }

    private var amountMessage: String? {
        guard let contribution else { return nil }
        if contribution < Self.minimumContribution {
            return "Enter at least \(Self.minimumContribution.formatted())."
        }
        if contribution > Self.maximumContribution {
            return "Enter at most \(Self.maximumContribution.formatted())."
        }
        return nil
    }

    private var validContribution: Money? {
        guard let contribution, amountMessage == nil else { return nil }
        return contribution
    }

    private var inviteLimit: Int {
        kind == .takeTurns ? people - 1 : Self.saveTogetherInviteLimit
    }

    private var isOverInviteLimit: Bool { emails.count > inviteLimit }

    private var hasNameAndAmount: Bool {
        !trimmedName.isEmpty && trimmedName.count <= Self.nameLimit && validContribution != nil
    }

    private var canCreate: Bool { hasNameAndAmount && !isOverInviteLimit }

    /// B4.11: why "Create group" is disabled.
    private var disabledReason: String {
        hasNameAndAmount && isOverInviteLimit ? GroupsCopy.createReasonOverLimit : GroupsCopy.createReasonIncomplete
    }

    /// B4.12: any edit makes Close ask "Discard this?" and blocks swipe-down.
    private var hasEdits: Bool {
        !name.isEmpty || !buffer.isEmpty || kind != .takeTurns || people != Self.defaultPeople
            || rounds != Self.defaultRounds || frequency != Self.defaultFrequency
            || !emailText.isEmpty || !emails.isEmpty
    }

    /// The email line: the field's own error, else the invitation limit.
    private var emailMessage: String? {
        if let emailError { return emailError }
        return isOverInviteLimit ? GroupsCopy.inviteLimit(max(0, inviteLimit)) : nil
    }

    private var summaryText: String? {
        guard let contribution = validContribution else { return nil }
        switch kind {
        case .takeTurns:
            let pot = Money(cents: contribution.cents * Int64(people))
            return "Each round, everyone pays in \(contribution.formatted(.wholeIfRound)) plus a small fee. One person receives \(pot.formatted(.wholeIfRound)). There are \(people) rounds, so everyone gets one payout. The group starts automatically when everyone has joined."
        case .saveTogether:
            let back = Money(cents: contribution.cents * Int64(rounds))
            return "You pay in \(contribution.formatted(.wholeIfRound)) \(frequency.word). After \(rounds) rounds you get back \(back.formatted(.wholeIfRound)). You start the group once people have joined."
        }
    }

    private var motion: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    // MARK: Body

    var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    form(accessibilitySize: accessibilitySize)
                        .padding(.horizontal, Spacing.sheetPadding)
                        .padding(.bottom, Spacing.space6)
                }
                .scrollDismissesKeyboard(.interactively)
                // The form's controls must never lie under the pinned bar, where
                // a tap lands on "Create group". This 1 pt keeps the scroll
                // view's frame from reaching the bar's safe-area edge, so the
                // form ends at the bar's top instead of running under it; the
                // hard bottom edge looks the same. (XCUITest on iOS 26.5 still
                // reports a field whose top edge shows above the bar as
                // hittable; GroupsFlowUITests scrolls such fields clear first.)
                Color.clear
                    .frame(height: 1)
                    .accessibilityHidden(true)
            }
            .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet, hardEdge: !accessibilitySize) {
                pinnedBar(accessibilitySize: accessibilitySize)
            })
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isCreating {
                        SheetCloseButton { close() }
                            // B4.12: attached to Close, so the iOS 26 popover points at it.
                            .confirmationDialog("Discard this?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                                Button("Discard", role: .destructive) { dismiss() }
                                Button("Keep editing", role: .cancel) {}
                            }
                    }
                }
            }
        }
        .sheetChrome([.large])
        .interactiveDismissDisabled(hasEdits || isCreating)
        .sensoryFeedback(.selection, trigger: kind)
        .sensoryFeedback(.error, trigger: failureTick)
        .onAppear { titleFocused = true }
    }

    private func close() {
        if hasEdits {
            confirmsDiscard = true
        } else {
            dismiss()
        }
    }

    // MARK: Form (B4.10)

    private func form(accessibilitySize: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Create group")
                .textStyle(.title1)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
                .padding(.top, Spacing.space2)

            MoolaTextField("Name", text: $name, placeholder: "e.g. Family savings", autocapitalization: .sentences)
                .onChange(of: name) { _, newValue in
                    if newValue.count > Self.nameLimit {
                        name = String(newValue.prefix(Self.nameLimit))
                    }
                }
                .padding(.top, Spacing.space6)

            fieldLabel("How it works")
                .padding(.top, Spacing.fieldToNextLabel)
            VStack(spacing: Spacing.gridGap) {
                kindCard(.takeTurns, description: GroupsCopy.takeTurnsDescription, identifier: "groups.create.takeTurns")
                kindCard(.saveTogether, description: GroupsCopy.saveTogetherDescription, identifier: "groups.create.saveTogether")
            }
            .padding(.top, Spacing.labelToField)

            fieldLabel("Each person pays per round")
                .padding(.top, Spacing.fieldToNextLabel)
            AmountEntry(
                buffer: $buffer,
                context: nil,
                presets: [2_000, 5_000, 10_000, 20_000].map { AmountPreset.amount(Money(cents: Int64($0))) },
                maximum: Self.maximumContribution,
                validationMessage: amountMessage
            )
            .padding(.top, Spacing.labelToField)

            countStepper
                .padding(.top, Spacing.fieldToNextLabel)

            Text("How often")
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, Spacing.fieldToNextLabel)
            Picker("How often", selection: $frequency) {
                ForEach(GroupFrequency.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("groups.create.frequency")
            .padding(.top, Spacing.labelToField)

            inviteRow(accessibilitySize: accessibilitySize)
                .padding(.top, Spacing.fieldToNextLabel)
            if let emailMessage {
                Text(emailMessage)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("groups.create.emailError")
                    .padding(.top, Spacing.space2)
                    .transition(.opacity)
            }
            if !emails.isEmpty {
                ChipFlowLayout(spacing: Spacing.space2, alignment: .leading) {
                    ForEach(emails, id: \.self) { email in
                        RemovableChip(text: email) {
                            emails.removeAll { $0 == email }
                            emailError = nil
                        }
                    }
                }
                .padding(.top, Spacing.space3)
            }

            if let summaryText {
                Text(summaryText)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("groups.create.summary")
                    .padding(.top, Spacing.space6)
                    .transition(.opacity)
            }

            // At accessibility sizes the pinned bar keeps only the button; its
            // banner and reason line move here, in the bar's order (A8.30).
            if accessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    if let errorMessage {
                        ErrorBanner(errorMessage)
                    }
                    if !canCreate && !isCreating {
                        Text(disabledReason)
                            .textStyle(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.top, Spacing.space6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion, value: summaryText != nil)
        .animation(motion, value: emailMessage)
        .animation(motion, value: emails)
    }

    /// A label above a group of controls (`body` `textPrimary`, header trait).
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .textStyle(.body)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private func kindCard(_ option: GroupKind, description: String, identifier: String) -> some View {
        ChoiceCard(title: option.label, description: description, isSelected: kind == option) {
            guard kind != option else { return }
            withAnimation(motion) {
                kind = option
                emailError = nil
            }
        }
        // B4.10: one element, label = the title, value = the description.
        .accessibilityLabel(option.label)
        .accessibilityValue(description)
        .accessibilityIdentifier(identifier)
    }

    @ViewBuilder
    private var countStepper: some View {
        switch kind {
        case .takeTurns:
            stepper(title: "Number of people (including you)", value: $people, range: Self.peopleRange, identifier: "groups.create.people")
        case .saveTogether:
            stepper(title: "Number of rounds", value: $rounds, range: Self.roundsRange, identifier: "groups.create.rounds")
        }
    }

    /// A system `Stepper` on the sheet, the value leading as a figure, no box
    /// (B4.10, reference `B4StepperRow`). The Stepper carries the label, the
    /// value and the identifier, so its − and + stay reachable as today.
    private func stepper(title: String, value: Binding<Int>, range: ClosedRange<Int>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Stepper(value: value, in: range) {
                Text(value.wrappedValue, format: .number)
                    .textStyle(.amountRow)
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(minHeight: Size.textFieldHeight)
            .accessibilityLabel(title)
            .accessibilityValue("\(value.wrappedValue)")
            .accessibilityIdentifier(identifier)
            .padding(.top, Spacing.labelToField)
            .onChange(of: value.wrappedValue) { _, _ in
                emailError = nil
            }
        }
    }

    /// The invite field and "Add", bottom-aligned and 12 apart; stacked, with
    /// "Add" full width, at accessibility sizes.
    private func inviteRow(accessibilitySize: Bool) -> some View {
        let row = accessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space3))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: Spacing.space3))
        return row {
            MoolaTextField(
                "Invite by email \u{00B7} optional",
                text: $emailText,
                placeholder: "friend@example.com",
                contentType: .emailAddress,
                keyboard: .emailAddress,
                autocapitalization: .never,
                autocorrection: false
            )
            .onSubmit(addEmail)
            MoolaButton("Add", kind: .secondary, size: .small, fillsWidth: accessibilitySize ? true : nil, action: addEmail)
                .disabled(emailText.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("groups.create.addEmail")
                .frame(minHeight: accessibilitySize ? nil : Size.textFieldHeight)
        }
    }

    // MARK: Pinned bar (A8.30)

    @ViewBuilder
    private func pinnedBar(accessibilitySize: Bool) -> some View {
        VStack(spacing: 0) {
            if !accessibilitySize, let errorMessage {
                ErrorBanner(errorMessage)
                    .padding(.bottom, Spacing.space3)
                    .transition(.opacity)
            }
            MoolaButton("Create group", loadingTitle: "Creating\u{2026}", isLoading: isCreating) {
                create()
            }
            .disabled(!canCreate)
            .accessibilityHint(canCreate ? "" : disabledReason)
            .accessibilityIdentifier("groups.create.submit")
            if !accessibilitySize {
                DisabledReasonLine(text: disabledReason, isShown: !canCreate && !isCreating)
                    .padding(.top, Spacing.space2)
            }
        }
        .animation(motion, value: errorMessage)
    }

    // MARK: Actions

    private func addEmail() {
        let email = Validation.normalizedEmail(emailText)
        guard !email.isEmpty else { return }
        guard Validation.isValidEmail(email) else {
            emailError = GroupsCopy.invalidEmail
            return
        }
        if emails.contains(email) {
            emailText = ""
            emailError = nil
            return
        }
        guard emails.count < inviteLimit else {
            emailError = GroupsCopy.inviteLimit(max(0, inviteLimit))
            return
        }
        emails.append(email)
        emailText = ""
        emailError = nil
    }

    private func create() {
        guard canCreate, let contribution = validContribution, !isCreating else { return }
        let input: CircleInput
        switch kind {
        case .takeTurns:
            input = .takeTurns(name: trimmedName, contribution: contribution, people: people, frequency: frequency, memberEmails: emails)
        case .saveTogether:
            input = .saveTogether(name: trimmedName, contribution: contribution, rounds: rounds, frequency: frequency, memberEmails: emails)
        }
        isCreating = true
        errorMessage = nil
        Task {
            do throws(APIError) {
                let created = try await services.api.send(API.Groups.create(input))
                isCreating = false
                GroupsToastCenter.shared.post("Group created.", to: .detail(created.id))
                dismiss()
                services.navigator.open(.groupDetail(id: created.id))
            } catch {
                isCreating = false
                guard error != .cancelled, error != .sessionExpired else { return }
                errorMessage = error.message(for: .action)
                failureTick += 1
            }
        }
    }
}
