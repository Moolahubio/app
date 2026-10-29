import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Savings list (DESIGN.md v2 B3.2 to B3.7): the "In goals" total as type on
/// the page, "Your goals" as a 2-column grid of goal tiles, the one-line
/// explanation; loading, empty, error and cached-with-a-failed-refresh
/// states; the "Goal deleted." toast. Pull to refresh.
struct SavingsListScreen: View {
    let services: AppServices
    @State private var goals: RemoteResource<[Goal]>
    @State private var toast: String?
    /// The latest `SavingsEvents.revision` this list has refetched for. The
    /// "Goal deleted." toast waits for it, so it never shows over a list that
    /// still holds the deleted goal (B3.7: the toast is over the list, "which
    /// no longer shows the goal").
    @State private var refreshedRevision: Int?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var events: SavingsEvents { SavingsEvents.shared }

    init(services: AppServices) {
        self.services = services
        let api = services.api
        _goals = State(initialValue: RemoteResource(cacheKey: .goals, cache: services.cache) {
            try await savingsRead { try await api.send(API.Goals.list()) }
        })
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.bottom, Spacing.space8)
                .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: goals.error)
        }
        .moolaCanvas()
        .navigationTitle("Savings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create goal", systemImage: "plus") {
                    services.navigator.present(.createGoal)
                }
                .accessibilityIdentifier("savings.createGoal")
            }
        }
        .refreshable { await goals.refresh() }
        .task {
            let revision = events.revision
            await goals.load()
            markRefreshed(revision)
        }
        .onChange(of: events.revision) { _, revision in
            Task {
                await goals.refresh()
                markRefreshed(revision)
            }
        }
        .onAppear { takeToast() }
        .onChange(of: events.pendingToast) { _, _ in takeToast() }
        .onChange(of: goals.value != nil) { _, _ in takeToast() }
        .toast($toast)
    }

    /// A refetch for `revision` finished (it may have failed: the list then
    /// shows its banner, and the toast still comes).
    private func markRefreshed(_ revision: Int) {
        refreshedRevision = max(refreshedRevision ?? revision, revision)
        takeToast()
    }

    /// Shows a queued toast ("Goal deleted.", B3.7, B3.28) once the list is
    /// on screen and has refetched since the last change, so the deleted
    /// goal is already gone from it.
    private func takeToast() {
        guard goals.value != nil, refreshedRevision == events.revision else { return }
        if let message = events.takeToast(for: .savingsList) { toast = message }
    }

    @ViewBuilder
    private var content: some View {
        if let list = goals.value {
            loaded(list)
        } else if let error = goals.error {
            // B3.5: 24 pt below the content origin; no "$" anywhere. The
            // state stays while "Try again" (or a pull) retries: the button
            // says "Trying again…" until the result.
            ErrorState(title: "We couldn't load your goals", message: error.message(for: .screen), isRetrying: goals.isLoading) {
                Task { await goals.refresh() }
            }
            .padding(.top, Spacing.space6)
        } else {
            loadingSkeleton
        }
    }

    /// The status block (A3.2, ruling 11): the ErrorBanner when a refresh
    /// failed, 8 pt, "Updated {N} min ago" when the list is a cached snapshot.
    private var hasStatusBlock: Bool {
        goals.error != nil || goals.updatedText() != nil
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if let error = goals.error {
                ErrorBanner(error.message(for: .screen)) {
                    Task { await goals.refresh() }
                }
                .transition(.opacity)
            }
            if let updated = goals.updatedText() {
                Text(updated)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Content starts 8 pt below the large-title bar (A3.2); after a status
    /// block the first content sits 24 pt below it. The empty state sits
    /// 24 pt below the content origin (B3.4).
    private func loaded(_ list: [Goal]) -> some View {
        let status = hasStatusBlock
        return VStack(alignment: .leading, spacing: 0) {
            if status {
                statusBlock
                    .padding(.top, Spacing.space2)
            }
            if list.isEmpty {
                EmptyState(
                    title: "No goals yet",
                    message: "Set a target and a date. We'll track your progress.",
                    actionTitle: "Create goal"
                ) {
                    services.navigator.present(.createGoal)
                }
                .padding(.top, Spacing.space6)
            } else {
                SavingsSummary(goals: list)
                    .padding(.top, status ? Spacing.space6 : Spacing.space2)
                SectionHeader("Your goals")
                    .padding(.top, Spacing.sectionGap)
                grid(list)
                    .padding(.top, Spacing.headingToContent)
                Text("Each goal is a pot inside your balance, not a separate account.")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space6)
            }
        }
    }

    /// 2 columns (1 at accessibility sizes), `gridGap` 12 both ways, in API
    /// order; an odd last tile keeps its column (A3.3). A `Grid`, so both tiles
    /// of a row share its height.
    private func grid(_ list: [Goal]) -> some View {
        let columnCount = dynamicTypeSize.isAccessibilitySize ? 1 : 2
        let rows = stride(from: 0, to: list.count, by: columnCount).map { start in
            Array(list[start..<min(start + columnCount, list.count)])
        }
        let now = Date()
        return Grid(alignment: .topLeading, horizontalSpacing: Spacing.gridGap, verticalSpacing: Spacing.gridGap) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { goal in
                        NavigationLink(value: AppDestination.goalDetail(id: goal.id)) {
                            GoalCard(GoalCardModel(goal, now: now))
                        }
                        .buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))
                        .frame(maxHeight: .infinity)
                        .accessibilityIdentifier("savings.goalCard.\(goal.id)")
                    }
                    if row.count < columnCount {
                        Color.clear
                            .gridCellUnsizedAxes([.horizontal, .vertical])
                            .accessibilityHidden(true)
                    }
                }
            }
        }
    }

    /// B3.3: the final layout with the values as blocks; "In goals" and
    /// "Your goals" render at once; one element "Loading your goals…". Every
    /// line is reserved at its real height, so when the goals land nothing
    /// moves but a tile whose name or pace line wraps (A5.7).
    private var loadingSkeleton: some View {
        LoadingPlaceholder(label: SavingsCopy.loadingGoals) {
            VStack(alignment: .leading, spacing: 0) {
                Text("In goals")
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                // The total bar (`displayAmount` cap, 40 % of the column) and
                // the count bar (the width of "Across 2 goals").
                SkeletonTextLine(.displayAmount, leadingWidth: 148)
                    .padding(.top, Spacing.space1)
                SkeletonTextLine(.subheadline, leadingWidth: 94)
                    .padding(.top, Spacing.space1)
                SectionHeader("Your goals")
                    .padding(.top, Spacing.sectionGap)
                Grid(horizontalSpacing: Spacing.gridGap, verticalSpacing: Spacing.gridGap) {
                    if dynamicTypeSize.isAccessibilitySize {
                        GridRow { SkeletonCard() }
                        GridRow { SkeletonCard() }
                    } else {
                        GridRow { SkeletonCard(); SkeletonCard() }
                        GridRow { SkeletonCard(); SkeletonCard() }
                    }
                }
                .padding(.top, Spacing.headingToContent)
            }
            .padding(.top, Spacing.space2)
        }
    }
}

/// The "In goals" total (B3.2): a page fact (no container): "In goals"
/// (`subheadline` `textSecondary`), 4 pt, the total (`displayAmount`), 4 pt,
/// "Across {n} goals"; the amber stale line 8 pt below when any goal's
/// balance could not be read. One element, `savings.summary`.
struct SavingsSummary: View {
    let goals: [Goal]

    @ScaledMetric(relativeTo: .footnote) private var staleSymbolSize: CGFloat = 13

    private var total: Money {
        goals.reduce(Money.zero) { $0 + $1.saved }
    }

    private var mayBeOutOfDate: Bool {
        goals.contains { $0.balanceUnavailable == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("In goals")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            MoneyText(total, style: .displayAmount)
                .padding(.top, Spacing.space1)
            Text(SavingsCopy.acrossGoals(goals.count))
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Spacing.space1)
            if mayBeOutOfDate {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: staleSymbolSize, weight: .regular))
                    Text(SavingsCopy.mayBeOutOfDate)
                        .textStyle(.footnote)
                }
                .foregroundStyle(Palette.amberText)
                .padding(.top, Spacing.space2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("In goals")
        .accessibilityValue(
            "\(total.accessibilityText()). \(SavingsCopy.acrossGoals(goals.count))."
                + (mayBeOutOfDate ? " \(SavingsCopy.mayBeOutOfDate)." : "")
        )
        .accessibilityIdentifier("savings.summary")
    }
}
