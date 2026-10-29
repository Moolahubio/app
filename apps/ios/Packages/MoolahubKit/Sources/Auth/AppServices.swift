import APIClient
import Domain
import Foundation
import Observation
import Persistence
import SwiftUI

/// How features ask for navigation they don't own. AppFeature's `Router`
/// implements it; features get it from `AppServices.navigator`.
///
/// - Same-feature pushes: use `NavigationLink(value:)` with your own route
///   type and register `.navigationDestination(for:)` inside your root view.
/// - Another feature's screen: `open(.goalDetail(id:))`.
/// - App-level sheets: `present(.moveToGoal(goalID:))`.
@MainActor
public protocol Navigator: AnyObject {
    /// Switches tab (keeps each tab's stack).
    func select(_ tab: AppTab)
    /// Pushes another feature's screen on the current tab's stack.
    func open(_ destination: AppDestination)
    /// Pushes a feature-local route value on the current tab's stack (for
    /// programmatic pushes, e.g. after "Create goal" succeeds).
    func push(_ route: any Hashable & Sendable)
    /// Pops the current tab to its root.
    func popToRoot()
    /// Presents an app-level sheet over everything.
    func present(_ sheet: AppSheet)
    /// Dismisses the app-level sheet.
    func dismissSheet()
    /// The view for an app-level sheet, for presenting it from inside your own
    /// sheet (SwiftUI can't present a root sheet while yours is up).
    func sheetView(for sheet: AppSheet) -> AnyView
    /// Goes up by one each time an app-level sheet closes. Any of them may
    /// have moved money (Add test money, Move to goal), so a screen that stays
    /// on screen under them (Home) refreshes when it changes. Observable.
    var appSheetDismissals: Int { get }
}

/// What "View activity" does in a money sheet after a move whose outcome is
/// unknown (DESIGN.md v2 J0.7): close the sheet and select Activity. A sheet
/// that presents another money sheet on top of itself (Pay in under Add test
/// money, A9.3) puts its own action in the environment, so both sheets close
/// and nothing covers Activity.
public struct ViewActivityAction: Sendable {
    private let run: @MainActor @Sendable () -> Void

    public init(_ run: @escaping @MainActor @Sendable () -> Void) {
        self.run = run
    }

    @MainActor
    public func callAsFunction() {
        run()
    }
}

private struct ViewActivityActionKey: EnvironmentKey {
    static let defaultValue: ViewActivityAction? = nil
}

extension EnvironmentValues {
    /// Set by a sheet that presents a money sheet on top of itself; nil
    /// otherwise (the money sheet then closes itself and selects Activity).
    public var viewActivityOverride: ViewActivityAction? {
        get { self[ViewActivityActionKey.self] }
        set { self[ViewActivityActionKey.self] = newValue }
    }
}

/// Static facts about this build.
public struct BuildInfo: Sendable, Hashable {
    public let version: String
    public let build: String
    public let bundleIdentifier: String
    public let configuration: String

    public init(version: String, build: String, bundleIdentifier: String, configuration: String) {
        self.version = version
        self.build = build
        self.bundleIdentifier = bundleIdentifier
        self.configuration = configuration
    }

    public static func current() -> BuildInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        return BuildInfo(
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
            configuration: configuration
        )
    }

    /// "0.1.0 (1)" for About and legal.
    public var displayVersion: String { "\(version) (\(build))" }
}

/// Everything a feature needs, created once by AppFeature and passed to each
/// feature's entry view (constructor injection). Also in the SwiftUI
/// environment: `@Environment(AppServices.self) var services`.
@MainActor
@Observable
public final class AppServices {
    @ObservationIgnored public let api: APIClient
    @ObservationIgnored public let session: SessionStore
    @ObservationIgnored public let cache: SnapshotCache
    @ObservationIgnored public let settings: DeviceSettings
    @ObservationIgnored public let appLock: AppLock
    @ObservationIgnored public let authenticator: DeviceAuthenticator
    @ObservationIgnored public let buildInfo: BuildInfo
    @ObservationIgnored public let navigator: any Navigator
    /// The account's savings streak, shared by every streak surface.
    @ObservationIgnored public let streaks: StreakStore
    /// Sends the device's time zone for streak periods (SPEC §4.5).
    @ObservationIgnored public let timeZoneSync: TimeZoneSync

    public init(
        api: APIClient,
        session: SessionStore,
        cache: SnapshotCache,
        settings: DeviceSettings,
        appLock: AppLock,
        authenticator: DeviceAuthenticator,
        buildInfo: BuildInfo,
        navigator: any Navigator,
        streaks: StreakStore,
        timeZoneSync: TimeZoneSync
    ) {
        self.api = api
        self.session = session
        self.cache = cache
        self.settings = settings
        self.appLock = appLock
        self.authenticator = authenticator
        self.buildInfo = buildInfo
        self.navigator = navigator
        self.streaks = streaks
        self.timeZoneSync = timeZoneSync
    }
}
