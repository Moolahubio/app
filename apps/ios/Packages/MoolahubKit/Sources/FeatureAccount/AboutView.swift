import Auth
import DesignSystem
import Foundation
import SwiftUI

/// The disclosures listed in About and legal (DESIGN.md v2 B5.8, B5.9, W7).
/// The Test money row exists in Debug builds only, as Add test money does
/// (account.md §11A; SPEC §8.2 item 9).
enum AccountDisclosure: String, Hashable, Sendable, CaseIterable {
    case aboutBalance
    #if DEBUG
    case testMoney
    #endif

    var title: String {
        switch self {
        case .aboutBalance: "About your balance"
        #if DEBUG
        case .testMoney: "Test money"
        #endif
        }
    }

    /// Verbatim copy (W7), from DesignSystem's `Disclosure`.
    var text: String {
        switch self {
        case .aboutBalance: Disclosure.aboutBalance
        #if DEBUG
        case .testMoney: Disclosure.testMoney
        #endif
        }
    }
}

/// About and legal (B5.8): the version, then the two disclosures as plain
/// rows on the page, split by one divider. No group labels, no licences (the
/// app bundles no fonts, founder decision 1).
struct AboutView: View {
    let services: AppServices

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // One static element, "Version, 0.1.0 (1)" (tested).
                SettingsValueRow(title: "Version", value: services.buildInfo.displayVersion)
                    .accessibilityIdentifier("account.about.version")

                SettingsGroupDivider(textColumnX: Spacing.screenGutter)

                ForEach(AccountDisclosure.allCases, id: \.self) { disclosure in
                    NavigationLink(value: AccountRoute.disclosure(disclosure)) {
                        SettingsRowLabel(symbol: nil, title: disclosure.title)
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityIdentifier("account.about.disclosure.\(disclosure.rawValue)")
                }
            }
            .padding(.top, AccountLayout.pushedTop)
            .padding(.bottom, Spacing.space6)
        }
        .moolaCanvas()
        .navigationTitle("About and legal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One disclosure's full text (B5.9): plain `body` paragraphs on the page,
/// 16 pt below the bar; the inline title names it.
struct DisclosureDetailView: View {
    let disclosure: AccountDisclosure

    var body: some View {
        ScrollView {
            Text(disclosure.text)
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, AccountLayout.pushedTop)
                .padding(.bottom, Spacing.space6)
                .accessibilityIdentifier("account.disclosure.text")
        }
        .moolaCanvas()
        .navigationTitle(disclosure.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG
#Preview("Disclosure") {
    NavigationStack {
        DisclosureDetailView(disclosure: .aboutBalance)
    }
}
#endif
