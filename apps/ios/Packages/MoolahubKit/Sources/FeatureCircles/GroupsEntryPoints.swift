import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

// Public entry points AppFeature wires up. Keep these names and initializers;
// everything else lives inside this folder (see README.md).

/// Groups tab root (DESIGN.md v2 B4.1 to B4.9). Placed inside the Groups tab's `NavigationStack`.
public struct GroupsRootView: View {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        GroupsListView(services: services)
    }
}

/// Group detail (DESIGN.md v2 B4.13 to B4.27), pushed for `AppDestination.groupDetail(id:)`,
/// and with `opensPayIn` for `AppDestination.groupPayIn(id:)` (Home's next
/// pay-in notice; lane G opens Pay in once on a live `canContribute == true`).
public struct GroupDetailView: View {
    private let services: AppServices
    private let groupID: String
    private let opensPayIn: Bool

    public init(services: AppServices, groupID: String, opensPayIn: Bool = false) {
        self.services = services
        self.groupID = groupID
        self.opensPayIn = opensPayIn
    }

    public var body: some View {
        GroupDetailScreen(services: services, groupID: groupID)
            .id(groupID)
    }
}

/// Create group sheet (DESIGN.md v2 B4.10 to B4.12), presented for `AppSheet.createGroup`.
public struct CreateGroupSheet: View {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        CreateGroupForm(services: services)
    }
}
