import APIClient
import Auth
import Combine
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Home tab root (DESIGN.md v2 B2.1). AppFeature places it inside the Home
/// tab's `NavigationStack`. Keep this type name and initializer: AppFeature
/// calls it.
///
/// Top to bottom: the greeting band (`GreetingHeader`, filling the status bar),
/// the total balance as type with its two action tiles and the "Cash out" /
/// "History" links (`BalanceCard`), the disclosure footer, then "Your goals",
/// "Your groups" and "Recent activity". Everything shown comes from
/// `GET /dashboard/summary` (cached snapshot first, then live) and the
/// signed-in user. Nothing is ever shown as `$0.00` in place of data that
/// didn't load: the first load is a skeleton, a failure with nothing to show is
/// one error block with one "Try again", and a failed refresh keeps the last
/// figures under an error banner.
public struct HomeRootView: View {
    private let services: AppServices
    @State private var summary: RemoteResource<DashboardSummary>
    /// The disclosure footer's text height. Its 44 pt hit region centres the
    /// text, and "Your goals" sits `sectionGap` below the text, not the region.
    @State private var footerTextHeight: CGFloat = 15.3

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(services: AppServices) {
        self.services = services
        let api = services.api
        _summary = State(initialValue: RemoteResource(cacheKey: .dashboard, cache: services.cache) {
            try await api.send(API.Dashboard.summary())
        })
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GreetingHeader(greeting, detail: freshnessText, identifier: "home.greeting")
                content
                    // Everything below the band paints its own ground, so the
                    // band-coloured backdrop never shows through it.
                    .background(Palette.canvas)
            }
            // The banner and the freshness line fade in while the layout
            // makes room (A5.9).
            .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: statusLines)
        }
        .accessibilityIdentifier("home.scroll")
        .refreshable { await summary.refresh() }
        .modifier(GreetingHeaderChrome())
        .task { await summary.load() }
        .onReceive(NotificationCenter.default.publisher(for: AppSignals.moneyMoved)) { _ in
            refresh()
        }
        // App-level sheets owned by other features (Move to goal, Create goal,
        // the Activity receipt) open over Home without Home disappearing:
        // refresh when one closes.
        .onChange(of: services.navigator.appSheetDismissals) { _, _ in
            refresh()
        }
    }

    // MARK: Layout

    private var greeting: String {
        let firstName = services.session.currentUser?.firstName ?? ""
        return firstName.isEmpty ? "Good to see you" : "Good to see you, \(firstName)"
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if let message = refreshFailureMessage {
                    ErrorBanner(message) { refresh() }
                        .padding(.top, Spacing.space4)
                        .transition(.opacity)
                }
                BalanceCard(state: balanceState, actions: balanceActions)
                    .padding(.top, Spacing.space5)
                DisclosureFooter()
                    .background { footerTextMeasure }
            }
            .padding(.horizontal, Spacing.screenGutter)

            sections
            // End of content.
            Color.clear
                .frame(height: Spacing.space8)
                .accessibilityHidden(true)
        }
    }

    /// The footer's text laid out exactly as `DisclosureFooter` lays it out,
    /// hidden, only to read its height.
    private var footerTextMeasure: some View {
        Text("\(Disclosure.footer) \(Image(systemName: "info.circle"))")
            .textStyle(.footnote)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
                footerTextHeight = height
            }
    }

    /// `sectionGap` from the footer's text frame to the "Your goals" heading.
    private var goalsHeadingGap: CGFloat {
        Spacing.sectionGap - max(0, (Size.minimumTapTarget - footerTextHeight) / 2)
    }

    // MARK: Balance

    private var balanceState: BalanceCard.State {
        if let value = summary.value {
            return .loaded(BalanceCard.Figures(value))
        }
        if let error = summary.error, error != .sessionExpired, error != .cancelled {
            // Never loaded (C3): one block, one retry, no figures.
            return .loadFailed(message: error.message(for: .screen), isRetrying: summary.isLoading, retry: { refresh() })
        }
        return .loading
    }

    private var balanceActions: BalanceCard.Actions {
        let navigator = services.navigator
        return BalanceCard.Actions(
            addMoney: { navigator.present(AddMoneyRoute.sheet(isDebugBuild: AddMoneyRoute.isDebugBuild, faucetEnabled: nil).appSheet) },
            moveToGoal: { navigator.present(.moveToGoal(goalID: nil)) },
            cashOut: { navigator.present(.cashOut) },
            history: { navigator.select(.activity) }
        )
    }

    // MARK: Sections

    @ViewBuilder
    private var sections: some View {
        if let value = summary.value {
            loadedSections(value)
                .padding(.top, goalsHeadingGap)
        } else if summary.error == nil {
            // First load with no cached snapshot (C2).
            HomeSectionsSkeleton()
                .padding(.top, goalsHeadingGap)
        }
        // Nothing loaded and the load failed (C3): no sections; the balance
        // block carries the error and the only "Try again".
    }

    private func loadedSections(_ value: DashboardSummary) -> some View {
        let navigator = services.navigator
        return VStack(alignment: .leading, spacing: 0) {
            HomeGoalsSection(
                goals: value.activeGoals,
                balanceUnavailable: value.balanceUnavailable == true,
                seeAll: { navigator.select(.savings) },
                open: { navigator.open(.goalDetail(id: $0)) },
                createGoal: { navigator.present(.createGoal) }
            )
            if !value.activeCircles.isEmpty {
                HomeGroupsSection(
                    groups: value.activeCircles,
                    seeAll: { navigator.select(.groups) },
                    open: { navigator.open(.groupDetail(id: $0)) }
                )
                .padding(.top, gapAfterGoals(value))
            }
            HomeRecentActivitySection(
                items: value.recentActivity,
                seeAll: { navigator.select(.activity) },
                openReceipt: { navigator.present(.activityReceipt($0)) }
            )
            .padding(.top, value.activeCircles.isEmpty ? gapAfterGoals(value) : Spacing.sectionGap)
        }
    }

    /// `sectionGap` after the goals. Goal rows end in their own 16.7 pt
    /// bottom padding, so the gap from the last row's frame is that much less
    /// and every Home section break measures the same (A3.2's
    /// `headingToContent` rule at the bottom of a list; 57 pt to the next
    /// heading's cap, as after the footer and the group card).
    private func gapAfterGoals(_ value: DashboardSummary) -> CGFloat {
        value.activeGoals.isEmpty ? Spacing.sectionGap : Spacing.sectionGap - Size.goalRowBottomPadding
    }

    // MARK: Refresh

    /// Shown 16 pt under the band when a refresh failed but data is still on screen (C4).
    private var refreshFailureMessage: String? {
        guard summary.value != nil, let error = summary.error,
              error != .sessionExpired, error != .cancelled
        else { return nil }
        return error.message(for: .screen)
    }

    /// The band's second line: "Updated …" while Home shows the cached
    /// snapshot, and while it keeps figures a refresh failed to replace (C4).
    private var freshnessText: String? {
        if let cached = summary.updatedText() { return cached }
        guard refreshFailureMessage != nil, let updatedAt = summary.updatedAt else { return nil }
        return SnapshotAge.text(savedAt: updatedAt)
    }

    /// Whether the banner and the freshness line show, to animate their arrival.
    private var statusLines: [Bool] {
        [refreshFailureMessage != nil, freshnessText != nil]
    }

    private func refresh() {
        Task { await summary.refresh() }
    }
}
