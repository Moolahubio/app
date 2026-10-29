import DesignSystem
import SwiftUI

/// "Add money" (home.md H9): what the Add money tile opens in every build
/// where it can't add test money, Release included. Presented by AppFeature
/// for `AppSheet.addMoney`. F0 stub: the title and the root identifier only
/// (SPEC §8.2 item 7); lane H builds the info sheet.
public struct AddMoneySheet: View {
    @Environment(\.dismiss) private var dismiss

    public init() {}

    public var body: some View {
        ScrollView {
            Text("Add money")
                .textStyle(.title2)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.sheetPadding)
                .padding(.top, Spacing.space6)
        }
        .accessibilityIdentifier("home.addMoney.unavailable")
        .scrollBounceBehavior(.basedOnSize)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            MoolaButton("Done") { dismiss() }
        })
        .sheetChrome([.medium])
    }
}
