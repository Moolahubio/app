import Foundation

// Value types for cross-feature navigation. The `Router` that acts on them
// lives in AppFeature; features ask for navigation through `Navigator` (Auth).

/// The five tabs, in order (DESIGN.md §6).
public enum AppTab: String, CaseIterable, Hashable, Sendable, Identifiable {
    case home, savings, groups, activity, account

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .home: "Home"
        case .savings: "Savings"
        case .groups: "Groups"
        case .activity: "Activity"
        case .account: "Account"
        }
    }

    /// The tab symbol (DESIGN.md v2 A7.2). Each has a `.fill` variant, which
    /// the system draws in the tab bar; pass the base name.
    public var symbolName: String {
        switch self {
        case .home: "house"
        case .savings: "flag"
        case .groups: "person.3"
        case .activity: "list.bullet.rectangle.portrait"
        case .account: "person.crop.circle"
        }
    }
}

/// Screens one feature pushes that another feature owns. AppFeature maps each
/// case to the owning feature's public view.
public enum AppDestination: Hashable, Sendable {
    /// FeatureSavings `GoalDetailView`.
    case goalDetail(id: String)
    /// FeatureCircles `GroupDetailView`.
    case groupDetail(id: String)
    /// FeatureCircles `GroupDetailView(services:groupID:opensPayIn: true)`: the
    /// same screen, which opens Pay in once on a live `canContribute == true`
    /// (Home's next pay-in notice).
    case groupPayIn(id: String)
    /// FeatureStreaks `StreakScreen` (root `streak.screen`).
    case streak
    /// FeatureStreaks `StreakFrequencyScreen` (root `streak.frequency.screen`).
    case streakFrequency
    /// FeatureLearn `LearnListView`.
    case learn
    /// FeatureLearn `LessonView`.
    case lesson(slug: String)
}

/// App-level sheets that more than one feature opens. AppFeature presents them
/// over the whole app.
public enum AppSheet: Hashable, Sendable, Identifiable {
    #if DEBUG
    /// FeatureHome `AddTestMoneySheet` (DESIGN.md §7.1; Debug builds only).
    case addTestMoney
    #endif
    /// FeatureHome `AddMoneySheet`: "Adding money isn't available yet." Every
    /// build; reached through `AddMoneyRoute.appSheet`.
    case addMoney
    /// FeatureStreaks `NewBadgeSheet`. Presented only by AppFeature's
    /// `AppRootView`.
    case newStreakBadge(StreakBadge)
    /// FeatureHome `CashOutSheet` (DESIGN.md §7.6).
    case cashOut
    /// FeatureSavings `MoveToGoalSheet`; nil starts at "Choose a goal".
    case moveToGoal(goalID: String?)
    /// FeatureSavings `CreateGoalSheet`.
    case createGoal
    /// FeatureCircles `CreateGroupSheet`.
    case createGroup
    /// FeatureActivity `ActivityReceiptSheet`: a move reopened from an Activity
    /// or Home row (DESIGN.md v2 B2.7, J7).
    case activityReceipt(ActivityItem)
    #if DEBUG
    /// AppFeature developer settings (Debug builds only).
    case developerSettings
    #endif

    public var id: String {
        switch self {
        #if DEBUG
        case .addTestMoney: "addTestMoney"
        #endif
        case .addMoney: "addMoney"
        case .newStreakBadge(let badge): "newStreakBadge-\(badge.badgeKey)"
        case .cashOut: "cashOut"
        case .moveToGoal(let goalID): "moveToGoal-\(goalID ?? "")"
        case .createGoal: "createGoal"
        case .createGroup: "createGroup"
        case .activityReceipt(let item): "activityReceipt-\(item.id)"
        #if DEBUG
        case .developerSettings: "developerSettings"
        #endif
        }
    }
}
