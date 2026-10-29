import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Profile (DESIGN.md v2 B5.3): edit the name and username; email and date
/// of birth are read-only. One save model: the pinned "Save changes" with its
/// reserved reason line.
struct ProfileView: View {
    let services: AppServices

    @State private var profile: RemoteResource<UserProfile>
    @State private var name = ""
    @State private var username = ""
    /// The server values the fields were last filled from; edits are
    /// anything that differs from these.
    @State private var baseline: Baseline?
    @State private var nameError: String?
    @State private var usernameError: String?
    @State private var usernameCheck: UsernameCheck = .idle
    @State private var bannerMessage: String?
    @State private var isSaving = false
    @State private var toast: String?
    @State private var validationFailures = 0
    @State private var saveFailures = 0
    @FocusState private var focus: Field?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Baseline: Equatable {
        var name: String
        var username: String
    }

    private enum Field: Hashable {
        case name, username
    }

    enum UsernameCheck: Equatable {
        case idle, checking, available, taken
    }

    static let usernameFormatError = "Username must be 3\u{2013}30 characters: letters, numbers or underscores."
    static let saveReason = "Change your name or username to save."
    private static let saveErrorAnchor = "account.profile.saveError"

    init(services: AppServices) {
        self.services = services
        let api = services.api
        _profile = State(initialValue: RemoteResource(cacheKey: .profile, cache: services.cache) {
            try await api.send(API.Profile.get())
        })
    }

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    private var standardAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    var body: some View {
        content
            .moolaCanvas()
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toast($toast)
            .sensoryFeedback(.warning, trigger: validationFailures)
            .sensoryFeedback(.error, trigger: saveFailures)
            .task { await profile.load() }
            .onChange(of: profile.value) { _, value in
                fill(from: value)
            }
            .task(id: username) { await checkUsername() }
    }

    @ViewBuilder
    private var content: some View {
        if case .failed(let error) = profile.phase {
            // Never loaded (B5.3): the error 24 pt below the bar, no pinned bar.
            ScrollView {
                ErrorState(
                    title: "We couldn't load your profile",
                    message: error.message(for: .screen),
                    isRetrying: profile.isLoading
                ) {
                    Task { await profile.refresh() }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
            }
        } else {
            form
        }
    }

    private var form: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    statusBlock
                    if let value = profile.value {
                        fields(value)
                    } else {
                        loadingFields
                    }
                    if isAccessibilitySize {
                        // A8.30: at accessibility sizes the bar keeps only its
                        // button; the banner and the reason follow the last field.
                        accessibilityBarExtras
                    }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, AccountLayout.pushedTop)
                .padding(.bottom, Spacing.space6)
                .animation(standardAnimation, value: bannerMessage)
            }
            .scrollDismissesKeyboard(.interactively)
            .modifier(PinnedActionBar(hardEdge: true, keyboardMargin: true) { saveBar })
            .onChange(of: bannerMessage) { _, message in
                guard message != nil, isAccessibilitySize else { return }
                withAnimation(standardAnimation) {
                    proxy.scrollTo(Self.saveErrorAnchor, anchor: .bottom)
                }
            }
            // The focused field stays whole above the pinned bar riding on the
            // keyboard, also when an error under a field or the bar's banner
            // changes the layout: centred in the room above the keyboard,
            // because on iOS 26.5 neither the system nor a plain `scrollTo`
            // counts the `safeAreaBar` (as `AuthScreen`).
            .task(id: FocusScroll(field: focus, layout: [nameError, usernameError, bannerMessage])) {
                guard let focus else { return }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                withAnimation(standardAnimation) { proxy.scrollTo(focus, anchor: .center) }
            }
        }
    }

    private struct FocusScroll: Hashable {
        let field: Field?
        let layout: [String?]
    }

    /// Refresh failed with data (A3.2 status block): banner, 8 pt, "Updated
    /// {N} min ago", then 24 pt to the first label. Only in that state: while
    /// a cached profile refreshes the fields show at once and nothing moves
    /// (B5.3 "Cached while refreshing").
    @ViewBuilder
    private var statusBlock: some View {
        if profile.value != nil, let refreshError = profile.error {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                ErrorBanner(refreshError.message(for: .screen)) {
                    Task { await profile.refresh() }
                }
                if let updated = profile.updatedText() {
                    Text(updated)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .padding(.bottom, AccountLayout.statusToContent)
        }
    }

    private func fields(_ value: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            MoolaTextField(
                "Full name",
                text: $name,
                error: nameError,
                contentType: .name,
                autocapitalization: .words
            )
            .focused($focus, equals: .name)
            .id(Field.name)
            .submitLabel(.next)
            .onSubmit { focus = .username }
            .onChange(of: name) { _, _ in
                nameError = nil
                bannerMessage = nil
            }

            MoolaTextField(
                "Username",
                text: $username,
                hint: "3\u{2013}30 letters, numbers or underscores",
                error: usernameError,
                leadingAdornment: "@",
                // The public handle, not a login name: no Passwords bar over
                // the keyboard (sign-in uses the email).
                contentType: .nickname,
                autocapitalization: .never,
                autocorrection: false,
                trailing: usernameCheck == .idle ? nil : AnyView(UsernameStatusLabel(check: usernameCheck))
            )
            .focused($focus, equals: .username)
            .id(Field.username)
            .submitLabel(.done)
            .onChange(of: username) { _, _ in
                usernameError = nil
                bannerMessage = nil
            }
            .padding(.top, Spacing.fieldToNextLabel)

            let isVerified = services.session.currentUser?.emailVerified == true
            ReadOnlyField(label: "Email", value: AccountEmail.breakable(value.email)) {
                if isVerified {
                    StatusPill("Verified", tone: .jade)
                }
            }
            // One element, "Email, demo@moolahub.test, Verified" (B5.3); the
            // address as it is, without the display-only break point.
            .accessibilityLabel(Self.emailAccessibilityLabel(value.email, isVerified: isVerified))
            .accessibilityIdentifier("account.profile.email")
            .padding(.top, Spacing.fieldToNextLabel)

            if let dateOfBirth = value.dateOfBirth.flatMap(APIDate.parseDay) {
                ReadOnlyField(label: "Date of birth", value: APIDate.formatUTCDay(dateOfBirth))
                    .accessibilityIdentifier("account.profile.dateOfBirth")
                    .padding(.top, Spacing.fieldToNextLabel)
            }
        }
    }

    static func emailAccessibilityLabel(_ email: String, isVerified: Bool) -> String {
        isVerified ? "Email, \(email), Verified" : "Email, \(email)"
    }

    /// Loading with no cache (B5.3): the labels and the hint at once, each
    /// value a 52 pt `fill` block at the field's radius; one element.
    private var loadingFields: some View {
        LoadingPlaceholder(label: "Loading your profile\u{2026}") {
            VStack(alignment: .leading, spacing: 0) {
                loadingField("Full name", hint: nil)
                loadingField("Username", hint: "3\u{2013}30 letters, numbers or underscores")
                    .padding(.top, Spacing.fieldToNextLabel)
                loadingField("Email", hint: nil)
                    .padding(.top, Spacing.fieldToNextLabel)
                loadingField("Date of birth", hint: nil)
                    .padding(.top, Spacing.fieldToNextLabel)
            }
        }
    }

    private func loadingField(_ label: String, hint: String?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            SkeletonBlock(height: Size.textFieldHeight, cornerRadius: Radius.control)
                .padding(.top, Spacing.labelToField)
            if let hint {
                Text(hint)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
        }
    }

    // MARK: Pinned bar (A8.30)

    private var canSave: Bool { profile.value != nil && hasChanges }

    /// ErrorBanner (12 above the button), "Save changes", the reserved reason
    /// slot 8 below. At accessibility sizes only the button.
    private var saveBar: some View {
        VStack(spacing: 0) {
            if !isAccessibilitySize, let bannerMessage {
                saveErrorBanner(bannerMessage)
                    .padding(.bottom, Spacing.space3)
                    .transition(.opacity)
            }
            MoolaButton("Save changes", loadingTitle: "Saving\u{2026}", isLoading: isSaving) {
                save()
            }
            .disabled(!canSave)
            .accessibilityHint(canSave ? "" : Self.saveReason)
            .accessibilityIdentifier("account.profile.save")
            if !isAccessibilitySize {
                DisabledReasonLine(text: Self.saveReason, isShown: !canSave)
                    .padding(.top, Spacing.space2)
            }
        }
        .animation(standardAnimation, value: bannerMessage)
    }

    @ViewBuilder
    private var accessibilityBarExtras: some View {
        if let bannerMessage {
            saveErrorBanner(bannerMessage)
                .id(Self.saveErrorAnchor)
                .padding(.top, Spacing.space6)
                .transition(.opacity)
        }
        if !canSave {
            Text(Self.saveReason)
                .textStyle(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space6)
        }
    }

    private func saveErrorBanner(_ message: String) -> some View {
        ErrorBanner(message)
            .accessibilityIdentifier("account.profile.error")
    }

    // MARK: State

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var hasChanges: Bool {
        guard let value = profile.value else { return false }
        return normalizedName != value.name || normalizedUsername != (value.username ?? "")
    }

    /// Fills the fields from the server, unless the user has edited them.
    private func fill(from value: UserProfile?) {
        guard let value else { return }
        let fresh = Baseline(name: value.name, username: value.username ?? "")
        let untouched = baseline.map { name == $0.name && username == $0.username } ?? true
        guard untouched else { return }
        name = fresh.name
        username = fresh.username
        baseline = fresh
    }

    private func setUsernameCheck(_ check: UsernameCheck) {
        guard usernameCheck != check else { return }
        withAnimation(standardAnimation) { usernameCheck = check }
    }

    private func checkUsername() async {
        let candidate = normalizedUsername
        guard let value = profile.value, candidate != (value.username ?? ""), Validation.isValidUsername(candidate) else {
            setUsernameCheck(.idle)
            return
        }
        setUsernameCheck(.idle)
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        setUsernameCheck(.checking)
        do {
            let result = try await services.session.isUsernameAvailable(candidate)
            guard !Task.isCancelled else { return }
            setUsernameCheck(result.available ? .available : .taken)
        } catch {
            // The server checks again on save; say nothing rather than guess.
            if !Task.isCancelled { setUsernameCheck(.idle) }
        }
    }

    private func save() {
        guard let value = profile.value, !isSaving else { return }
        bannerMessage = nil
        nameError = nil
        usernameError = nil

        let newName = normalizedName
        let newUsername = normalizedUsername
        let currentUsername = value.username ?? ""
        var invalid = false
        if newName.isEmpty {
            nameError = "Name cannot be empty."
            invalid = true
        }
        if newUsername != currentUsername, !Validation.isValidUsername(newUsername) {
            usernameError = Self.usernameFormatError
            invalid = true
        }
        guard !invalid else {
            validationFailures += 1
            return
        }

        let update = ProfileUpdate(
            name: newName != value.name ? newName : nil,
            username: newUsername != currentUsername ? newUsername : nil
        )
        isSaving = true
        Task {
            defer { isSaving = false }
            do throws(APIError) {
                let updated = try await services.api.send(API.Profile.update(update))
                baseline = Baseline(name: updated.name, username: updated.username ?? "")
                name = updated.name
                username = updated.username ?? ""
                profile.replace(with: updated)
                await services.cache.save(updated, for: .profile)
                usernameCheck = .idle
                toast = "Saved."
                // The Account header and the rest of the app read the session user.
                await services.session.refreshUser()
            } catch {
                guard error != .cancelled else { return }
                bannerMessage = error.message(for: .action)
                saveFailures += 1
            }
        }
    }
}

/// The username field's trailing status (A8.26): "Checking…" in
/// `textSecondary`; `checkmark` + "Available" in `jadeText`; `xmark` +
/// "Taken" in `redText`; `subheadline`. One element the tests read
/// (`account.profile.usernameStatus`); it stays at the field's trailing edge.
private struct UsernameStatusLabel: View {
    let check: ProfileView.UsernameCheck
    @ScaledMetric(relativeTo: .footnote) private var symbolSize: CGFloat = 12

    private var parts: (text: String, symbol: String?, color: Color) {
        switch check {
        case .idle, .checking: ("Checking\u{2026}", nil, Palette.textSecondary)
        case .available: ("Available", "checkmark", Palette.jadeText)
        case .taken: ("Taken", "xmark", Palette.redText)
        }
    }

    var body: some View {
        let parts = parts
        HStack(spacing: Spacing.space1) {
            if let symbol = parts.symbol {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .medium))
                    .accessibilityHidden(true)
            }
            Text(parts.text)
                .textStyle(.subheadline)
                .lineLimit(1)
                .fixedSize()
        }
        .foregroundStyle(parts.color)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.profile.usernameStatus")
    }
}
