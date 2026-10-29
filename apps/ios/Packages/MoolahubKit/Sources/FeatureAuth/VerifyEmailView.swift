import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Verify email (DESIGN.md v2 B1.16): `POST /auth/verify-email`, submits by
/// itself at 6 digits, "Resend code" with the 30-second cooldown. A signed-in
/// result needs nothing here (AppFeature swaps to the tabs); a two-factor
/// challenge pushes Two-factor. The instruction sentence names the code, so
/// the disabled button has no reason line (A9.9 exception).
struct VerifyEmailView: View {
    let services: AppServices
    @Binding var path: [AuthRoute]
    let email: String

    @State private var code = ""
    @State private var isVerifying = false
    @State private var codeError: String?
    @State private var errorMessage: String?
    @State private var failureCount = 0
    @FocusState private var codeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledTypeFont(.headline) private var emphasis

    var body: some View {
        AuthScreen(scrollToTopOn: errorMessage) {
            AuthTitle(
                "Verify your email",
                subtitle: Text("We sent a 6-digit code to \(AuthText.email(email, font: emphasis)). It expires in 15 minutes."),
                focusesOnAppear: false
            )

            if let errorMessage {
                ErrorBanner(errorMessage)
                    .accessibilityIdentifier("auth.verify.error")
                    .padding(.top, Spacing.space6)
                    .transition(.opacity)
            }

            CodeField(
                code: $code, accessibilityLabel: "Verification code", identifier: "auth.verify.code",
                error: codeError, isFocused: $codeFocused
            )
            .padding(.top, Spacing.space6)

            ResendCodeButton {
                () async throws(APIError) in
                try await services.session.resendVerificationCode(email: email)
            } onSent: {
                // The old code was replaced: its error no longer applies.
                codeError = nil
                errorMessage = nil
            } onFailure: { message in
                failureCount += 1
                errorMessage = message
            }
            .padding(.top, Spacing.space3)
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: errorMessage)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: codeError)
        .modifier(PinnedActionBar(inset: Spacing.screenGutter, ground: .canvas, hardEdge: false) {
            MoolaButton("Verify and continue", loadingTitle: "Verifying\u{2026}", isLoading: isVerifying) {
                Task { await verify() }
            }
            .disabled(!Validation.isSixDigitCode(code) && !isVerifying)
            .accessibilityIdentifier("auth.verify.submit")
        })
        .onChange(of: code) { _, newValue in
            if !newValue.isEmpty { codeError = nil }
            if Validation.isSixDigitCode(newValue) {
                Task { await verify() }
            }
        }
        .onAppear { codeFocused = true }
        .sensoryFeedback(.error, trigger: failureCount)
    }

    private func verify() async {
        guard Validation.isSixDigitCode(code), !isVerifying else { return }
        let entered = code
        isVerifying = true
        codeError = nil
        errorMessage = nil
        defer { isVerifying = false }
        do throws(APIError) {
            let outcome = try await services.session.verifyEmail(email: email, code: entered)
            code = ""
            switch outcome {
            case .signedIn, .emailVerificationRequired:
                break
            case .twoFactorRequired(let challengeID):
                path.append(.twoFactor(challengeID: challengeID))
            }
        } catch {
            code = ""
            guard error != .cancelled else { return }
            failureCount += 1
            let message = error.message(for: .action)
            if case .rejected(status: 400, _) = error {
                // "That code is invalid or has expired." under the field.
                codeError = message
                AccessibilityNotification.Announcement(message).post()
                codeFocused = true
            } else {
                errorMessage = message
            }
        }
    }
}
