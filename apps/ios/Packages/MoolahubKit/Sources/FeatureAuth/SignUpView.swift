import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Sign up (DESIGN.md v2 B1.14, B1.15; account.md §10): legal name, username
/// with a live availability check, email, password, date of birth and the
/// optional "How did you hear about MoolaHub?" →
/// `POST /auth/register` → Verify email.
struct SignUpView: View {
    let services: AppServices
    @Binding var path: [AuthRoute]

    private enum Field: Hashable, CaseIterable {
        case name, username, email, password, dateOfBirth
    }

    /// The field Next moves to (shown with the focused one, `AuthScreen`).
    private static func nextField(after field: Field) -> Field? {
        switch field {
        case .name: .username
        case .username: .email
        case .email: .password
        case .password: .dateOfBirth
        case .dateOfBirth: nil
        }
    }

    private enum UsernameStatus: Equatable {
        case idle, checking, available, taken
    }

    private static let emptyReason = "Fill in every required field to continue."
    private static let invalidReason = "Fix the highlighted field to continue."

    @State private var name = ""
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var dateOfBirth: Date?
    /// Optional; nil until a choice is made ("Choose one"). Kept after a
    /// server error, like the other fields.
    @State private var referral: ReferralChoice?
    @State private var touched: Set<Field> = []
    @State private var usernameStatus = UsernameStatus.idle
    @State private var showsCalendar = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var failureCount = 0
    @State private var blockedCount = 0
    @FocusState private var focus: Field?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var statusSymbolSize: CGFloat = 14

    var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        AuthScreen(
            scrollToTopOn: errorMessage,
            focusedField: focus.map(AnyHashable.init),
            nextField: focus.flatMap(Self.nextField(after:)).map(AnyHashable.init),
            layoutKey: AnyHashable(visibleErrors)
        ) {
            AuthTitle("Create your account", subtitle: "It takes about a minute.")

            if let errorMessage {
                ErrorBanner(errorMessage)
                    .accessibilityIdentifier("auth.signUp.error")
                    .padding(.top, Spacing.space6)
                    .transition(.opacity)
            }

            MoolaTextField(
                "Legal name \u{00B7} private", text: $name, placeholder: "e.g. Ama Mensah",
                error: visibleError(.name), contentType: .name, autocapitalization: .words,
                autocorrection: false
            )
            .focused($focus, equals: .name)
            .submitLabel(.next)
            .onSubmit { focus = .username }
            .id(Field.name)
            .padding(.top, Spacing.space6)

            MoolaTextField(
                "Username \u{00B7} public", text: $username,
                hint: "3\u{2013}30 letters, numbers or underscores", error: visibleError(.username),
                leadingAdornment: "@", contentType: .nickname, autocapitalization: .never,
                autocorrection: false, trailing: AnyView(usernameStatusView)
            )
            .focused($focus, equals: .username)
            .submitLabel(.next)
            .onSubmit { focus = .email }
            .id(Field.username)
            .padding(.top, Spacing.fieldToNextLabel)

            MoolaTextField(
                "Email", text: $email, error: visibleError(.email), contentType: .username,
                keyboard: .emailAddress, autocapitalization: .never, autocorrection: false
            )
            .focused($focus, equals: .email)
            .submitLabel(.next)
            .onSubmit { focus = .password }
            .id(Field.email)
            .padding(.top, Spacing.fieldToNextLabel)

            MoolaTextField(
                "Password", text: $password, hint: "At least 8 characters",
                error: visibleError(.password), isSecure: true, contentType: .newPassword,
                autocapitalization: .never, autocorrection: false
            )
            .focused($focus, equals: .password)
            .submitLabel(.done)
            .onSubmit { Task { await submit() } }
            .id(Field.password)
            .padding(.top, Spacing.fieldToNextLabel)

            // B1.15: the system graphical calendar in a popover; no default
            // value, "Choose a date" until a day is picked.
            PickerField(
                label: "Date of birth \u{00B7} private",
                value: dateOfBirth.map { $0.formatted(date: .abbreviated, time: .omitted) },
                placeholder: "Choose a date",
                accessibilityValue: dateOfBirthSpoken,
                trailingSymbol: "calendar",
                error: visibleError(.dateOfBirth),
                identifier: "auth.signUp.dateOfBirth"
            ) {
                showsCalendar = true
            }
            .popover(isPresented: $showsCalendar) {
                DateOfBirthCalendar(date: $dateOfBirth)
                    .presentationCompactAdaptation(.popover)
            }
            .id(Field.dateOfBirth)
            .padding(.top, Spacing.fieldToNextLabel)

            referralMenu
                .padding(.top, Spacing.fieldToNextLabel)

            if accessibilitySize {
                // Accessibility sizes: the bar keeps only the main button; the
                // reason and the footer prompt scroll with the form (B1.0.2).
                reasonLine
                    .padding(.top, Spacing.space6)
                footer
                    .padding(.top, Spacing.space3)
            }
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: errorMessage)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: visibleErrors)
        // B1.0.3: a hard bottom edge at every size (the reason slot and the
        // footer sit under the button; at accessibility sizes the form scrolls
        // under the tall button).
        .modifier(PinnedActionBar(
            inset: Spacing.screenGutter,
            ground: .canvas,
            bottomPadding: PinnedBarMetrics.bottomPadding(
                bottomSafeArea: PinnedBarMetrics.windowBottomSafeArea, endsWithFooterRow: !accessibilitySize
            ),
            hardEdge: true,
            keyboardMargin: true
        ) {
            VStack(spacing: 0) {
                MoolaButton("Create account", loadingTitle: "Creating account\u{2026}", isLoading: isSubmitting) {
                    Task { await submit() }
                }
                .disabled(!canSubmit && !isSubmitting)
                .accessibilityIdentifier("auth.signUp.submit")
                .accessibilityHint(showsReason ? reasonText : "")
                if !accessibilitySize {
                    reasonLine
                        .padding(.top, Spacing.space2)
                    footer
                        .padding(.top, Spacing.space1)
                }
            }
        })
        .onChange(of: focus) { previous, _ in
            // Field errors appear when the field loses focus (blur).
            if let previous { touched.insert(previous) }
        }
        .onChange(of: dateOfBirth) { _, _ in touched.insert(.dateOfBirth) }
        .task(id: normalizedUsername) { await checkUsername(normalizedUsername) }
        .sensoryFeedback(.error, trigger: failureCount)
        .sensoryFeedback(.warning, trigger: blockedCount)
    }

    /// "Already have an account?" + "Sign in".
    private var footer: some View {
        AuthFooterPrompt(prompt: "Already have an account?", actionTitle: "Sign in", identifier: "auth.signUp.signIn") {
            path = [.signIn]
        }
    }

    /// "How did you hear about MoolaHub?" (B1.14 amended, W10.9-acc14 to
    /// acc16): the `PickerField` menu variant, last and optional. The server's
    /// seven keys in its order, then "Prefer not to say" after a divider,
    /// which sends nothing. Never disables the button, never shows an error;
    /// not in the keyboard's return chain.
    private var referralMenu: some View {
        PickerMenuField(
            label: "How did you hear about MoolaHub? \u{00B7} optional",
            value: referral?.displayName,
            placeholder: "Choose one",
            hint: "Shows choices.",
            selection: $referral,
            identifier: "auth.signUp.referralSource"
        ) {
            ForEach(ReferralChoice.sources, id: \.self) { choice in
                Text(choice.displayName).tag(ReferralChoice?.some(choice))
            }
        } trailingOptions: {
            // After the menu's separator (B1.14 amended).
            Text(ReferralChoice.preferNotToSay.displayName).tag(ReferralChoice?.some(.preferNotToSay))
        }
    }

    /// The date control's VoiceOver value (A8.26): the long date, or
    /// "Choose a date" until one is picked (tested).
    private var dateOfBirthSpoken: String {
        dateOfBirth.map { $0.formatted(date: .long, time: .omitted) } ?? "Choose a date"
    }

    // MARK: Disabled reason (A9.9, W10.4)

    /// Every required field has something in it (the date is picked); the
    /// referral menu is optional.
    private var everyFieldFilled: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && dateOfBirth != nil
    }

    /// "Fill in every required field…" while any required field is empty
    /// (W10.4-chg1); "Fix the highlighted field…" once every one has a value
    /// but one is invalid or the username is taken. Kept while the line fades out, so the text never swaps mid-fade.
    private var reasonText: String {
        everyFieldFilled ? Self.invalidReason : Self.emptyReason
    }

    private var showsReason: Bool {
        !isFormValid && !isSubmitting
    }

    /// The reserved reason slot under "Create account" (B1.0.3).
    private var reasonLine: some View {
        DisabledReasonLine(text: reasonText, isShown: showsReason)
    }

    // MARK: Username availability

    private var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The field's trailing status (A8.26): "Checking…" `textSecondary`;
    /// `checkmark` + "Available" `jadeText`; `xmark` + "Taken" `redText`, in
    /// `subheadline`, cross-fading. At accessibility sizes only the symbol
    /// shows, labelled.
    private var usernameStatusView: some View {
        ZStack {
            switch usernameStatus {
            case .idle:
                EmptyView()
            case .checking:
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        ProgressView()
                            .accessibilityLabel("Checking\u{2026}")
                    } else {
                        Text("Checking\u{2026}")
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize()
                    }
                }
                .transition(.opacity)
            case .available:
                statusLabel("Available", systemImage: "checkmark", color: Palette.jadeText)
                    .transition(.opacity)
            case .taken:
                statusLabel("Taken", systemImage: "xmark", color: Palette.redText)
                    .transition(.opacity)
            }
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: usernameStatus)
        .accessibilityIdentifier("auth.signUp.usernameStatus")
    }

    @ViewBuilder
    private func statusLabel(_ title: String, systemImage: String, color: Color) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            Image(systemName: systemImage)
                .font(.system(size: statusSymbolSize, weight: .medium))
                .foregroundStyle(color)
                .accessibilityLabel(title)
        } else {
            Label(title, systemImage: systemImage)
                .labelStyle(.titleAndIcon)
                .textStyle(.subheadline)
                .foregroundStyle(color)
                .fixedSize()
        }
    }

    /// `GET /auth/username-available` 400ms after typing stops. A failed check
    /// shows nothing: the server checks again on submit.
    private func checkUsername(_ candidate: String) async {
        guard Validation.isValidUsername(candidate) else {
            usernameStatus = .idle
            return
        }
        usernameStatus = .checking
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        do throws(APIError) {
            let result = try await services.session.isUsernameAvailable(candidate)
            guard !Task.isCancelled else { return }
            usernameStatus = result.available ? .available : .taken
        } catch {
            guard !Task.isCancelled else { return }
            usernameStatus = .idle
        }
    }

    // MARK: Validation

    private func error(for field: Field) -> String? {
        switch field {
        case .name:
            name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Please enter your legal name." : nil
        case .username:
            Validation.isValidUsername(normalizedUsername)
                ? nil : "Username must be 3\u{2013}30 characters: letters, numbers or underscores."
        case .email:
            Validation.isValidEmail(email) ? nil : "Please enter a valid email address."
        case .password:
            Validation.isValidPassword(password) ? nil : "Password must be at least 8 characters."
        case .dateOfBirth:
            dateOfBirth == nil ? "Please enter your date of birth." : nil
        }
    }

    private func visibleError(_ field: Field) -> String? {
        touched.contains(field) ? error(for: field) : nil
    }

    /// The errors on screen, so their insertion animates (B1.0.2).
    private var visibleErrors: [String?] {
        Field.allCases.map { visibleError($0) }
    }

    private var isFormValid: Bool {
        Field.allCases.allSatisfy { error(for: $0) == nil } && usernameStatus != .taken
    }

    private var canSubmit: Bool {
        isFormValid && !isSubmitting
    }

    // MARK: Submit

    private func submit() async {
        guard !isSubmitting else { return }
        guard canSubmit, let dateOfBirth else {
            revealFirstProblem()
            return
        }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do throws(APIError) {
            let sentTo = try await services.session.register(
                name: name, username: username, email: email, password: password,
                dateOfBirth: APIDate.dayString(from: dateOfBirth),
                referralSource: referral?.sentSource
            )
            clearPassword()
            path.append(.verifyEmail(email: sentTo.isEmpty ? Validation.normalizedEmail(email) : sentTo))
        } catch {
            clearPassword()
            guard error != .cancelled else { return }
            failureCount += 1
            errorMessage = error.message(for: .action)
            // The scroll moves to the top so the banner shows (B1.14); the
            // keyboard goes down so no focused field hides under the pinned bar.
            focus = nil
        }
    }

    /// The first invalid field shows its error (and takes focus when it's a
    /// text field).
    private func revealFirstProblem() {
        blockedCount += 1
        if let field = Field.allCases.first(where: { error(for: $0) != nil }) {
            touched.insert(field)
            if field != .dateOfBirth { focus = field }
        } else if usernameStatus == .taken {
            focus = .username
        }
    }

    /// Passwords never outlive a request; the cleared field isn't an error yet.
    private func clearPassword() {
        password = ""
        touched.remove(.password)
    }
}
