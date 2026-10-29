import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// "Confirm it's you" for Deactivate account and Delete account (account.md
/// B5.15, J0.4, A8.18). The fields are DesignSystem's `StepUpFields` (D-41):
/// with a password the title, the instruction and Password (plus
/// Authenticator code with two-factor on); without one the code-only variant,
/// or the title and the no-password body when there is nothing to prove here.
/// One request per tap, never retried; the password and code are cleared the
/// moment it leaves. A 401 shows inline and never signs out; a delete refused
/// with 409 closes the sheet so Delete account checks again. On success the
/// session ends and the root cross-fades to Welcome with the toast.
struct AccountStepUpSheet: View {
    let services: AppServices
    let action: AccountStepUpAction
    /// Delete only: the server refused (409); Delete account re-checks.
    var onRefused: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var password = ""
    @State private var code = ""
    /// `GET /security/2fa`; nil while it loads or after it failed.
    @State private var twoFactor: TwoFactorStatus?
    @State private var statusError: APIError?
    /// The server's 401 message, verbatim, under the fields.
    @State private var fieldError: String?
    /// Any other failure, in the banner above the button.
    @State private var failure: String?
    @State private var isSubmitting = false
    /// VoiceOver focus on "Confirm it's you" once the sheet is up (B5.15).
    @AccessibilityFocusState private var titleFocused: Bool
    /// Keyboard focus in `StepUpFields`: a 401 sends it back to Password
    /// (B5.15 "Refused"). Nothing is focused on appear (no automatic
    /// keyboard, as B3.24).
    @FocusState private var focusedField: StepUpFields.Field?
    /// Haptic triggers (A6, account.md §13.3).
    @State private var submitCount = 0
    @State private var failureCount = 0

    /// W10.3-acc3: sent, and no answer came back.
    static let noResponseMessage = "We couldn't confirm this. Check your connection and try again."

    /// The end of the content, where the field error and the banners sit.
    private static let messageAnchor = "account.stepUp.message"

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private var standardAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    /// Every iOS sign-in uses a password, so a missing value counts as one.
    private var hasPassword: Bool {
        services.session.currentUser?.hasPassword != false
    }

    /// Whether the code field shows; nil until the status loads.
    private var needsCode: Bool? { twoFactor?.enabled }

    /// No password and no two-factor: such an account can only prove itself
    /// with an emailed code, which iOS does not request (B5.15).
    private var hasNothingToProve: Bool {
        !hasPassword && twoFactor?.enabled == false
    }

    private var isComplete: Bool {
        guard let needsCode else { return false }
        if hasPassword, password.isEmpty { return false }
        if needsCode, !Validation.isSixDigitCode(code.trimmingCharacters(in: .whitespaces)) { return false }
        return hasPassword || needsCode
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasNothingToProve {
                    form
                } else {
                    // The keyboard margin lets the content scroll clear of
                    // the bar while the keyboard is up (iOS 26.5).
                    form
                        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet, keyboardMargin: true) { bar })
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !isSubmitting {
                    ToolbarItem(placement: .cancellationAction) {
                        SheetCloseButton(identifier: "account.stepUp.close") { dismiss() }
                    }
                }
            }
        }
        .sheetChrome([.large])
        .interactiveDismissDisabled(isSubmitting)
        .sensoryFeedback(action == .delete ? .impact(weight: .heavy) : .impact(weight: .medium), trigger: submitCount)
        .sensoryFeedback(.error, trigger: failureCount)
        .task { await loadStatus() }
        .task {
            // Once the sheet has finished presenting, so VoiceOver lands on
            // the title (as the money sheets do).
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            titleFocused = true
        }
    }

    // MARK: Content

    private var form: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StepUpFields(
                        password: $password,
                        code: $code,
                        needsCode: needsCode,
                        error: fieldError,
                        needsPassword: hasPassword,
                        errorIdentifier: "account.stepUp.fieldError",
                        titleFocus: $titleFocused,
                        fieldFocus: $focusedField
                    )
                    if hasNothingToProve {
                        // 8 pt under the title: the title's own bottom padding.
                        Text("This account doesn't have a password. You can deactivate or delete it on the MoolaHub website.")
                            .textStyle(.body)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let statusError {
                        ErrorBanner(statusError.message(for: .screen)) {
                            Task { await loadStatus() }
                        }
                        .accessibilityIdentifier("account.stepUp.statusError")
                        .padding(.top, Spacing.space4)
                        .transition(.opacity)
                    }
                    if isAccessibilitySize, let failure {
                        // A8.30: at accessibility sizes the bar keeps only its
                        // button; the failure follows the fields.
                        failureBanner(failure)
                            .padding(.top, Spacing.space6)
                            .transition(.opacity)
                    }
                    Color.clear
                        .frame(height: 0)
                        .id(Self.messageAnchor)
                }
                .padding(.horizontal, Spacing.sheetPadding)
                .padding(.top, Spacing.space2)
                .padding(.bottom, Spacing.space6)
                .animation(standardAnimation, value: fieldError)
                .animation(standardAnimation, value: statusError)
                .animation(standardAnimation, value: needsCode)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
            // A refusal can land under the keyboard and the bar: the field
            // error and the status banner when the form is long (accessibility
            // sizes, or two-factor on a small iPhone), the failure banner at
            // accessibility sizes, where it follows the fields. Each is
            // scrolled into view above the bar once the keyboard, the bar and
            // a 401's move of focus back to Password have settled, as
            // `AuthScreen` and Profile wait: a scroll sent at once was undone
            // by the scroll to the newly focused field. The bar's keyboard
            // margin (`PinnedActionBar(keyboardMargin:)`) gives the content
            // the room to scroll that far (on iOS 26.5 it lands about a bar's
            // height higher than `.bottom` asks, measured at AX5).
            .task(id: shownMessage) {
                guard shownMessage != nil else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(standardAnimation) {
                    proxy.scrollTo(Self.messageAnchor, anchor: .bottom)
                }
            }
        }
    }

    /// The message the content scrolls to: the field error, else the status
    /// error, else, at accessibility sizes, the failure (in the bar otherwise).
    private var shownMessage: String? {
        fieldError ?? statusError?.message(for: .screen) ?? (isAccessibilitySize ? failure : nil)
    }

    /// The failure banner 12 pt above the button, then the destructive
    /// button (no reason slot: the instruction names every input, A9.9).
    private var bar: some View {
        VStack(spacing: 0) {
            if !isAccessibilitySize, let failure {
                failureBanner(failure)
                    .padding(.bottom, Spacing.space3)
                    .transition(.opacity)
            }
            MoolaButton(action.submitTitle, kind: .destructive, loadingTitle: action.loadingTitle, isLoading: isSubmitting) {
                submit()
            }
            .disabled(!isComplete && !isSubmitting)
            .accessibilityIdentifier("account.stepUp.submit")
        }
        .animation(standardAnimation, value: failure)
    }

    private func failureBanner(_ message: String) -> some View {
        ErrorBanner(message)
            .accessibilityIdentifier("account.stepUp.error")
    }

    // MARK: Requests

    private func loadStatus() async {
        statusError = nil
        do throws(APIError) {
            twoFactor = try await services.api.send(API.Security.twoFactorStatus())
        } catch {
            if error != .cancelled { statusError = error }
        }
    }

    private func submit() {
        guard isComplete, !isSubmitting else { return }
        let proof = StepUpProof(
            currentPassword: hasPassword ? Secret(password) : nil,
            twoFactorCode: needsCode == true ? Secret(code.trimmingCharacters(in: .whitespaces)) : nil
        )
        // Never kept past the request (J0.4).
        password = ""
        code = ""
        fieldError = nil
        failure = nil
        isSubmitting = true
        submitCount &+= 1
        let api = services.api
        let action = action
        Task {
            do throws(APIError) {
                switch action {
                case .deactivate:
                    _ = try await api.send(API.Account.deactivate(proof))
                case .delete:
                    _ = try await api.send(API.Account.delete(DeleteAccountInput(proof: proof)))
                }
            } catch {
                isSubmitting = false
                show(error)
                return
            }
            // The server already ended every session: no logout request.
            // The root cross-fades to Welcome, which shows the toast.
            await services.session.endSessionAfterAccountClosed(action.closedReason)
        }
    }

    /// The response table of B5.15. The server's 400 sentence is never shown
    /// (it quotes a word iOS never asks for), nor are the 409 sentences.
    private func show(_ error: APIError) {
        switch error {
        case .cancelled, .sessionExpired:
            // Session expiry signs out by itself (B1.6).
            return
        case .rejected(status: 401, let message):
            let text = message ?? APIError.Copy.generic
            fieldError = text
            focusedField = .password
            AccessibilityNotification.Announcement(text).post()
        case .rejected(status: 409, _) where action == .delete:
            failureCount &+= 1
            onRefused()
            dismiss()
            return
        case .noResponse:
            failure = Self.noResponseMessage
        case .notConnected, .rateLimited, .misconfigured:
            failure = error.message(for: .action)
        case .rejected, .server, .invalidResponse:
            failure = APIError.Copy.generic
        }
        failureCount &+= 1
    }
}
