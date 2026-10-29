import AppFeature
import SwiftUI

/// App entry point. All app code lives in MoolahubKit; this target only owns
/// the bundle (Info.plist, asset catalog) and starts `AppRootView`. The app
/// bundles no fonts: SF Pro and SF Pro Rounded are the system's (DESIGN.md v2 A2.1).
@main
struct MoolahubApp: App {
    @State private var composition: AppComposition

    init() {
        AppComposition.configureAppearance()
        _composition = State(initialValue: AppComposition.live())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(composition: composition)
        }
    }
}
