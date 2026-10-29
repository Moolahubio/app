import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Forgot password, step 1 (DESIGN.md v2 B1.19, account.md §9):
/// `POST /auth/forgot-password`, then step 2 (Reset password) with the email.
/// The email starts as Sign in's when that one was valid. The subtitle asks
/// for the email, so the disabled button has no reason line (A9.9 exception).
struct ForgotPasswordView: View {
    let services: AppServices
    @Binding var path: [AuthRoute]

    @State private var email: String
    @State private var emailTouched = false
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var failureCount = 0
    @State private var blockedCount = 0
    @FocusState private var emailFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `email`: Sign in's email when it was valid, else "" (A14). Shown as
    /// typed; no keyboard focus is forced, so the person sees the address and
    /// the enabled button.
    init(services: AppServices, path: Binding<[AuthRoute]>, email: String = "") {
        self.services = services
        self._path = path
        self._email = State(initialValue: email)
    }

    private var emailError: String? {
        emailTouched && !Validation.isValidEmail(email) ? "Please enter a valid email address." : nil
    }

    private var canSubmit: Bool {
        Validation.isValidEmail(email) && !isSending
    }

    var body: some View {
        AuthScreen(scrollToTopOn: errorMessage) {
            AuthTitle("Forgot your password?", subtitle: "Enter your email and we'll send you a reset code.")

            if let errorMessage {
                ErrorBanner(errorMessage)
                    .accessibilityIdentifier("auth.forgot.error")
                    .padding(.top, Spacing.space6)
                    .transition(.opacity)
            }

            MoolaTextField(
                "Email", text: $email, error: emailError, contentType: .username, keyboard: .emailAddress,
                autocapitalization: .never, autocorrection: false
            )
            .focused($emailFocused)
            .submitLabel(.send)
            .onSubmit { Task { await send() } }
            .padding(.top, Spacing.space6)
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: errorMessage)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: emailError)
        .modifier(PinnedActionBar(inset: Spacing.screenGutter, ground: .canvas, hardEdge: false) {
            MoolaButton("Send reset code", loadingTitle: "Sending\u{2026}", isLoading: isSending) {
                Task { await send() }
            }
            .disabled(!canSubmit && !isSending)
            .accessibilityIdentifier("auth.forgot.submit")
        })
        .onChange(of: emailFocused) { wasFocused, _ in
            if wasFocused { emailTouched = true }
        }
        .sensoryFeedback(.error, trigger: failureCount)
        .sensoryFeedback(.warning, trigger: blockedCount)
    }

    private func send() async {
        guard !isSending else { return }
        guard canSubmit else {
            emailTouched = true
            emailFocused = true
            blockedCount += 1
            return
        }
        isSending = true
        errorMessage = nil
        defer { isSending = false }
        do throws(APIError) {
            try await services.session.requestPasswordReset(email: email)
            path.append(.resetPassword(email: Validation.normalizedEmail(email)))
        } catch {
            guard error != .cancelled else { return }
            failureCount += 1
            // Verbatim: 404 "We couldn't find an account with that email address.", 429, 409.
            errorMessage = error.message(for: .action)
        }
    }
}

/// Reset password, step 2 (DESIGN.md v2 B1.20): code + new password →
/// `POST /auth/reset-password`. On success the session store moves to
/// `.signedOut(.passwordReset)` and the flow restarts on Sign in with the
/// positive banner.
struct ResetPasswordView: View {
    let services: AppServices
    @Binding var path: [AuthRoute]
    let email: String

    private enum Field: Hashable {
        case code, newPassword, confirmPassword
    }

    private static let disabledReason = "Enter the code and a new password."

    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var touched: Set<Field> = []
    @State private var isResetting = false
    @State private var codeError: String?
    @State private var errorMessage: String?
    @State private var failureCount = 0
    @State private var blockedCount = 0
    @FocusState private var focus: Field?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledTypeFont(.headline) private var emphasis

    private var newPasswordError: String? {
        touched.contains(.newPassword) && !Validation.isValidPassword(newPassword)
            ? "Password must be at least 8 characters." : nil
    }

    private var confirmError: String? {
        touched.contains(.confirmPassword) && confirmPassword != newPassword ? "Passwords don't match." : nil
    }

    /// A 6-digit code, a valid new password and a matching confirmation.
    private var isComplete: Bool {
        Validation.isSixDigitCode(code) && Validation.isValidPassword(newPassword) && confirmPassword == newPassword
    }

    private var canSubmit: Bool {
        isComplete && !isResetting
    }

    var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        AuthScreen(
            scrollToTopOn: errorMessage,
            focusedField: focus.map(AnyHashable.init),
            nextField: focus == .code ? AnyHashable(Field.newPassword) : (focus == .newPassword ? AnyHashable(Field.confirmPassword) : nil),
            layoutKey: AnyHashable([codeError, newPasswordError, confirmError])
        ) {
            AuthTitle(
                "Reset your password",
                subtitle: Text("A 6-digit code is on its way to \(AuthText.email(email, font: emphasis)). Enter it with a new password.")
            )

            if let errorMessage {
                ErrorBanner(errorMessage)
                    .accessibilityIdentifier("auth.reset.error")
                    .padding(.top, Spacing.space6)
                    .transition(.opacity)
            }

            // A labelled field among three, not the hero code field (B1.20).
            MoolaTextField(
                "Reset code", text: $code, placeholder: "6-digit code", error: codeError,
                contentType: .oneTimeCode, keyboard: .numberPad, autocapitalization: .never,
                autocorrection: false
            )
            .monospacedDigit()
            .focused($focus, equals: .code)
            .id(Field.code)
            .padding(.top, Spacing.space6)

            ResendCodeButton {
                () async throws(APIError) in
                try await services.session.requestPasswordReset(email: email)
            } onSent: {
                // The old code was replaced: its error no longer applies.
                codeError = nil
                errorMessage = nil
            } onFailure: { message in
                failureCount += 1
                errorMessage = message
            }
            .padding(.top, Spacing.space1)

            MoolaTextField(
                "New password", text: $newPassword, hint: "At least 8 characters", error: newPasswordError,
                isSecure: true, contentType: .newPassword, autocapitalization: .never, autocorrection: false
            )
            .focused($focus, equals: .newPassword)
            .submitLabel(.next)
            .onSubmit { focus = .confirmPassword }
            .id(Field.newPassword)
            .padding(.top, Spacing.fieldToNextLabel)

            MoolaTextField(
                "Confirm new password", text: $confirmPassword, error: confirmError, isSecure: true,
                contentType: .newPassword, autocapitalization: .never, autocorrection: false
            )
            .focused($focus, equals: .confirmPassword)
            .submitLabel(.done)
            .onSubmit { Task { await reset() } }
            .id(Field.confirmPassword)
            .padding(.top, Spacing.fieldToNextLabel)

            if accessibilitySize {
                // Accessibility sizes: the bar keeps only the main button; the
                // reason scrolls with the form (A8.30).
                reasonLine
                    .padding(.top, Spacing.space6)
            }
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: errorMessage)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: [codeError, newPasswordError, confirmError])
        // B1.0.3: a hard bottom edge at every size (the reason slot sits under
        // the button; at accessibility sizes the form scrolls under it).
        .modifier(PinnedActionBar(inset: Spacing.screenGutter, ground: .canvas, hardEdge: true, keyboardMargin: true) {
            VStack(spacing: 0) {
                MoolaButton("Reset password", loadingTitle: "Resetting\u{2026}", isLoading: isResetting) {
                    Task { await reset() }
                }
                .disabled(!canSubmit && !isResetting)
                .accessibilityIdentifier("auth.reset.submit")
                .accessibilityHint(isComplete || isResetting ? "" : Self.disabledReason)
                if !accessibilitySize {
                    reasonLine
                        .padding(.top, Spacing.space2)
                }
            }
        })
        .onChange(of: focus) { previous, _ in
            if let previous { touched.insert(previous) }
        }
        .onChange(of: code) { _, newValue in
            if !newValue.isEmpty { codeError = nil }
            let digits = newValue.codeDigits()
            if digits != newValue { code = digits }
        }
        .sensoryFeedback(.error, trigger: failureCount)
        .sensoryFeedback(.warning, trigger: blockedCount)
    }

    /// The reserved reason slot under "Reset password" (A9.9, B1.0.3).
    private var reasonLine: some View {
        DisabledReasonLine(text: Self.disabledReason, isShown: !isComplete && !isResetting)
    }

    private func reset() async {
        guard !isResetting else { return }
        guard canSubmit else {
            blockedCount += 1
            touched.formUnion([.newPassword, .confirmPassword])
            if !Validation.isSixDigitCode(code) {
                focus = .code
            } else if !Validation.isValidPassword(newPassword) {
                focus = .newPassword
            } else {
                focus = .confirmPassword
            }
            return
        }
        let enteredCode = code
        let enteredPassword = newPassword
        isResetting = true
        codeError = nil
        errorMessage = nil
        defer { isResetting = false }
        do throws(APIError) {
            try await services.session.resetPassword(email: email, code: enteredCode, newPassword: enteredPassword)
            clearSecrets()
            // The session store is now `.signedOut(.passwordReset)`; AppFeature
            // restarts this flow on Sign in. Make sure we land there regardless.
            path = [.signIn]
        } catch {
            clearSecrets()
            guard error != .cancelled else { return }
            failureCount += 1
            let message = error.message(for: .action)
            if case .rejected(status: 400, _) = error {
                // "That code is invalid or has expired." under the code field.
                codeError = message
                AccessibilityNotification.Announcement(message).post()
                focus = .code
            } else {
                errorMessage = message
                // The banner shows at the top (B1.9); no focused field under the bar.
                focus = nil
            }
        }
    }

    /// Codes and passwords never outlive a request.
    private func clearSecrets() {
        code = ""
        newPassword = ""
        confirmPassword = ""
        touched.subtract([.newPassword, .confirmPassword])
    }
}
