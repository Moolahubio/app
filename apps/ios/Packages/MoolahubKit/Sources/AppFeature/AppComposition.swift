import APIClient
import Auth
import DesignSystem
import Domain
import FeatureActivity
import FeatureCircles
import FeatureHome
import FeatureSavings
import FeatureStreaks
import Foundation
import Persistence
import SwiftUI

/// Builds the live object graph once at launch. The app target calls
/// `AppComposition.live()` and shows `AppRootView(composition:)`.
@MainActor
public final class AppComposition {
    public let services: AppServices
    public let router: Router

    init(services: AppServices, router: Router) {
        self.services = services
        self.router = router
    }

    public static func live() -> AppComposition {
        #if DEBUG
        resetForUITestsIfRequested()
        #endif
        let router = Router()
        let settings = DeviceSettings()
        let authenticator = DeviceAuthenticator()
        let cache = SnapshotCache()
        let api = APIClient(baseURL: ServerEnvironment.currentBaseURL(), clientInfo: launchClientInfo())
        let session = SessionStore(api: api, tokenStore: KeychainTokenStore(), cache: cache)
        let appLock = AppLock(settings: settings, authenticator: authenticator)
        let streaks = StreakStore(api: api, session: session, cache: cache)
        let timeZoneSync = TimeZoneSync(api: api, session: session, currentIdentifier: launchTimeZoneIdentifier())
        let services = AppServices(
            api: api,
            session: session,
            cache: cache,
            settings: settings,
            appLock: appLock,
            authenticator: authenticator,
            buildInfo: .current(),
            navigator: router,
            streaks: streaks,
            timeZoneSync: timeZoneSync
        )
        router.sheetBuilder = { [weak services] sheet in
            guard let services else { return AnyView(EmptyView()) }
            return AnyView(AppSheetContent(sheet: sheet, services: services))
        }
        return AppComposition(services: services, router: router)
    }

    /// The client's facts; in Debug, with a UI test run's id (D-36).
    private static func launchClientInfo() -> APIClient.ClientInfo {
        let info = APIClient.ClientInfo.fromMainBundle()
        #if DEBUG
        return APIClient.ClientInfo(
            appVersion: info.appVersion,
            build: info.build,
            testRunID: testRunID(from: ProcessInfo.processInfo.environment)
        )
        #else
        return info
        #endif
    }

    /// The zone `TimeZoneSync` compares and sends: the device's; in Debug, the
    /// launch environment's `MH_TIME_ZONE` when set (SPEC §4.5). Dates on
    /// screen always use the device zone.
    private static func launchTimeZoneIdentifier() -> @Sendable () -> String {
        #if DEBUG
        if let zone = ProcessInfo.processInfo.environment["MH_TIME_ZONE"], !zone.isEmpty {
            return { zone }
        }
        #endif
        return { TimeZone.current.identifier }
    }

    /// Global UIKit appearance: inline navigation titles in SF Pro 21 Bold
    /// (DESIGN.md v2 A2.5 rule 4). Large titles, glass and the scroll edge stay
    /// system-drawn. Call before the first view.
    public static func configureAppearance() {
        NavigationBarFonts.applyInlineTitle()
    }

    #if DEBUG
    /// A UI test run's id from the launch environment `MH_TEST_RUN_ID`, sent as
    /// `X-MH-Test-Run` so the dev backend's log attributes the run's requests
    /// (D-36). Anything but 1 to 64 letters, digits and hyphens is ignored.
    static func testRunID(from environment: [String: String]) -> String? {
        guard let id = environment["MH_TEST_RUN_ID"],
              id.firstMatch(of: #/^[A-Za-z0-9-]{1,64}$/#.matchingSemantics(.unicodeScalar)) != nil
        else { return nil }
        return id
    }

    /// Launch argument for UI tests and clean manual runs: wipes the session
    /// token, cached snapshots and device settings before anything reads them.
    public static let resetLaunchArgument = "-mh-reset-state"

    private static func resetForUITestsIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains(resetLaunchArgument) else { return }
        try? KeychainTokenStore().deleteToken()
        let defaults = UserDefaults.standard
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix("device.") || key.hasPrefix("session.") || key.hasPrefix("dev.") {
            defaults.removeObject(forKey: key)
        }
        // Mark the install as seen so restore() doesn't treat it as fresh.
        defaults.set(UUID().uuidString, forKey: "session.installMarker")
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(at: support.appendingPathComponent("Snapshots"))
        }
    }
    #endif
}

/// Maps each app-level sheet to the owning feature's view.
struct AppSheetContent: View {
    let sheet: AppSheet
    let services: AppServices

    var body: some View {
        Group {
            switch sheet {
            #if DEBUG
            case .addTestMoney:
                AddTestMoneySheet(services: services)
            #endif
            case .addMoney:
                AddMoneySheet()
            case .newStreakBadge(let badge):
                NewBadgeSheet(services: services, badge: badge)
            case .cashOut:
                CashOutSheet()
            case .moveToGoal(let goalID):
                MoveToGoalSheet(services: services, goalID: goalID)
            case .createGoal:
                CreateGoalSheet(services: services)
            case .createGroup:
                CreateGroupSheet(services: services)
            case .activityReceipt(let item):
                ActivityReceiptSheet(item: item, services: services)
            #if DEBUG
            case .developerSettings:
                DeveloperSettingsView(services: services)
            #endif
            }
        }
        .environment(services)
        .environment(services.session)
        .environment(services.settings)
        // No tint here (DESIGN.md v2 U2): sheets take ink from `SheetChrome`,
        // and the app's AccentColor asset is the same ink (A1.6).
    }
}
