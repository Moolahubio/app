import Auth
import DesignSystem
import SwiftUI

/// Streak frequency (streaks.md ST.5), pushed for
/// `AppDestination.streakFrequency` from the Streak screen and from Account.
/// F0 stub: the bar title and the root identifier only (SPEC §8.2 item 7);
/// lane S builds the screen.
public struct StreakFrequencyScreen: View {
    private let services: AppServices

    public init(services: AppServices) {
        self.services = services
    }

    public var body: some View {
        ScrollView {}
            .accessibilityIdentifier("streak.frequency.screen")
            .moolaCanvas()
            .navigationTitle("Streak frequency")
            .navigationBarTitleDisplayMode(.inline)
    }
}
