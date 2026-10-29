import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Technical details (DESIGN.md v2 B5.7, B5.13; account.md B5.7 amended): a
/// device setting, off by default. Only when it's on does this screen call
/// `GET /wallet` and show the network and the account address in
/// `TechnicalDetailsRow`s, and, whenever the address shows with its Copy
/// button, the send-only warning under the footnote. One of the four files
/// where crypto words may appear (W3; CopyCheckTests allow-list).
struct TechnicalDetailsView: View {
    let services: AppServices
    @State private var wallet: RemoteResource<WalletInfo>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices) {
        self.services = services
        let api = services.api
        _wallet = State(initialValue: RemoteResource {
            try await api.send(API.Wallet.info())
        })
    }

    private var isOn: Bool { services.settings.showTechnicalDetails }

    /// The "on" block inserts with opacity and `Motion.standard` and leaves
    /// with `Motion.exit`; Reduce Motion: the reduced cross-fade (B5.7).
    private var detailsTransition: AnyTransition {
        if reduceMotion {
            return .opacity.animation(Motion.reducedCrossfade)
        }
        return .asymmetric(
            insertion: .opacity.animation(Motion.standard),
            removal: .opacity.animation(Motion.exit)
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsToggleRow(title: "Show technical details", isOn: Binding(
                    get: { services.settings.showTechnicalDetails },
                    set: { value in
                        withAnimation(Motion.animation(Motion.standard, reduceMotion: reduceMotion)) {
                            services.settings.showTechnicalDetails = value
                        }
                    }
                ))
                .accessibilityIdentifier("account.technical.toggle")

                SettingsGroupFootnote("Shows network names, account addresses and contract details across the app. You never need this to use MoolaHub. This choice is saved on this device.")

                if isOn {
                    details
                        .transition(detailsTransition)
                }
            }
            .padding(.top, AccountLayout.pushedTop)
            .padding(.bottom, Spacing.space6)
        }
        .moolaCanvas()
        .navigationTitle("Technical details")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: isOn) {
            if isOn { await wallet.load() }
        }
    }

    /// Divider, "Your account", the two values (or their skeleton, or the
    /// error in their place), then the USDC footnote, which always stays.
    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsGroupDivider(textColumnX: Spacing.screenGutter)
            SettingsGroupLabel("Your account")

            switch wallet.phase {
            case .loading:
                LoadingPlaceholder(label: "Loading technical details\u{2026}") {
                    VStack(alignment: .leading, spacing: 0) {
                        loadingRow("Network", widthFraction: 0.4)
                        loadingRow("Account address", widthFraction: 0.8)
                    }
                }
            case .failed(let error):
                walletError(error)
            case .loaded:
                if let error = wallet.error {
                    // Refresh failed with data: the rows stay, the banner says so.
                    walletError(error)
                        .padding(.bottom, Spacing.space3)
                }
                if let info = wallet.value {
                    TechnicalDetailsRow(label: "Network", value: info.network)
                        .padding(.horizontal, Spacing.screenGutter)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("account.technical.network")
                    addressRow(info.address)
                }
            }

            SettingsGroupFootnote("Your balance is held as USDC, a US-dollar digital currency.")

            if case .loaded = wallet.phase, let info = wallet.value,
               SendWarningRule.showsSendWarning(address: info.address) {
                sendWarning(syncEnabled: info.syncEnabled)
                    .padding(.top, Spacing.space4)
            }
        }
    }

    /// The account address with Copy only when `SendWarningRule` shows the
    /// warning too (A12, AC-25: no Copy without the warning). A VoiceOver user
    /// meets Copy before the warning, so Copy carries W10.8-acc2 as its hint
    /// (account.md B5.7 amended).
    @ViewBuilder
    private func addressRow(_ address: String?) -> some View {
        if SendWarningRule.showsSendWarning(address: address) {
            TechnicalDetailsRow(
                label: "Account address", value: address,
                copyHint: "See the note below before you send money here."
            )
            .padding(.horizontal, Spacing.screenGutter)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("account.technical.address")
        } else {
            TechnicalDetailsRow(label: "Account address", value: nil)
                .padding(.horizontal, Spacing.screenGutter)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("account.technical.address")
        }
    }

    /// The send-only warning (A12, W10.3-acc4 to acc6): an amber NoticeBanner
    /// 16 pt under the footnote, its third sentence only while deposits to
    /// this address are not added to the balance (`syncEnabled == false`).
    private func sendWarning(syncEnabled: Bool) -> some View {
        var message = "Only send USDC on the network shown above. Anything else may be lost."
        if SendWarningRule.includesNotAddedSentence(syncEnabled: syncEnabled) {
            message += " Money sent here isn't added to your balance yet."
        }
        return NoticeBanner(message, title: "Sending to this address", tone: .amber)
            .accessibilityIdentifier("account.technical.sendWarning")
            .padding(.horizontal, Spacing.screenGutter)
    }

    private func walletError(_ error: APIError) -> some View {
        ErrorBanner(error.message(for: .screen)) {
            Task { await wallet.refresh() }
        }
        .accessibilityIdentifier("account.technical.error")
        .padding(.horizontal, Spacing.screenGutter)
    }

    /// A row while `GET /wallet` loads (B5.7): the label at once, the value a
    /// bar at the `body` cap height, no Copy; the same 68 pt as a loaded row.
    private func loadingRow(_ label: String, widthFraction: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(label)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            SkeletonTextLine(.body, leading: widthFraction)
        }
        .padding(.vertical, Spacing.space3)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .bottomLeading)
        .padding(.horizontal, Spacing.screenGutter)
    }
}
