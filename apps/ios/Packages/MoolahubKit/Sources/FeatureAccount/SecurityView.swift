import APIClient
import Auth
import DesignSystem
import Domain
import LocalAuthentication
import SwiftUI

/// Security (DESIGN.md v2 B5.4): Password, the two-factor status (read-only in
/// this build) and the app lock switch, as two groups of text-only rows on the
/// page, each with its footnote.
struct SecurityView: View {
    let services: AppServices
    @Bindable var flow: AccountFlowState

    @State private var twoFactor: RemoteResource<TwoFactorStatus>
    @State private var biometry: BiometryKind = .unavailable
    /// The biometry hardware's name, for the switch when there's no passcode.
    @State private var hardwareBiometryName = SecurityView.detectHardwareBiometryName()
    @State private var isEnablingLock = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices, flow: AccountFlowState) {
        self.services = services
        self.flow = flow
        let api = services.api
        _twoFactor = State(initialValue: RemoteResource {
            try await api.send(API.Security.twoFactorStatus())
        })
    }

    private var standardAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Refresh failed with data: the banner first, 24 pt to the rows (A3.2).
                if let error = twoFactor.error, twoFactor.value != nil {
                    ErrorBanner(error.message(for: .screen)) {
                        Task { await twoFactor.refresh() }
                    }
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.bottom, AccountLayout.statusToContent)
                    .transition(.opacity)
                }

                NavigationLink(value: AccountRoute.changePassword) {
                    SettingsRowLabel(symbol: nil, title: "Password")
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("account.security.password")

                twoFactorRow

                SettingsGroupFootnote("You can turn two-factor on or off on the MoolaHub website.")

                SettingsGroupDivider(textColumnX: Spacing.screenGutter)

                SettingsToggleRow(title: lockTitle, isOn: lockBinding)
                    .disabled(!biometry.isAvailable || isEnablingLock)
                    .accessibilityIdentifier("account.security.appLock")

                SettingsGroupFootnote(lockFootnote)
                    .accessibilityIdentifier("account.security.appLock.footnote")
            }
            .padding(.top, AccountLayout.pushedTop)
            .padding(.bottom, Spacing.space6)
            .animation(standardAnimation, value: twoFactor.value)
        }
        .moolaCanvas()
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
        .toast($flow.securityToast)
        .task { await twoFactor.load() }
        .onChange(of: twoFactor.value) { _, status in
            // Change password starts from this, so its fields don't move (B5.5).
            if let status { flow.twoFactorStatus = status }
        }
        .onAppear { refreshBiometry() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refreshBiometry() }
        }
    }

    // MARK: Two-factor

    /// "Authenticator app" with "Off" or "On" (words, not pills, A8.10), and
    /// "Backup codes left: {n}" when on. One static element, not a button.
    @ViewBuilder
    private var twoFactorRow: some View {
        switch twoFactor.phase {
        case .loaded:
            if let status = twoFactor.value {
                SettingsValueRow(
                    title: "Authenticator app",
                    subtitle: status.enabled ? "Backup codes left: \(status.backupCodesRemaining)" : nil,
                    value: status.enabled ? "On" : "Off"
                )
                .contentTransition(.opacity)
                .accessibilityIdentifier("account.security.twoFactor")
            }
        case .loading:
            SettingsValueRow(title: "Authenticator app") {
                // `body` cap height, scaling with the text it stands in for (A5.7).
                SkeletonBlock(width: 28, height: TypeToken.body.capHeight, relativeTo: TypeToken.body.relativeTo)
            }
            .accessibilityValue("Loading")
            .accessibilityIdentifier("account.security.twoFactor")
        case .failed:
            TwoFactorFailedRow {
                Task { await twoFactor.refresh() }
            }
        }
    }

    // MARK: App lock

    private var lockName: String {
        biometry.isAvailable ? biometry.name : hardwareBiometryName
    }

    private var lockTitle: String {
        "Lock with \(lockName)"
    }

    /// The footnote is also the switch's disabled reason (A9.9).
    private var lockFootnote: String {
        guard biometry.isAvailable else { return "Set a passcode on your iPhone to use app lock." }
        let asksFor = biometry == .passcode ? "your passcode" : biometry.name
        return "MoolaHub asks for \(asksFor) when you open it, and after a minute in the background."
    }

    private var lockBinding: Binding<Bool> {
        Binding(
            get: { services.settings.appLockEnabled },
            set: { isOn in
                if isOn {
                    turnOnLock()
                } else {
                    services.appLock.disable()
                }
            }
        )
    }

    /// Turning it on runs the system prompt once (B5.4); the setting only
    /// flips on success, and the switch is disabled while the prompt is up.
    private func turnOnLock() {
        guard !isEnablingLock else { return }
        isEnablingLock = true
        Task {
            let result = await services.appLock.enable()
            isEnablingLock = false
            if result == .unavailable { refreshBiometry() }
        }
    }

    private func refreshBiometry() {
        biometry = services.authenticator.biometryKind()
        hardwareBiometryName = Self.detectHardwareBiometryName()
    }

    /// The device's biometry hardware, for the switch's name when there is no
    /// passcode (so it still reads "Lock with Face ID").
    private static func detectHardwareBiometryName() -> String {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        switch context.biometryType {
        case .faceID: return BiometryKind.faceID.name
        case .touchID: return BiometryKind.touchID.name
        case .opticID: return BiometryKind.opticID.name
        default: return BiometryKind.passcode.name
        }
    }
}

/// The two-factor row when its status never loaded (B5.4): the sub-line "We
/// couldn't load this." in `redText` and a trailing ink "Try again". Title and
/// sub-line are the element `account.security.twoFactor`; "Try again" is its
/// own button, "We couldn't load this. Try again". `SettingsValueRow` has no
/// red sub-line or separate action, so this state is drawn here on the same
/// geometry (16 pt gutter, 12 pt padding, 68 pt with a sub-line).
private struct TwoFactorFailedRow: View {
    let retry: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        let layout = accessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space1))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.space3))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text("Authenticator app")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("We couldn't load this.")
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: accessibilitySize ? nil : .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("account.security.twoFactor")
            TextLinkButton("Try again", action: retry)
                .accessibilityLabel("We couldn't load this. Try again")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: 68)
    }
}

/// Change password (DESIGN.md v2 B5.5, A8.18). A 401 is shown inline and never
/// signs the user out. The current password and code are cleared after each
/// request and never stored. One save model: the pinned "Save password".
struct ChangePasswordView: View {
    let services: AppServices
    let flow: AccountFlowState

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var twoFactor: RemoteResource<TwoFactorStatus>
    @State private var currentPassword = ""
    @State private var code = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var currentPasswordError: String?
    @State private var codeError: String?
    @State private var newPasswordError: String?
    @State private var confirmError: String?
    @State private var serverError: String?
    @State private var isSaving = false
    @State private var validationFailures = 0
    @State private var saveFailures = 0
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case current, code, new, confirm
    }

    private static let serverErrorAnchor = "account.changePassword.serverError"

    init(services: AppServices, flow: AccountFlowState) {
        self.services = services
        self.flow = flow
        let api = services.api
        _twoFactor = State(initialValue: RemoteResource {
            try await api.send(API.Security.twoFactorStatus())
        })
    }

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private var standardAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    /// Whether the Authenticator code field exists: this screen's fresh status
    /// if it has one, else the one Security already loaded (so the field set
    /// is final when the screen appears), else unknown.
    private var needsCode: Bool? {
        (twoFactor.value ?? flow.twoFactorStatus)?.enabled
    }

    /// The status failed to load and Security had none either.
    private var statusFailedError: APIError? {
        guard needsCode == nil, case .failed(let error) = twoFactor.phase else { return nil }
        return error
    }

    private var disabledReason: String {
        statusFailedError == nil ? "Checking your two-factor setting\u{2026}" : "We couldn't check your two-factor setting."
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = statusFailedError {
                        ErrorBanner(error.message(for: .screen)) {
                            Task { await twoFactor.refresh() }
                        }
                        .padding(.bottom, AccountLayout.statusToContent)
                        .transition(.opacity)
                    }

                    MoolaTextField(
                        "Current password", text: $currentPassword, error: currentPasswordError,
                        isSecure: true, contentType: .password, autocapitalization: .never, autocorrection: false
                    )
                    .focused($focus, equals: .current)
                    .submitLabel(.next)
                    .onSubmit { focus = needsCode == true ? .code : .new }
                    .onChange(of: currentPassword) { _, _ in currentPasswordError = nil }

                    if needsCode == true {
                        MoolaTextField(
                            "Authenticator code", text: $code, placeholder: "6-digit code", error: codeError,
                            contentType: .oneTimeCode, keyboard: .numberPad, autocapitalization: .never, autocorrection: false
                        )
                        .focused($focus, equals: .code)
                        .onChange(of: code) { _, _ in codeError = nil }
                        .padding(.top, Spacing.fieldToNextLabel)
                    }

                    MoolaTextField(
                        "New password", text: $newPassword, hint: "At least 8 characters", error: newPasswordError,
                        isSecure: true, contentType: .newPassword, autocapitalization: .never, autocorrection: false
                    )
                    .focused($focus, equals: .new)
                    .submitLabel(.next)
                    .onSubmit { focus = .confirm }
                    .onChange(of: newPassword) { _, _ in newPasswordError = nil }
                    .padding(.top, Spacing.fieldToNextLabel)

                    MoolaTextField(
                        "Confirm new password", text: $confirmPassword, error: confirmError,
                        isSecure: true, contentType: .newPassword, autocapitalization: .never, autocorrection: false
                    )
                    .focused($focus, equals: .confirm)
                    .submitLabel(.done)
                    .onChange(of: confirmPassword) { _, _ in confirmError = nil }
                    .padding(.top, Spacing.fieldToNextLabel)

                    if isAccessibilitySize {
                        // A8.30: at accessibility sizes the server line and the
                        // reason follow the last field; the bar keeps the button.
                        if let serverError {
                            serverErrorLine(serverError)
                                .id(Self.serverErrorAnchor)
                                .padding(.top, Spacing.space6)
                        }
                        if needsCode == nil {
                            Text(disabledReason)
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, Spacing.space6)
                        }
                    }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, AccountLayout.pushedTop)
                .padding(.bottom, Spacing.space6)
                .animation(standardAnimation, value: needsCode)
                .animation(standardAnimation, value: serverError)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(PinnedActionBar(hardEdge: true) { saveBar })
            .onChange(of: serverError) { _, message in
                guard message != nil, isAccessibilitySize else { return }
                withAnimation(standardAnimation) {
                    proxy.scrollTo(Self.serverErrorAnchor, anchor: .bottom)
                }
            }
        }
        .moolaCanvas()
        .navigationTitle("Change password")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSaving)
        .sensoryFeedback(.warning, trigger: validationFailures)
        .sensoryFeedback(.error, trigger: saveFailures)
        .task { await twoFactor.load() }
    }

    /// The server's refusal (12 above the button), "Save password", the
    /// reserved reason slot 8 below. At accessibility sizes only the button.
    private var saveBar: some View {
        VStack(spacing: 0) {
            if !isAccessibilitySize, let serverError {
                serverErrorLine(serverError)
                    .padding(.bottom, Spacing.space3)
                    .transition(.opacity)
            }
            MoolaButton("Save password", loadingTitle: "Saving\u{2026}", isLoading: isSaving) {
                save()
            }
            .disabled(needsCode == nil)
            .accessibilityHint(needsCode == nil ? disabledReason : "")
            .accessibilityIdentifier("account.changePassword.save")
            if !isAccessibilitySize {
                DisabledReasonLine(text: disabledReason, isShown: needsCode == nil)
                    .padding(.top, Spacing.space2)
            }
        }
        .animation(standardAnimation, value: serverError)
    }

    /// "Your password is incorrect." or another server message, verbatim
    /// (`footnote` `redText`), announced when it appears.
    private func serverErrorLine(_ message: String) -> some View {
        Text(message)
            .textStyle(.footnote)
            .foregroundStyle(Palette.redText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("account.changePassword.error")
            .onAppear { AccessibilityNotification.Announcement(message).post() }
    }

    private func save() {
        guard let needsCode, !isSaving else { return }
        currentPasswordError = nil
        codeError = nil
        newPasswordError = nil
        confirmError = nil
        serverError = nil

        var invalid = false
        if currentPassword.isEmpty {
            currentPasswordError = "Please confirm your password to continue."
            invalid = true
        }
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if needsCode, trimmedCode.isEmpty {
            codeError = "Please enter your two-factor code to continue."
            invalid = true
        }
        if !Validation.isValidPassword(newPassword) {
            newPasswordError = "Password must be at least 8 characters."
            invalid = true
        } else if newPassword != confirmPassword {
            confirmError = "Passwords don't match."
            invalid = true
        }
        guard !invalid else {
            validationFailures += 1
            return
        }

        let input = ChangePasswordInput(
            currentPassword: Secret(currentPassword),
            twoFactorCode: needsCode ? Secret(trimmedCode) : nil,
            newPassword: Secret(newPassword)
        )
        isSaving = true
        Task {
            defer { isSaving = false }
            do throws(APIError) {
                _ = try await services.api.send(API.Auth.changePassword(input))
                clearProof()
                newPassword = ""
                confirmPassword = ""
                flow.securityToast = "Password updated."
                dismiss()
            } catch {
                clearProof()
                guard error != .cancelled else { return }
                serverError = error.message(for: .action)
                saveFailures += 1
            }
        }
    }

    /// Never keep the current password or code after a request.
    private func clearProof() {
        currentPassword = ""
        code = ""
    }
}
