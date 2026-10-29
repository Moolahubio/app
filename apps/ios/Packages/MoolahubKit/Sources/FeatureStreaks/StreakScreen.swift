import Auth
import DesignSystem
import SwiftUI

/// Savings streak (SPEC §2.3, streaks.md ST.4), pushed for
/// `AppDestination.streak`. F0 stub: the bar title and the root identifier
/// only (SPEC §8.2 item 7); lane S builds the screen.
public struct StreakScreen: View {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        ScrollView {}
            .accessibilityIdentifier("streak.screen")
            .moolaCanvas()
            .navigationTitle("Savings streak")
            .navigationBarTitleDisplayMode(.inline)
    }
}
