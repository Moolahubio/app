import APIClient
import Auth
import DesignSystem
import Domain
import FeatureAccount
import FeatureActivity
import FeatureAuth
import FeatureCircles
import FeatureHome
import FeatureLearn
import FeatureSavings
import FeatureStreaks
import SwiftUI

/// The app's root: session gate → signed-out flow or the five tabs, and the
/// app-level sheets. The app lock and the privacy cover are drawn above all
/// of it, sheets included, by `SecurityOverlayWindow`, which also tells
/// `AppLock` when the scene leaves and returns. It is also the only presenter
/// of the New badge sheet (D-23), resets the shared stores when the user
/// changes (D-24) and fires the time zone sync's triggers (SPEC §4.5).
public struct AppRootView: View {
    private let composition: AppComposition
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAppLockOffer = false

    public init(composition: AppComposition) {
        self.composition = composition
    }

    private var services: AppServices { composition.services }

    public var body: some View {
        ZStack {
            ZStack {
                content
            }
            // Root gate swaps cross-fade; nothing moves or scales (ruling 20, A5.4).
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: rootKey)
            if isLocked {
                // A backstop under the lock window: the tabs never show for a
                // frame before the window is up (a locked cold launch). It is
                // the privacy cover's picture, so nothing changes when the
                // window's lock screen arrives over it.
                PrivacyCover()
                    .allowsHitTesting(false)
                    .transition(RootTransition.lockOverlay)
                    .zIndex(1)
            }
        }
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: isLocked)
        // The lock screen and the privacy cover are drawn in their own window
        // above every sheet (`SecurityOverlayWindow`, B1.2, B1.3).
        .background {
            SceneWindowReader { [services] window in
                guard let scene = window.windowScene else { return }
                SecurityOverlayWindow.shared.install(on: scene, appWindow: window, services: services)
            }
            .accessibilityHidden(true)
        }
        .environment(services)
        .environment(services.session)
        .environment(services.settings)
        .environment(composition.router)
        .sheet(item: sheetBinding, onDismiss: { composition.router.appSheetDidDismiss() }) { sheet in
            composition.router.sheetView(for: sheet)
        }
        .sheet(isPresented: $showsAppLockOffer, onDismiss: { services.session.acknowledgeSignIn() }) {
            AppLockOfferSheet(services: services)
        }
        .task {
            services.appLock.lockOnLaunchIfEnabled()
            await services.session.restore()
        }
        .onChange(of: services.session.state) { old, new in
            handleSessionChange(from: old, to: new)
            // In the same update: a locked session shows its lock at once.
            SecurityOverlayWindow.shared.refresh()
        }
        .onChange(of: scenePhase, initial: true) { old, new in
            services.timeZoneSync.isSceneActive = new == .active
            // Time zone trigger 1: the scene becomes active while signed in.
            if new == .active, old != .active, services.session.isSignedIn {
                Task { await services.timeZoneSync.sync() }
            }
        }
        // The sheet went away some other way than its own binding (a router
        // reset or replacement): it was seen all the same (ST.9).
        .onChange(of: composition.router.sheet) { old, _ in
            if case .newStreakBadge = old { services.streaks.markBadgesSeen() }
        }
        .onChange(of: badgeToCelebrate) { _, _ in
            // After this update's other changes (a sheet that just closed
            // marks its badge seen first), so a badge is never shown twice.
            Task { @MainActor in presentPendingBadge() }
        }
        .onOpenURL { url in
            if services.session.isSignedIn { composition.router.handle(url) }
        }
    }

    private var isLocked: Bool {
        services.session.isSignedIn && services.appLock.isLocked
    }

    /// The app-level sheet. Swiping the New badge sheet down marks its badge
    /// seen, as its "Done" does (ST.9).
    private var sheetBinding: Binding<AppSheet?> {
        let router = composition.router
        let streaks = services.streaks
        return Binding(
            get: { router.sheet },
            set: { sheet in
                if sheet == nil, case .newStreakBadge = router.sheet { streaks.markBadgesSeen() }
                router.sheet = sheet
            }
        )
    }

    /// The badge the New badge sheet may show now (D-23, ST.9): a pending
    /// badge, Home's root or the Streak screen visible with nothing of its
    /// own presented, no app-level sheet, no app lock offer, no lock, and the
    /// app active. Nil otherwise; re-checked whenever any of these changes.
    private var badgeToCelebrate: StreakBadge? {
        guard let badge = services.streaks.pendingBadge,
              !services.streaks.celebrationHosts.isEmpty,
              composition.router.sheet == nil,
              !showsAppLockOffer,
              !isLocked,
              scenePhase == .active
        else { return nil }
        return badge
    }

    private func presentPendingBadge() {
        guard let badge = badgeToCelebrate else { return }
        composition.router.present(.newStreakBadge(badge))
    }

    /// Which root is showing; a change cross-fades.
    private var rootKey: String {
        guard ServerEnvironment.isAllowed(ServerEnvironment.defaultBaseURL) else { return "notConfigured" }
        switch services.session.state {
        case .restoring: return "launch"
        case .signedOut: return "signedOut-\(String(describing: services.session.signedOutReason))"
        case .signedIn: return "tabs"
        case .restoreFailed: return "restoreFailed"
        }
    }

    @ViewBuilder
    private var content: some View {
        if !ServerEnvironment.isAllowed(ServerEnvironment.defaultBaseURL) {
            // Release builds until a real API domain is configured.
            NotConfiguredView()
                .transition(RootTransition.crossFade)
        } else {
            switch services.session.state {
            case .restoring:
                // Nothing on it is tappable; while it fades out over Welcome,
                // a tap must reach Welcome, not land on the fading mark.
                LaunchView()
                    .allowsHitTesting(false)
                    .transition(RootTransition.crossFade)
            case .signedOut:
                AuthFlowView(services: services)
                    .id(services.session.signedOutReason)
                    .transition(RootTransition.crossFade)
            case .signedIn:
                MainTabView(services: services, router: composition.router)
                    .transition(RootTransition.crossFade)
            case .restoreFailed(let error):
                RestoreFailedView(services: services, error: error)
                    .transition(RootTransition.crossFade)
            }
        }
    }

    private func handleSessionChange(from old: SessionState, to new: SessionState) {
        switch new {
        case .signedOut(let reason):
            // A sign-out while the New badge sheet is up: it was seen (ST.9).
            // Not after a deletion, which removed this user's keys.
            if case .newStreakBadge = composition.router.sheet, reason != .accountDeleted {
                services.streaks.markBadgesSeen()
            }
            services.streaks.reset()
            composition.router.reset()
            services.appLock.reset()
            showsAppLockOffer = false
        case .signedIn(let user):
            // One user's streak at a time (D-24).
            if let owner = services.streaks.ownerUserID, owner != user.id {
                services.streaks.reset()
            }
            if case .signedIn = old { return }
            // Time zone trigger 2: the session enters `.signedIn` (a sign-in or a restore).
            Task { await services.timeZoneSync.sync() }
            if services.session.didJustSignIn {
                let biometry = services.authenticator.biometryKind()
                if !services.settings.appLockOffered && !services.settings.appLockEnabled && biometry.isAvailable {
                    showsAppLockOffer = true
                } else {
                    services.session.acknowledgeSignIn()
                }
            }
        case .restoring, .restoreFailed:
            break
        }
    }
}

/// The five tabs, each with its own `NavigationStack` (DESIGN.md v2 A4.2,
/// B1.5): the system `TabView` (Liquid Glass on iOS 26, the bar material on
/// 17/18). Jade on the `TabView` marks the selected tab, the one jade item in
/// the chrome; each tab's stack restores the ink tint for its content and
/// toolbar items. The bar never minimizes; re-tapping a tab pops it to root.
struct MainTabView: View {
    let services: AppServices
    @Bindable var router: Router

    var body: some View {
        TabView(selection: Binding(get: { router.selectedTab }, set: { router.tabTapped($0) })) {
            ForEach(AppTab.allCases) { tab in
                NavigationStack(path: Binding(get: { router.path(for: tab) }, set: { router.setPath($0, for: tab) })) {
                    root(for: tab)
                        .navigationDestination(for: AppDestination.self) { destination in
                            destinationView(destination)
                        }
                }
                .tint(Palette.ctaBackground)
                .tabItem { Label(tab.title, systemImage: tab.symbolName) }
                .tag(tab)
            }
        }
        .tint(Palette.jadeText)
        .modifier(TabBarNeverMinimizes())
    }

    @ViewBuilder
    private func root(for tab: AppTab) -> some View {
        switch tab {
        case .home: HomeRootView(services: services)
        case .savings: SavingsRootView(services: services)
        case .groups: GroupsRootView(services: services)
        case .activity: ActivityRootView(services: services)
        case .account: AccountRootView(services: services)
        }
    }

    @ViewBuilder
    private func destinationView(_ destination: AppDestination) -> some View {
        switch destination {
        case .goalDetail(let id): GoalDetailView(services: services, goalID: id)
        case .groupDetail(let id): GroupDetailView(services: services, groupID: id)
        case .groupPayIn(let id): GroupDetailView(services: services, groupID: id, opensPayIn: true)
        case .streak: StreakScreen(services: services)
        case .streakFrequency: StreakFrequencyScreen(services: services)
        case .learn: LearnListView(services: services)
        case .lesson(let slug): LessonView(services: services, slug: slug)
        }
    }
}

/// Root swaps cross-fade (ruling 20). The outgoing tree leaves the
/// accessibility tree at once, so a test never finds two roots at the same
/// time; the incoming one is reachable immediately.
enum RootTransition {
    static var crossFade: AnyTransition {
        .asymmetric(insertion: .opacity, removal: fadeOut)
    }

    /// The lock overlay is in place in the frame it is needed: when the app
    /// relocks on returning from the background, the privacy cover leaves at
    /// once, and a fade-in would show the money behind the lock for a moment
    /// (B1.2). Its ground and 72 pt mark are the privacy cover's and the
    /// launch screen's, so the visible change is only the title and buttons
    /// appearing (A9.11). Unlocking fades it out with `Motion.standard` (B1.3).
    static var lockOverlay: AnyTransition {
        .asymmetric(insertion: .identity, removal: fadeOut)
    }

    private static var fadeOut: AnyTransition {
        AnyTransition.opacity.combined(
            with: .modifier(active: AccessibilityGone(isGone: true), identity: AccessibilityGone(isGone: false))
        )
    }
}

struct AccessibilityGone: ViewModifier {
    let isGone: Bool

    func body(content: Content) -> some View {
        content.accessibilityHidden(isGone)
    }
}

/// Launch (B1.1): the 72 pt mark centred in the safe area on `canvas`, the
/// same size and centre as the system launch image, so the hand-off is
/// invisible. No text, no spinner.
struct LaunchView: View {
    var body: some View {
        VStack {
            MoolaMark(size: 72)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .moolaCanvas()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading MoolaHub")
    }
}

/// Privacy cover (B1.2): opaque `canvas` and the 72 pt mark at the launch
/// position, never a blur (a blur can leak content), never animated.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Palette.canvas.ignoresSafeArea()
            MoolaMark(size: 72)
        }
        .accessibilityHidden(true)
    }
}

/// The wordmark on the navigation-bar row of a screen without a bar (B1.7, B1.8).
private struct WordmarkRow: View {
    var body: some View {
        Wordmark(height: 36)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

/// Restore failed (B1.7): a token exists but the session couldn't be checked
/// and nothing is cached. The wordmark on the bar row, then the ErrorState 24
/// pt below it: "We couldn't open MoolaHub", the W6 message, "Try again".
struct RestoreFailedView: View {
    let services: AppServices
    let error: APIError
    @State private var isRetrying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WordmarkRow()
                ErrorState(
                    title: "We couldn't open MoolaHub",
                    message: error.message(for: .screen),
                    isRetrying: isRetrying
                ) {
                    isRetrying = true
                    Task {
                        await services.session.retryRestore()
                        isRetrying = false
                    }
                }
                .padding(.top, Spacing.space6)
                #if DEBUG
                TextLinkButton("Developer settings") {
                    services.navigator.present(.developerSettings)
                }
                .padding(.top, Spacing.space3)
                #endif
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.bottom, Spacing.space8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .moolaCanvas()
    }
}

/// Not configured (B1.8): Release builds refuse to run against the
/// placeholder API URL. The wordmark row, then the empty state, no button
/// and no symbol.
struct NotConfiguredView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                WordmarkRow()
                EmptyState(
                    title: "This build isn't set up yet",
                    message: APIError.Copy.misconfigured
                )
                .padding(.top, Spacing.space6)
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.bottom, Spacing.space8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .moolaCanvas()
    }
}
