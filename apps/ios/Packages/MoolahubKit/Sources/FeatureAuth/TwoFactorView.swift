import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Two-factor (DESIGN.md v2 B1.18): `POST /auth/2fa/login` with an
/// authenticator code (the code field) or a backup code (a labelled field).
/// A wrong code (401) shows inline; an expired challenge (400) goes back to
/// Sign in with the server's message. The instruction sentence names both
/// inputs, so the disabled button has no reason line (A9.9 exception).
struct TwoFactorView: View {
    let services: AppServices
    @Binding var path: [AuthRoute]
    @Binding var signInNotice: String?
    let challengeID: String

    @State private var code = ""
    @State private var usesBackupCode = false
    @State private var isVerifying = false
    @State private var codeError: String?
    @State private var errorMessage: String?
    @State private var failureCount = 0
    @FocusState private var codeFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedCode: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSubmit: Bool {
        guard !isVerifying else { return false }
        return usesBackupCode ? !trimmedCode.isEmpty : Validation.isSixDigitCode(trimmedCode)
    }

    var body: some View {
        AuthScreen(scrollToTopOn: errorMessage) {
            AuthTitle(
                "Two-factor authentication",
                subtitle: "Enter the 6-digit code from your authenticator app, or a backup code.",
                focusesOnAppear: false
            )

            if let errorMessage {
                ErrorBanner(errorMessage)
                    .accessibilityIdentifier("auth.twoFactor.error")
                    .padding(.top, Spacing.space6)
                    .transition(.opacity)
            }

            // The mode switch cross-fades the field while the layout makes room.
            ZStack(alignment: .topLeading) {
                if usesBackupCode {
                    MoolaTextField(
                        "Backup code", text: $code, placeholder: "e.g. 1a2b-3c4d", error: codeError,
                        contentType: .oneTimeCode, keyboard: .default, autocapitalization: .never, autocorrection: false
                    )
                    .focused($codeFocused)
                    .submitLabel(.go)
                    .onSubmit { Task { await verify() } }
                    .transition(.opacity)
                } else {
                    CodeField(
                        code: $code, accessibilityLabel: "Authenticator code",
                        error: codeError, isFocused: $codeFocused
                    )
                    .transition(.opacity)
                }
            }
            .padding(.top, Spacing.space6)

            TextLinkButton(usesBackupCode ? "Use an authenticator code" : "Use a backup code", alignment: .leading) {
                usesBackupCode.toggle()
                code = ""
                codeError = nil
            }
            .accessibilityIdentifier("auth.twoFactor.toggleMode")
            .padding(.top, Spacing.space3)
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: usesBackupCode)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: errorMessage)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: codeError)
        .modifier(PinnedActionBar(inset: Spacing.screenGutter, ground: .canvas, hardEdge: false) {
            MoolaButton("Verify and sign in", loadingTitle: "Verifying\u{2026}", isLoading: isVerifying) {
                Task { await verify() }
            }
            .disabled(!canSubmit && !isVerifying)
            .accessibilityIdentifier("auth.twoFactor.submit")
        })
        .onChange(of: code) { _, newValue in
            if !newValue.isEmpty { codeError = nil }
        }
        .task(id: usesBackupCode) {
            // On appear and after switching modes: the switch rebuilds the
            // field (new keyboard), so focus the new one once it's on screen.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            codeFocused = true
        }
        .sensoryFeedback(.error, trigger: failureCount)
    }

    private func verify() async {
        guard canSubmit else { return }
        let entered = trimmedCode
        isVerifying = true
        codeError = nil
        errorMessage = nil
        defer { isVerifying = false }
        do throws(APIError) {
            _ = try await services.session.completeTwoFactor(challengeID: challengeID, code: entered)
            code = ""
            // Signed in: AppFeature swaps to the tabs.
        } catch {
            code = ""
            guard error != .cancelled else { return }
            failureCount += 1
            let message = error.message(for: .action)
            switch error {
            case .rejected(status: 401, _):
                // "That code didn't match. Try a current code or a backup code."
                codeError = message
                AccessibilityNotification.Announcement(message).post()
                codeFocused = true
            case .rejected(status: 400, _):
                // "Your verification session expired. Please sign in again."
                signInNotice = message
                path = [.signIn]
            default:
                errorMessage = message
            }
        }
    }
}
