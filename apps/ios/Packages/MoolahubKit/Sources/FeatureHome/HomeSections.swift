import DesignSystem
import Domain
import SwiftUI

// Home's sections under the balance (DESIGN.md v2 B2.1): "Your goals" as goal
// rows with the goal's own emoji tile, "Your groups" as outlined cards and
// "Recent activity" as plain rows without symbols. Sections sit 52 pt apart
// (`sectionGap`); headings and cards at the 16 pt gutter, rows full width with
// their content at the gutter, so a pressed row fills edge to edge.

/// The identity media column of Home's goal rows (A3.1): text starts at x 80.
private let goalTextColumn = Spacing.screenGutter + EmojiTileSize.s52.rawValue + Spacing.space3

// MARK: - Your goals

/// "Your goals": the heading (with "See all" only when there are goals, D8),
/// then up to `previewLimit` goal rows separated by a divider from the text
/// column to the trailing gutter. With no goals, one sentence and a small
/// secondary "Create goal" (C6).
struct HomeGoalsSection: View {
    let goals: [Goal]
    /// The summary's `balanceUnavailable`. The dashboard's goals omit their own
    /// flag (B2.0.2), so while it is true every row says "May be out of date".
    let balanceUnavailable: Bool
    let seeAll: () -> Void
    let open: (String) -> Void
    let createGoal: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// The server sends at most 3; the client cap stays as a guard (tests: at most 4).
    static let previewLimit = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                "Your goals",
                actionTitle: goals.isEmpty ? nil : "See all",
                actionHint: "Opens Savings.",
                action: goals.isEmpty ? nil : seeAll
            )
            .padding(.horizontal, Spacing.screenGutter)
            if goals.isEmpty {
                empty
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        let shown = Array(goals.prefix(Self.previewLimit))
        return VStack(spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, goal in
                if index > 0 {
                    HomeRowDivider(leading: dynamicTypeSize.isAccessibilitySize ? Spacing.screenGutter : goalTextColumn)
                }
                Button {
                    open(goal.id)
                } label: {
                    GoalCard(model(for: goal), layout: .row)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("home.goal.\(goal.id)")
            }
        }
        // `headingToContent` is the row's own 16 pt top padding (A3.2).
        .padding(.top, Spacing.headingToContent - Spacing.space4)
    }

    private func model(for goal: Goal) -> GoalCardModel {
        let model = GoalCardModel(goal)
        guard balanceUnavailable, !model.mayBeOutOfDate else { return model }
        return GoalCardModel(
            id: model.id, name: model.name, emoji: model.emoji, colorKey: model.colorKey,
            saved: model.saved, target: model.target, pace: model.pace, deadline: model.deadline,
            mayBeOutOfDate: true
        )
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("No goals yet. Create your first one.")
                .textStyle(.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            MoolaButton("Create goal", kind: .secondary, size: .small, action: createGoal)
                .padding(.top, Spacing.space3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.top, Spacing.headingToContent)
        // The sentence and the button stay separate elements (tests read both).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.goals.empty")
    }
}

// MARK: - Your groups

/// "Your groups": up to `previewLimit` outlined group cards, 12 pt apart. Not
/// drawn when there are no groups (C7).
struct HomeGroupsSection: View {
    let groups: [CircleSummary]
    let seeAll: () -> Void
    let open: (String) -> Void

    static let previewLimit = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your groups", actionTitle: "See all", actionHint: "Opens Groups.", action: seeAll)
            VStack(spacing: Spacing.space3) {
                ForEach(groups.prefix(Self.previewLimit)) { group in
                    Button {
                        open(group.id)
                    } label: {
                        GroupCard(GroupCardModel(group))
                    }
                    .buttonStyle(PressableCardButtonStyle(restingFill: Palette.canvas))
                    .accessibilityIdentifier("home.group.\(group.id)")
                }
            }
            .padding(.top, Spacing.headingToContent)
        }
        .padding(.horizontal, Spacing.screenGutter)
    }
}

// MARK: - Recent activity

/// "Recent activity": up to `previewLimit` rows with no symbol (Home's text
/// edges are x 16 and x 80 only, A3.1), each opening the move's receipt; or
/// "No activity yet." (C8). No dividers: rows sit at their 64 pt pitch.
struct HomeRecentActivitySection: View {
    let items: [ActivityItem]
    let seeAll: () -> Void
    let openReceipt: (ActivityItem) -> Void

    static let previewLimit = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(
                "Recent activity",
                actionTitle: items.isEmpty ? nil : "See all",
                actionHint: "Opens Activity.",
                action: items.isEmpty ? nil : seeAll
            )
            .padding(.horizontal, Spacing.screenGutter)
            if items.isEmpty {
                Text("No activity yet.")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.headingToContent)
                    .accessibilityIdentifier("home.activity.empty")
            } else {
                VStack(spacing: 0) {
                    ForEach(items.prefix(Self.previewLimit)) { item in
                        ActivityRow(item, subtitle: HomeActivityDay.subline(for: item.createdAt), symbol: nil) {
                            openReceipt(item)
                        }
                        .accessibilityIdentifier("home.activity.\(item.id)")
                    }
                }
                // 16 to the content, less the row's own 12 pt padding (A3.2).
                .padding(.top, Spacing.headingToContent - Spacing.space3)
            }
        }
    }
}

/// The sub-line of Home's activity rows (B2 D7, W5): Home has no day headers,
/// so a move that is not from today shows its day. Same day "10:36 AM";
/// previous day "Yesterday"; this year "Mon, Oct 20"; earlier "Mon, Oct 20, 2025".
enum HomeActivityDay {
    static func subline(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            var time = Date.FormatStyle.dateTime.hour().minute()
            time.calendar = calendar
            time.timeZone = calendar.timeZone
            return date.formatted(time)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }
}

/// A 1 pt divider between peer rows, from `leading` to the trailing gutter (A3.6).
struct HomeRowDivider: View {
    let leading: CGFloat

    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: Size.hairline)
            .padding(.leading, leading)
            .padding(.trailing, Spacing.screenGutter)
            .accessibilityHidden(true)
    }
}

// MARK: - Loading (C2)

/// The sections while Home loads for the first time (B2.1 C2): the "Your
/// goals" heading (no "See all": unknown yet) over two goal-row skeletons,
/// then "Recent activity" over three activity-row skeletons, all at the real
/// row geometry, each block one VoiceOver element with its loading label (W8).
/// No groups skeleton: whether there are groups is only known from the API.
struct HomeSectionsSkeleton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your goals")
                .padding(.horizontal, Spacing.screenGutter)
            LoadingPlaceholder(label: "Loading your goals\u{2026}") {
                VStack(spacing: 0) {
                    GoalRowSkeleton()
                    HomeRowDivider(leading: dynamicTypeSize.isAccessibilitySize ? Spacing.screenGutter : goalTextColumn)
                    GoalRowSkeleton()
                }
            }
            .padding(.top, Spacing.headingToContent - Spacing.space4)

            SectionHeader("Recent activity")
                .padding(.horizontal, Spacing.screenGutter)
                // The goal rows end in their own bottom padding (A3.2).
                .padding(.top, Spacing.sectionGap - Size.goalRowBottomPadding)
            LoadingPlaceholder(label: "Loading activity\u{2026}") {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        ActivityRowSkeleton(showsSymbol: false)
                    }
                }
            }
            .padding(.top, Spacing.headingToContent - Spacing.space3)
        }
    }
}

