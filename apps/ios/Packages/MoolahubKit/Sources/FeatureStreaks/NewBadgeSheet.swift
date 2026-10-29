import Auth
import DesignSystem
import Domain
import SwiftUI

/// New badge (SPEC §2.6, streaks.md ST.9), presented only by AppFeature's
/// `AppRootView` for `AppSheet.newStreakBadge(_:)` (D-23). F0 stub: the title
/// and "Done", which marks every badge seen, so a badge that comes due before
/// lane S merges never strands anyone in an empty sheet (SPEC §8.2 item 7).
public struct NewBadgeSheet: View {
    private let services: AppServices
    private let badge: StreakBadge
    @Environment(\.dismiss) private var dismiss

    public init(services: AppServices, badge: StreakBadge) {
        self.services = services
        self.badge = badge
    }

    public var body: some View {
        ScrollView {
            Text("New badge")
                .textStyle(.title2)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.sheetPadding)
                .padding(.top, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            MoolaButton("Done") {
                services.streaks.markBadgesSeen()
                dismiss()
            }
            .accessibilityIdentifier("streak.badgeSheet.done")
        })
        .sheetChrome([.medium])
    }
}
