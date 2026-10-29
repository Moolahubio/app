import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// What a Savings sheet asks the screen underneath to do once it has closed.
enum SavingsSheetExit: Hashable, Sendable {
    case close
    case viewActivity
    case viewGoal(id: String)
    /// Close this sheet and open Create goal (Move to goal with no goals).
    case createGoal
    /// The goal is gone: pop to Savings (with the "Goal deleted." toast when no
    /// receipt was shown).
    case goalDeleted(showToast: Bool)
}

/// Goal detail (DESIGN.md v2 B3.11 to B3.16): the goal's identity band (its
/// 72 pt emoji tile, the saved figure against the target, progress, pace and
/// target date), then the two actions, the plan, "Saved each month", the
/// history and, when the setting is on, the technical details.
struct GoalDetailScreen: View {
    let services: AppServices
    let goalID: String

    @State private var goal: RemoteResource<Goal>
    @State private var activeSheet: GoalSheet?
    @State private var pendingExit: SavingsSheetExit?
    @State private var toast: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var events: SavingsEvents { SavingsEvents.shared }

    enum GoalSheet: Identifiable {
        case moveToGoal(Goal)
        case moveToBalance(Goal)
        case delete(Goal)

        var id: String {
            switch self {
            case .moveToGoal: "moveToGoal"
            case .moveToBalance: "moveToBalance"
            case .delete: "delete"
            }
        }
    }

    init(services: AppServices, goalID: String) {
        self.services = services
        self.goalID = goalID
        let api = services.api
        _goal = State(initialValue: RemoteResource(cacheKey: .goal(goalID), cache: services.cache) {
            try await savingsRead { try await api.send(API.Goals.get(goalID)) }
        })
    }

    /// 404, even over a cached copy: the goal is gone (B3.14).
    private var isNotFound: Bool {
        goal.error?.status == 404
    }

    /// The goal to show: nil while loading, after a failure with nothing
    /// cached, and when it is gone.
    private var shownGoal: Goal? {
        isNotFound ? nil : goal.value
    }

    /// Never loaded: the load failed with nothing cached. The error state
    /// stays while "Try again" retries (B3.15).
    private var loadError: APIError? {
        guard !isNotFound, goal.value == nil else { return nil }
        return goal.error
    }

    /// The scroll view's ground (A8.32): the goal's tint once it is known,
    /// the neutral `fill` band while it loads, plain `canvas` (no band) when
    /// it never loaded or is gone.
    private var groundTint: Color {
        if let value = shownGoal { return GoalTint.color(forAPIKey: value.color) }
        if isNotFound || loadError != nil { return Palette.canvas }
        return Palette.fill
    }

    var body: some View {
        ScrollView {
            content
        }
        .modifier(IdentityBandScreen(tint: groundTint))
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: goal.value?.color)
        .navigationTitle(shownGoal?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let loaded = shownGoal {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Delete goal", systemImage: "trash", role: .destructive) {
                            activeSheet = .delete(loaded)
                        }
                        // Icon and title in the system's one destructive red.
                        .tint(Palette.systemDestructive)
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .accessibilityIdentifier("savings.detail.more")
                }
            }
        }
        .refreshable { await goal.refresh() }
        .task { await goal.load() }
        .onChange(of: events.revision) { _, _ in
            Task { await goal.refresh() }
        }
        .onAppear { takeToast() }
        .onChange(of: events.pendingToast) { _, _ in takeToast() }
        .onChange(of: goal.value != nil) { _, isLoaded in
            guard isLoaded else { return }
            // The skeleton cross-fades into the goal with `Motion.standard`
            // (0.3 s, B3.13); the toast comes once that is done, so it never
            // sits over the skeleton (B3.12).
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                takeToast()
            }
        }
        .toast($toast)
        .sheet(item: $activeSheet, onDismiss: runPendingExit) { sheet in
            sheetContent(sheet)
        }
    }

    /// Shows a queued toast ("Goal created.", B3.12) once the goal is on
    /// screen, so its 3 seconds aren't spent on the skeleton or the sheet.
    private func takeToast() {
        guard shownGoal != nil else { return }
        if let message = events.takeToast(for: .goal(id: goalID)) { toast = message }
    }

    // MARK: Sheets

    @ViewBuilder
    private func sheetContent(_ sheet: GoalSheet) -> some View {
        let finish: (SavingsSheetExit) -> Void = { exit in
            pendingExit = exit
            activeSheet = nil
        }
        switch sheet {
        case .moveToGoal(let goal):
            MoveToGoalFlow(services: services, start: .goal(goal), origin: .goalDetail, finish: finish)
        case .moveToBalance(let goal):
            MoveToBalanceFlow(services: services, goal: goal, finish: finish)
        case .delete(let goal):
            DeleteGoalFlow(services: services, goal: goal, finish: finish)
        }
    }

    private func runPendingExit() {
        let exit = pendingExit
        pendingExit = nil
        switch exit {
        case .viewActivity:
            services.navigator.select(.activity)
        case .viewGoal(let id):
            services.navigator.open(.goalDetail(id: id))
        case .createGoal:
            services.navigator.present(.createGoal)
        case .goalDeleted(let showToast):
            if showToast {
                events.queueToast("Goal deleted.", for: .savingsList)
            }
            services.navigator.popToRoot()
            services.navigator.select(.savings)
            services.navigator.popToRoot()
            events.goalsChanged()
        case .close, nil:
            break
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let value = shownGoal {
            loaded(value)
        } else if isNotFound {
            // B3.14: 24 pt below the bar; no band (there is no goal).
            ErrorState(
                title: "We couldn't find that goal.",
                message: nil,
                retryTitle: "Back to savings",
                retryKind: .primary
            ) {
                // The list drops the goal that is gone (it refetches).
                services.navigator.popToRoot()
                services.navigator.select(.savings)
                services.navigator.popToRoot()
                events.goalsChanged()
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.space6)
        } else if let error = loadError {
            // B3.15 never loaded: on `canvas`, 24 pt below the bar.
            ErrorState(title: "We couldn't load this goal", message: error.message(for: .screen), isRetrying: goal.isLoading) {
                Task { await goal.refresh() }
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.space6)
        } else {
            GoalDetailSkeleton()
        }
    }

    private func loaded(_ goal: Goal) -> some View {
        let now = Date()
        return VStack(alignment: .leading, spacing: 0) {
            IdentityBand(tint: GoalTint.color(forAPIKey: goal.color)) {
                VStack(alignment: .leading, spacing: 0) {
                    statusBlock
                    GoalDetailHeader(goal: goal, now: now)
                }
                .padding(.top, Spacing.space4)
            }
            VStack(alignment: .leading, spacing: 0) {
                actions(goal)
                    .padding(.top, Spacing.space6)
                if !goal.feeRate.isZero {
                    Text("Moving money out of this goal has a \(goal.feeRate.percentText) fee.")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.space3)
                }
                GoalPlanSection(goal: goal)
                    .padding(.top, Spacing.sectionGap)
                SectionHeader("Saved each month")
                    .padding(.top, Spacing.sectionGap)
                SavedEachMonthChart(data: SavedEachMonthData(history: goal.history ?? [], now: now))
                    .padding(.top, Spacing.headingToContent)
                GoalHistorySection(history: goal.history ?? [], now: now)
                    .padding(.top, Spacing.sectionGap)
                if services.settings.showTechnicalDetails, let vault = goal.vaultAddress, !vault.isEmpty {
                    SectionHeader("Technical details")
                        .padding(.top, Spacing.sectionGap)
                    VStack(spacing: 0) {
                        TechnicalDetailsRow(label: "Vault", value: vault)
                        if let network = goal.network, !network.isEmpty {
                            TechnicalDetailsRow(label: "Network", value: network)
                        }
                    }
                    .padding(.top, Spacing.headingToContent - Spacing.space3)
                }
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.bottom, Spacing.space8)
            .modifier(BelowIdentityBand())
        }
    }

    /// The status block inside the band (B3.15, ruling 11): the ErrorBanner
    /// after a failed refresh, 8 pt, "Updated {N} min ago" for a cached
    /// snapshot, then 24 pt to the emoji tile.
    @ViewBuilder
    private var statusBlock: some View {
        let updated = goal.updatedText()
        if goal.error != nil || updated != nil {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                if let error = goal.error {
                    ErrorBanner(error.message(for: .screen)) {
                        Task { await self.goal.refresh() }
                    }
                }
                if let updated {
                    Text(updated)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Spacing.space6)
        }
    }

    /// "Move to goal" (primary) and "Move to balance" (secondary) side by
    /// side, equal widths, 12 apart; stacked at accessibility sizes.
    /// "Nothing to move yet." under "Move to balance" when nothing is saved.
    private func actions(_ goal: Goal) -> some View {
        let canMoveOut = goal.saved.isPositive
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Spacing.space3))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.space3))
        return layout {
            MoolaButton("Move to goal") {
                activeSheet = .moveToGoal(goal)
            }
            .accessibilityIdentifier("savings.detail.moveToGoal")
            VStack(spacing: Spacing.space2) {
                MoolaButton("Move to balance", kind: .secondary) {
                    activeSheet = .moveToBalance(goal)
                }
                .disabled(!canMoveOut)
                .accessibilityHint(canMoveOut ? "" : "Nothing to move yet.")
                .accessibilityIdentifier("savings.detail.moveToBalance")
                if !canMoveOut {
                    DisabledReasonLine(text: "Nothing to move yet.")
                }
            }
        }
    }
}

/// The identity block on the band (A8.6 detail header, B3.11): the 72 pt
/// emoji tile on `canvas`, the saved figure (`displayAmount`), "of {target}",
/// a 6 pt bar on a `canvas` track and the two meta lines ("41% · On track";
/// "Target date Apr 21, 2027 · 5 months left", the "left" clause omitted after
/// the deadline). One element, `savings.detail.header`.
struct GoalDetailHeader: View {
    let goal: Goal
    let now: Date

    private var model: GoalCardModel { GoalCardModel(goal, now: now) }

    /// "Target date Apr 21, 2027 · 5 months left" (W5: the deadline in UTC).
    private var dateLine: String {
        var text = "Target date \(APIDate.formatUTCDay(goal.deadline))"
        if now <= goal.deadline {
            let left = SavingsDates.wholePeriods(from: now, to: goal.deadline, frequency: goal.goalFrequency)
            text += " \u{00B7} \(SavingsCopy.periods(max(0, left), goal.goalFrequency)) left"
        }
        return text
    }

    private var paceLabel: String {
        goal.balanceUnavailable == true ? SavingsCopy.mayBeOutOfDate : model.pace.label
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GoalCard(model, layout: .detail, dateLine: dateLine)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(goal.name)
        .accessibilityValue(
            "\(goal.saved.accessibilityText()) saved of \(goal.target.accessibilityText()). "
                + "\(GoalProgress.percent(saved: goal.saved, target: goal.target)) percent. \(paceLabel). \(dateLine)."
        )
        .accessibilityIdentifier("savings.detail.header")
    }
}

/// "Your plan" (B3.11, W9.1): the heading; 16 pt; "{Frequency} · grows
/// gradually"; 8 pt; "Next step" and "Step" as detail rows; 8 pt; the
/// sentence. With no next step: "You've completed every step of your plan."
struct GoalPlanSection: View {
    let goal: Goal

    private var plan: [Int64] {
        let periods = ContributionPlan.periodsBetween(goal.createdAt, goal.deadline, frequency: goal.goalFrequency)
        return ContributionPlan.progressivePlan(targetCents: goal.targetCents, periods: periods)
    }

    var body: some View {
        let frequency = goal.goalFrequency
        let next = ContributionPlan.nextContribution(plan: plan, savedCents: goal.savedCents)
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your plan")
            Text("\(frequency.label) \u{00B7} grows gradually")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .padding(.top, Spacing.headingToContent)
            if let next {
                VStack(spacing: 0) {
                    DetailRowView(DetailRow("Next step", .text("\(Money(cents: next.amountCents).formatted()) \(SavingsCopy.thisPeriod(frequency))")))
                    DetailRowView(DetailRow("Step", .text("\(next.index) of \(next.total)")))
                }
                .monospacedDigit()
                .padding(.top, Spacing.space2)
                planSentence("About \(SavingsCopy.periods(next.total - next.index + 1, frequency)) of saving left to reach your target.")
            } else {
                planSentence("You've completed every step of your plan.")
            }
        }
    }

    private func planSentence(_ text: String) -> some View {
        Text(text)
            .textStyle(.subheadline)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Spacing.space2)
    }
}

/// "History" (B3.11, A8.19): up to 10 `ActivityRow`s with no dividers, the
/// symbol at the gutter and the text at x 52, the W5 date and time as the
/// sub-line, amounts signed relative to the goal (in `jadeText` "+", out
/// "−"). "Showing your latest 10 moves." when there are more; "No moves
/// yet." when there are none.
struct GoalHistorySection: View {
    let history: [GoalHistoryItem]
    let now: Date

    static let maxRows = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("History")
            if history.isEmpty {
                Text("No moves yet.")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, Spacing.headingToContent)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.prefix(Self.maxRows).enumerated()), id: \.offset) { _, item in
                        ActivityRow(
                            kind: ActivityKind(type: item.type),
                            title: Self.title(for: item),
                            subtitle: MoolaDates.dateAndTime(item.createdAt, now: now),
                            amount: item.amount,
                            status: item.status,
                            symbol: Self.symbol(for: item)
                        )
                    }
                }
                // Rows pad themselves to the gutter: let them run full width.
                .padding(.horizontal, -Spacing.screenGutter)
                .padding(.top, Spacing.headingToContent - Spacing.space3)
                if history.count > Self.maxRows {
                    Text("Showing your latest \(Self.maxRows) moves.")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.top, Spacing.space2)
                }
            }
        }
    }

    /// Positive `goal_allocate` "Moved in", `goal_release` "Moved out", `fee`
    /// "Fee" (W9.4). Anything else by sign.
    static func title(for item: GoalHistoryItem) -> String {
        switch item.type {
        case "fee": "Fee"
        case "goal_release": "Moved out"
        default: item.amountCents >= 0 ? "Moved in" : "Moved out"
        }
    }

    /// `tray.and.arrow.down` (Moved in), `tray.and.arrow.up` (Moved out),
    /// `percent` (Fee) (A7.3).
    static func symbol(for item: GoalHistoryItem) -> String {
        switch title(for: item) {
        case "Fee": "percent"
        case "Moved out": "tray.and.arrow.up"
        default: "tray.and.arrow.down"
        }
    }
}

/// Goal detail while it first loads (B3.13): the band in the neutral `fill`
/// with the 72 pt emoji block in `canvas` and `fillPressed` bars for the
/// figures; the action blocks; "Your plan" with two row skeletons. One
/// element "Loading goal…".
struct GoalDetailSkeleton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var emojiScale: CGFloat = 1

    var body: some View {
        // The emoji block scales like the 72 pt EmojiTile (at most 1.5 ×);
        // each figure line is reserved at its real height (`SkeletonTextLine`).
        let emojiSide = EmojiTileSize.s72.rawValue * min(emojiScale, 1.5)
        LoadingPlaceholder(label: SavingsCopy.loadingGoal) {
            VStack(alignment: .leading, spacing: 0) {
                IdentityBand(tint: Palette.fill) {
                    VStack(alignment: .leading, spacing: 0) {
                        SkeletonBlock(width: emojiSide, height: emojiSide, cornerRadius: EmojiTileSize.s72.cornerRadius, color: Palette.canvas)
                        SkeletonTextLine(.displayAmount, leadingWidth: 148, color: Palette.fillPressed)
                            .padding(.top, Spacing.space4)
                        SkeletonTextLine(.amountSmall, leadingWidth: 65, color: Palette.fillPressed)
                        SkeletonBlock(height: 6, cornerRadius: 3, color: Palette.canvas)
                            .padding(.top, Spacing.space4)
                        SkeletonTextLine(.footnote, leadingWidth: 89, color: Palette.fillPressed)
                            .padding(.top, Spacing.space2)
                        SkeletonTextLine(.footnote, leadingWidth: 237, color: Palette.fillPressed)
                            .padding(.top, 2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.space4)
                }
                VStack(alignment: .leading, spacing: 0) {
                    actionBlocks
                        .padding(.top, Spacing.space6)
                    SectionHeader("Your plan")
                        .padding(.top, Spacing.sectionGap)
                    VStack(spacing: 0) {
                        ForEach(0..<2, id: \.self) { _ in
                            SkeletonTextLine(.body, leadingWidth: 70, trailingWidth: 144)
                                .frame(minHeight: 48)
                        }
                    }
                    .padding(.top, Spacing.headingToContent)
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.bottom, Spacing.space8)
                .modifier(BelowIdentityBand())
            }
        }
    }

    @ViewBuilder
    private var actionBlocks: some View {
        let block = SkeletonBlock(height: Size.buttonHeight, cornerRadius: Radius.control)
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Spacing.space3) { block; block }
        } else {
            HStack(spacing: Spacing.space3) { block; block }
        }
    }
}
