import Auth
import Domain
import Observation
import SwiftUI

/// Typed navigation state: the selected tab, one `NavigationPath` per tab
/// (preserved when switching tabs), and the app-level sheet. Implements the
/// `Navigator` protocol features use.
@MainActor
@Observable
public final class Router: Navigator {
    public var selectedTab: AppTab = .home
    public var homePath = NavigationPath()
    public var savingsPath = NavigationPath()
    public var groupsPath = NavigationPath()
    public var activityPath = NavigationPath()
    public var accountPath = NavigationPath()
    public var sheet: AppSheet?
    /// Counts app-level sheet dismissals (see `Navigator.appSheetDismissals`).
    public private(set) var appSheetDismissals = 0

    /// Builds sheet content; set by AppFeature once services exist.
    @ObservationIgnored var sheetBuilder: ((AppSheet) -> AnyView)?

    public init() {}

    public func path(for tab: AppTab) -> NavigationPath {
        switch tab {
        case .home: homePath
        case .savings: savingsPath
        case .groups: groupsPath
        case .activity: activityPath
        case .account: accountPath
        }
    }

    public func setPath(_ path: NavigationPath, for tab: AppTab) {
        switch tab {
        case .home: homePath = path
        case .savings: savingsPath = path
        case .groups: groupsPath = path
        case .activity: activityPath = path
        case .account: accountPath = path
        }
    }

    /// Tab bar selection. Re-tapping the selected tab pops it to its root
    /// (DESIGN.md §6).
    public func tabTapped(_ tab: AppTab) {
        if tab == selectedTab {
            popToRoot()
        } else {
            selectedTab = tab
        }
    }

    /// Clears all navigation (sign-out, server change).
    public func reset() {
        selectedTab = .home
        for tab in AppTab.allCases { setPath(NavigationPath(), for: tab) }
        sheet = nil
    }

    // MARK: Navigator

    public func select(_ tab: AppTab) {
        selectedTab = tab
    }

    public func open(_ destination: AppDestination) {
        var path = path(for: selectedTab)
        path.append(destination)
        setPath(path, for: selectedTab)
    }

    public func push(_ route: any Hashable & Sendable) {
        var path = path(for: selectedTab)
        path.append(route)
        setPath(path, for: selectedTab)
    }

    public func popToRoot() {
        setPath(NavigationPath(), for: selectedTab)
    }

    public func present(_ sheet: AppSheet) {
        self.sheet = sheet
    }

    public func dismissSheet() {
        sheet = nil
    }

    /// Called by `AppRootView` when an app-level sheet has gone away.
    func appSheetDidDismiss() {
        appSheetDismissals += 1
    }

    public func sheetView(for sheet: AppSheet) -> AnyView {
        sheetBuilder?(sheet) ?? AnyView(EmptyView())
    }

    // MARK: Deep links

    /// Handles an incoming URL (Universal Links once AASA exists; see
    /// `DeepLink`). Returns true when the URL was understood.
    @discardableResult
    public func handle(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        sheet = nil
        switch link {
        case .tab(let tab):
            selectedTab = tab
            popToRoot()
        case .goal(let id):
            selectedTab = .savings
            setPath(NavigationPath([AppDestination.goalDetail(id: id)]), for: .savings)
        case .group(let id):
            selectedTab = .groups
            setPath(NavigationPath([AppDestination.groupDetail(id: id)]), for: .groups)
        }
        return true
    }
}

/// Deep link parser (stub). Accepts `https://<any host>/app/<path>` and
/// `moolahub://<path>` where path is `home`, `savings`, `groups`, `activity`,
/// `account`, `goals/<id>` or `groups/<id>`. No URL scheme or associated
/// domain is registered yet, so nothing can open these today; the plan is
/// Universal Links only (docs/ios-app-plan.md §2) once the API domain and AASA
/// exist.
public enum DeepLink: Hashable, Sendable {
    case tab(AppTab)
    case goal(id: String)
    case group(id: String)

    public init?(url: URL) {
        var parts = url.pathComponents.filter { $0 != "/" }
        switch url.scheme?.lowercased() {
        case "https":
            guard parts.first == "app" else { return nil }
            parts.removeFirst()
        case "moolahub":
            if let host = url.host, !host.isEmpty { parts.insert(host, at: 0) }
        default:
            return nil
        }
        guard let first = parts.first else { return nil }
        let isSafeID: (String) -> Bool = { id in
            !id.isEmpty && id.count <= 64 && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        switch (first, parts.count) {
        case ("goals", 2) where isSafeID(parts[1]): self = .goal(id: parts[1])
        case ("groups", 2) where isSafeID(parts[1]): self = .group(id: parts[1])
        case (_, 1):
            guard let tab = AppTab(rawValue: first) else { return nil }
            self = .tab(tab)
        default:
            return nil
        }
    }
}
