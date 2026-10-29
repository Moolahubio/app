import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Sign in (DESIGN.md v2 B1.17): `POST /auth/login` → signed in (AppFeature
/// swaps to the tabs), Two-factor, or Verify email. One banner at a time in
/// the banner slot: an arrival notice (password reset, signed out, expired
/// two-factor session) until the next attempt, which an error replaces.
struct SignInView: View {
    let services: AppServices
    @Binding var path: [AuthRoute]
    /// A message to show on arrival from another step (an expired two-factor
    /// session). Cleared on the next attempt.
    var notice: Binding<String?> = .constant(nil)

    private enum Field: Hashable {
        case email, password
    }

    private static let disabledReason = "Enter your email and password."

    @State private var email = ""
    @State private var password = ""
    @State private var emailTouched = false
    @State private var isSigningIn = false
    @State private var errorMessage: String?
    /// The arrival banner shows until the next sign-in attempt (B1.6, B1.17).
    @State private var arrivalDismissed = false
    @State private var failureCount = 0
    @State private var blockedCount = 0
    @FocusState private var focus: Field?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var emailError: String? {
        emailTouched && !Validation.isValidEmail(email) ? "Please enter a valid email address." : nil
    }

    /// Everything the request needs: a valid email and a password.
    private var isComplete: Bool {
        Validation.isValidEmail(email) && !password.isEmpty
    }

    private var canSubmit: Bool {
        isComplete && !isSigningIn
    }

    /// Forgot password starts from the email typed here, trimmed, only when it
    /// is a valid email, so that screen never opens with a red field (A14).
    private var forgotPasswordPrefill: String {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return Validation.isValidEmail(trimmed) ? trimmed : ""
    }

    var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        AuthScreen(
            scrollToTopOn: errorMessage,
            focusedField: focus.map(AnyHashable.init),
            nextField: focus == .email ? AnyHashable(Field.password) : nil,
            layoutKey: AnyHashable(emailError)
        ) {
            AuthTitle("Welcome back", subtitle: "Sign in to keep your savings on track.")

            banner

            MoolaTextField(
                "Email", text: $email, error: emailError, contentType: .username, keyboard: .emailAddress,
                autocapitalization: .never, autocorrection: false
            )
            .focused($focus, equals: .email)
            .submitLabel(.next)
            .onSubmit { focus = .password }
            .id(Field.email)
            .padding(.top, Spacing.space6)

            MoolaTextField(
                "Password", text: $password, isSecure: true, contentType: .password,
                autocapitalization: .never, autocorrection: false
            )
            .focused($focus, equals: .password)
            .submitLabel(.go)
            .onSubmit { Task { await signIn() } }
            .id(Field.password)
            .padding(.top, Spacing.fieldToNextLabel)

            TextLinkButton("Forgot password?", alignment: .trailing) { path.append(.forgotPassword(email: forgotPasswordPrefill)) }
                .accessibilityIdentifier("auth.signIn.forgotPassword")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, Spacing.space1)

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
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: emailError)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: arrivalDismissed)
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
                MoolaButton("Sign in", loadingTitle: "Signing in\u{2026}", isLoading: isSigningIn) {
                    Task { await signIn() }
                }
                .disabled(!canSubmit && !isSigningIn)
                .accessibilityIdentifier("auth.signIn.submit")
                .accessibilityHint(isComplete || isSigningIn ? "" : Self.disabledReason)
                if !accessibilitySize {
                    reasonLine
                        .padding(.top, Spacing.space2)
                    footer
                        .padding(.top, Spacing.space1)
                }
            }
        })
        .onChange(of: focus) { previous, _ in
            if previous == .email { emailTouched = true }
        }
        .sensoryFeedback(.error, trigger: failureCount)
        .sensoryFeedback(.warning, trigger: blockedCount)
    }

    /// The reserved reason slot under "Sign in" (A9.9, B1.0.3).
    private var reasonLine: some View {
        DisabledReasonLine(text: Self.disabledReason, isShown: !isComplete && !isSigningIn)
    }

    /// "New to MoolaHub?" + "Create an account".
    private var footer: some View {
        AuthFooterPrompt(prompt: "New to MoolaHub?", actionTitle: "Create an account", identifier: "auth.signIn.createAccount") {
            path = [.createAccount]
        }
    }

    // MARK: Banner slot

    private struct Arrival {
        let message: String
        let tone: PillTone
        let identifier: String
    }

    /// The arrival notice (B1.6, B1.17, W10.3), until the next attempt.
    private var arrival: Arrival? {
        if let message = notice.wrappedValue {
            // The server's "Your verification session expired. Please sign in
            // again." Two-factor sets it after this screen's own attempt (which
            // dismissed the other arrival banners) and pops back here; the next
            // attempt clears it.
            return Arrival(message: message, tone: .neutral, identifier: "auth.signIn.notice")
        }
        guard !arrivalDismissed else { return nil }
        switch services.session.signedOutReason {
        case .passwordReset:
            return Arrival(
                message: "Your password has been reset. Sign in with your new password.",
                tone: .jade, identifier: "auth.signIn.resetBanner"
            )
        case .sessionExpired, .serverChanged:
            return Arrival(message: "You've been signed out. Please sign in again.", tone: .neutral, identifier: "auth.signIn.notice")
        case .userSignedOut, .accountDeactivated, .accountDeleted, nil:
            return nil
        }
    }

    /// One banner at a time: an error replaces the arrival notice.
    @ViewBuilder
    private var banner: some View {
        if let errorMessage {
            ErrorBanner(errorMessage)
                .accessibilityIdentifier("auth.signIn.error")
                .padding(.top, Spacing.space6)
                .transition(.opacity)
        } else if let arrival {
            NoticeBanner(arrival.message, tone: arrival.tone)
                .accessibilityIdentifier(arrival.identifier)
                .onAppear {
                    // Banners are announced (A5.9): why VoiceOver is on Sign in.
                    AccessibilityNotification.Announcement(arrival.message).post()
                }
                .padding(.top, Spacing.space6)
                .transition(.opacity)
        }
    }

    // MARK: Submit

    private func signIn() async {
        guard !isSigningIn else { return }
        guard canSubmit else {
            blockedCount += 1
            if !Validation.isValidEmail(email) {
                emailTouched = true
                focus = .email
            } else {
                focus = .password
            }
            return
        }
        isSigningIn = true
        errorMessage = nil
        arrivalDismissed = true
        notice.wrappedValue = nil
        defer { isSigningIn = false }
        do throws(APIError) {
            let outcome = try await services.session.signIn(email: email, password: password)
            password = ""
            switch outcome {
            case .signedIn:
                break
            case .twoFactorRequired(let challengeID):
                path.append(.twoFactor(challengeID: challengeID))
            case .emailVerificationRequired(let address):
                path.append(.verifyEmail(email: address.isEmpty ? Validation.normalizedEmail(email) : address))
            }
        } catch {
            // 401 "Invalid email or password." and 429 in the banner; the
            // password clears, the email stays.
            password = ""
            guard error != .cancelled else { return }
            failureCount += 1
            errorMessage = error.message(for: .action)
            // The screen scrolls to the top so the banner shows (B1.9); with the
            // keyboard up the focused field would sit under the pinned bar, so
            // the keyboard goes down and the whole form shows under the banner.
            focus = nil
        }
    }
}
