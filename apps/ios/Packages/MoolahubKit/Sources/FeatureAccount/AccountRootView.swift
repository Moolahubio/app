import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Account tab root (DESIGN.md v2 B5.1, account.md B5.1 amended): the
/// identity block, then one flat list of settings rows on the page, groups
/// split by dividers: Profile, Security, Notifications, Streak frequency;
/// Learn, Technical details, About and legal; (Debug) Developer settings;
/// Deactivate account (B5.14 dialog, then the step-up sheet) and Delete
/// account (B5.16); Sign out last.
/// Placed inside the Account tab's `NavigationStack`. Keep this name and
/// initializer.
public struct AccountRootView: View {
    private let services: AppServices
    @State private var flow = AccountFlowState()
    @State private var confirmsSignOut = false
    @State private var isSigningOut = false
    @State private var confirmsDeactivate = false
    /// The Deactivate dialog's choice, presented once the dialog has gone:
    /// a sheet presented in the dialog's own dismissal can be dropped (B5.14).
    @State private var pendingStepUp: AccountStepUpAction?
    @State private var sheet: AccountSheet?
    /// The last pull-to-refresh failure (B5.1 "Refresh failed with data").
    @State private var refreshError: APIError?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(services: AppServices) {
        self.services = services
    }

    private var swapAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let refreshError {
                    ErrorBanner(refreshError.message(for: .screen)) {
                        Task { await refresh() }
                    }
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.bottom, AccountLayout.statusToContent)
                    .transition(.opacity)
                }

                if let user = services.session.currentUser {
                    AccountHeader(user: user)
                } else {
                    AccountHeaderSkeleton()
                }

                navigationRow(AccountRoute.profile, symbol: "person.text.rectangle", title: "Profile", id: "profile")
                    .padding(.top, Spacing.space6)
                navigationRow(AccountRoute.security, symbol: "lock.shield", title: "Security", id: "security")
                navigationRow(AccountRoute.notifications, symbol: "bell", title: "Notifications", id: "notifications")
                // The person's frequency only when Home already loaded the
                // streak (no read here, no placeholder; account.md B5.1).
                navigationRow(
                    AppDestination.streakFrequency,
                    symbol: "flame",
                    title: "Streak frequency",
                    value: streakFrequencyName,
                    id: "streakFrequency"
                )

                SettingsGroupDivider()

                navigationRow(AppDestination.learn, symbol: "book.closed", title: "Learn", id: "learn")
                navigationRow(
                    AccountRoute.technicalDetails,
                    symbol: "wrench.and.screwdriver",
                    title: "Technical details",
                    value: services.settings.showTechnicalDetails ? "On" : "Off",
                    id: "technicalDetails"
                )
                navigationRow(AccountRoute.about, symbol: "doc.text", title: "About and legal", id: "about")

                #if DEBUG
                SettingsGroupDivider()
                // Opens an app sheet; the chevron stays as the "opens" cue (B5.1).
                SettingsRow(symbol: "hammer", title: "Developer settings") {
                    services.navigator.present(.developerSettings)
                }
                .accessibilityIdentifier("account.row.developerSettings")
                #endif

                SettingsGroupDivider()

                // Opens a dialog, like Sign out: no chevron (D-41).
                SettingsRow(symbol: "pause.circle", title: "Deactivate account", showsChevron: false) {
                    confirmsDeactivate = true
                }
                .disabled(isSigningOut)
                .accessibilityIdentifier("account.deactivate")
                // Attached to the row so the iOS 26 popover points at it (A9.4).
                .confirmationDialog("Deactivate your account?", isPresented: $confirmsDeactivate, titleVisibility: .visible) {
                    Button("Deactivate account", role: .destructive) {
                        pendingStepUp = .deactivate
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You'll be signed out on all your devices. Signing in again turns it back on.")
                }
                // Opens a screen: a navigation row, not red (D-13).
                navigationRow(AccountRoute.deleteAccount, symbol: "trash", title: "Delete account", id: "deleteAccount")
                    .disabled(isSigningOut)

                SettingsGroupDivider()

                SettingsRow(
                    symbol: "rectangle.portrait.and.arrow.right",
                    title: isSigningOut ? "Signing out\u{2026}" : "Sign out",
                    tone: .destructive
                ) {
                    confirmsSignOut = true
                }
                .contentTransition(.opacity)
                .animation(swapAnimation, value: isSigningOut)
                .disabled(isSigningOut)
                .accessibilityIdentifier("account.signOut")
                // Attached to the row so the iOS 26 popover points at "Sign out" (A9.4).
                .confirmationDialog("Sign out of MoolaHub?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) {
                        signOut()
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(.top, AccountLayout.rootTop)
            .padding(.bottom, Spacing.space8)
            .animation(swapAnimation, value: refreshError)
        }
        .moolaCanvas()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.large)
        .navigationDestination(for: AccountRoute.self) { route in
            destination(route)
        }
        .refreshable { await refresh() }
        .onChange(of: confirmsDeactivate) { _, isShown in
            guard !isShown, let action = pendingStepUp else { return }
            pendingStepUp = nil
            sheet = .stepUp(action)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .stepUp(let action):
                AccountStepUpSheet(services: services, action: action)
            }
        }
    }

    /// "Daily", "Weekly" or "Monthly" when the shared streak store holds an
    /// overview with a known frequency; nil otherwise (D-38).
    private var streakFrequencyName: String? {
        services.streaks.overview.value.flatMap { StreakWords.frequencyName($0.frequency) }
    }

    // MARK: Rows and destinations

    /// A navigation row (A8.21): symbol at x 16, title at x 52, optional value,
    /// chevron. One button whose label is the title plus the value (the tests
    /// read "Off" inside the Technical details row). `route` is an
    /// `AccountRoute` or an `AppDestination` (Learn, Streak frequency), which
    /// AppFeature registers on every tab's stack.
    private func navigationRow(
        _ route: some Hashable,
        symbol: String,
        title: String,
        value: String? = nil,
        id: String
    ) -> some View {
        NavigationLink(value: route) {
            SettingsRowLabel(symbol: symbol, title: title, value: value)
                .contentTransition(.opacity)
                .animation(swapAnimation, value: value)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityIdentifier("account.row.\(id)")
    }

    @ViewBuilder
    private func destination(_ route: AccountRoute) -> some View {
        switch route {
        case .profile:
            ProfileView(services: services)
        case .security:
            SecurityView(services: services, flow: flow)
        case .changePassword:
            ChangePasswordView(services: services, flow: flow)
        case .notifications:
            NotificationSettingsView(services: services)
        case .technicalDetails:
            TechnicalDetailsView(services: services)
        case .about:
            AboutView(services: services)
        case .disclosure(let disclosure):
            DisclosureDetailView(disclosure: disclosure)
        case .deleteAccount:
            DeleteAccountView(services: services)
        }
    }

    // MARK: Refresh and sign out

    /// Pull to refresh (A5.8): the shown user stays; a failure shows the
    /// banner at the top. No "Updated … ago" line: the session user carries no
    /// timestamp, and the screen never invents one (B5.1).
    private func refresh() async {
        let error = await services.session.refreshUser()
        refreshError = error
    }

    /// Sign out (B5.2): server logout (best effort), Keychain token deleted,
    /// cached data cleared, back to Welcome. Device settings stay.
    /// `SessionStore` does all of it; the root swaps to the signed-out flow.
    private func signOut() {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            await services.session.signOut()
            isSigningOut = false
        }
    }
}

/// The identity block (B5.1): a 64 pt initials avatar, then the name
/// (`title3`), "@username" and the email (`subheadline` `textSecondary`), all
/// on the 16 pt gutter. One accessibility element, "Ama Owusu, @ama, demo@…".
private struct AccountHeader: View {
    let user: AuthUser
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Fixed 64 pt at every size, initials capped at .large, hidden
            // from VoiceOver: the name below says who it is (A8.13, ruling 38).
            AvatarView(name: AccountInitials.of(user.name), size: 64)
            Text(user.name)
                .textStyle(.title3)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space3)
            if let username = user.username, !username.isEmpty {
                Text(verbatim: "@\(username)")
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space1)
            }
            // At accessibility sizes the email wraps (B5.1). A zero-width space
            // after "@" lets it break there ("demo@" / "moolahub.test") rather
            // than mid-word; VoiceOver reads the address as it is.
            Text(verbatim: AccountEmail.breakable(user.email))
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.isAccessibilitySize)
                .accessibilityLabel(user.email)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenGutter)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.header")
    }
}

/// The identity block while the session user is missing (B5.1 "Loading"):
/// the same layout with a 64 pt circle and bars at each line's cap height
/// (`title3` 45 %, `subheadline` 20 % and 55 %). One element, "Loading your
/// profile…". The rows below are local and render at once.
private struct AccountHeaderSkeleton: View {
    var body: some View {
        LoadingPlaceholder(label: "Loading your profile\u{2026}") {
            VStack(alignment: .leading, spacing: 0) {
                SkeletonBlock(width: 64, height: 64, cornerRadius: 32)
                SkeletonTextLine(.title3, leading: 0.45)
                    .padding(.top, Spacing.space3)
                SkeletonTextLine(.subheadline, leading: 0.2)
                    .padding(.top, Spacing.space1)
                SkeletonTextLine(.subheadline, leading: 0.55)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenGutter)
        }
    }
}
