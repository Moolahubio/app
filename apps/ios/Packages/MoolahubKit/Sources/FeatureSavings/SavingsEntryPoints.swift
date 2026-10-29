import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

// Public entry points AppFeature wires up. Keep these names and initializers;
// everything else in this folder is internal (see README.md).

/// Savings tab root (DESIGN.md v2 B3.2 to B3.7). Placed inside the Savings tab's `NavigationStack`.
public struct SavingsRootView: View {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        SavingsListScreen(services: services)
    }
}

/// Goal detail (DESIGN.md v2 B3.11 to B3.16), pushed for `AppDestination.goalDetail(id:)`
/// from any tab.
public struct GoalDetailView: View {
    private let services: AppServices
    private let goalID: String

    public init(services: AppServices, goalID: String) {
        self.services = services
        self.goalID = goalID
    }

    public var body: some View {
        GoalDetailScreen(services: services, goalID: goalID)
    }
}

/// Move to goal sheet (DESIGN.md v2 J2), presented for `AppSheet.moveToGoal(goalID:)`.
/// `goalID == nil` starts at "Choose a goal".
public struct MoveToGoalSheet: View {
    private let services: AppServices
    private let goalID: String?
    @Environment(\.dismiss) private var dismiss

    public init(services: AppServices, goalID: String?) {
        self.services = services
        self.goalID = goalID
    }

    public var body: some View {
        MoveToGoalFlow(
            services: services,
            start: goalID.map { MoveToGoalModel.Start.goalID($0) } ?? .choose,
            origin: .elsewhere
        ) { exit in
            switch exit {
            case .createGoal:
                // Replaces this app-level sheet with Create goal.
                services.navigator.present(.createGoal)
            case .viewActivity:
                dismiss()
                services.navigator.select(.activity)
            case .viewGoal(let id):
                dismiss()
                services.navigator.open(.goalDetail(id: id))
            case .close, .goalDeleted:
                dismiss()
            }
        }
    }
}

/// Create goal sheet (DESIGN.md v2 B3.8), presented for `AppSheet.createGoal`.
/// On success: closes, pushes the new goal's detail on the current tab and
/// shows "Goal created." there.
public struct CreateGoalSheet: View {
    private let services: AppServices
    @Environment(\.dismiss) private var dismiss

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        CreateGoalFlow(services: services, close: { dismiss() }) { goal in
            let events = SavingsEvents.shared
            events.queueToast("Goal created.", for: .goal(id: goal.id))
            events.goalsChanged()
            dismiss()
            services.navigator.open(.goalDetail(id: goal.id))
        }
    }
}
