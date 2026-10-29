#if DEBUG
import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Debug builds only: every DesignSystem component (DESIGN.md v2 Part A) with
/// specimen values, in the current appearance and text size, so the restyle
/// can be reviewed on a simulator (Developer settings → Design specimen).
/// Nothing here is account data and nothing here is reachable in Release.
struct DesignSpecimenView: View {
    let services: AppServices
    @State private var toggleOn = true
    @State private var name = ""
    @State private var filled = "Emergency fund"
    @State private var password = "password"
    @State private var code = ""
    @State private var buffer = AmountEntryBuffer(text: "25")
    @State private var selectedIcon: GoalIcon = .travel
    @FocusState private var codeFocused: Bool
    /// The account's newest moves (live `GET /activity`), to open real Activity receipts (B2.7).
    @State private var recentMoves: [ActivityItem] = []
    @State private var recentMovesError: String?
    @State private var receiptItem: ActivityItem?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let deadline = Date(timeIntervalSince1970: 1_808_870_400) // 2027-04-21 UTC

    private var fund: GoalCardModel {
        GoalCardModel(
            id: "s1", name: "Emergency fund", emoji: GoalIcon.emergencyFund.emoji, colorKey: GoalIcon.apiColor,
            saved: Money(cents: 125_000), target: Money(cents: 300_000), pace: .onTrack, deadline: Self.deadline
        )
    }

    private var trip: GoalCardModel {
        GoalCardModel(
            id: "s2", name: "Trip to Accra", emoji: GoalIcon.travel.emoji, colorKey: GoalIcon.apiColor,
            saved: Money(cents: 38_000), target: Money(cents: 120_000), pace: .behind(periods: 2, frequency: .weekly),
            deadline: Self.deadline
        )
    }

    private var laptop: GoalCardModel {
        GoalCardModel(
            id: "s3", name: "Laptop", emoji: nil, colorKey: nil,
            saved: Money(cents: 0), target: Money(cents: 90_000), pace: .onTrack, deadline: Self.deadline, figureState: .unknown
        )
    }

    private var susu: GroupCardModel {
        GroupCardModel(
            id: "g1", name: "Family susu", kind: .takeTurns, status: .active, frequency: .monthly,
            contribution: Money(cents: 10_000), payout: Money(cents: 40_000), memberCount: 4, targetMembers: 4,
            currentRound: 3, totalRounds: 4, myPayoutRound: 4
        )
    }

    private var forming: GroupCardModel {
        GroupCardModel(
            id: "g2", name: "Wedding fund", kind: .saveTogether, status: .forming, frequency: .biweekly,
            contribution: Money(cents: 5_000), payout: Money(cents: 30_000), memberCount: 1, targetMembers: 2,
            currentRound: 0, totalRounds: 6, myPayoutRound: nil
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GreetingHeader("Good to see you, Ama", detail: "Updated 5 min ago")
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    Text("Specimen values, not account data.")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
                group("Shell screens", padsHeader: true) { shellScreens }
                    .padding(.top, Spacing.sectionGap)
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    group("Type") { typeScale }
                    group("Colour") { swatches }
                    group("Balance") { balance }
                    group("Buttons") { buttons }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.sectionGap)
                group("Goals", padsHeader: true) { goals }
                    .padding(.top, Spacing.sectionGap)
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    group("Emoji tiles") { emoji }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.sectionGap)
                group("Groups", padsHeader: true) { groups }
                    .padding(.top, Spacing.sectionGap)
                group("Identity", padsHeader: true) { identity }
                    .padding(.top, Spacing.sectionGap)
                group("Activity", padsHeader: true) { activity }
                    .padding(.top, Spacing.sectionGap)
                group("Activity receipt", padsHeader: true) { liveReceipts }
                    .padding(.top, Spacing.sectionGap)
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    group("Review and receipt") { review }
                    group("Fields") { fields }
                    group("Feedback") { feedback }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.sectionGap)
                group("Settings rows", padsHeader: true) { settings }
                    .padding(.top, Spacing.sectionGap)
                VStack(alignment: .leading, spacing: Spacing.sectionGap) {
                    group("States") { states }
                    group("Amount entry") {
                        AmountEntry(
                            buffer: $buffer,
                            context: "Available $1,480.76",
                            presets: [
                                AmountPreset(label: "Next step $17.85", money: Money(cents: 1_785), isSuggested: true),
                                .amount(Money(cents: 1_000)), .amount(Money(cents: 2_500)), .amount(Money(cents: 5_000)),
                                AmountPreset(label: "All", money: Money(cents: 148_076)),
                            ],
                            maximum: Money(cents: 148_076),
                            validationMessage: "You don't have enough available for that. Add money or choose a smaller amount."
                        )
                    }
                    Text("End of specimen")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityIdentifier("specimen.end")
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.sectionGap)
                .padding(.bottom, Spacing.space10)
            }
        }
        .accessibilityIdentifier("specimen.scroll")
        .moolaCanvas()
        .navigationTitle("Design specimen")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A section; full-width sections (rows that carry their own gutter) pad only the header.
    private func group<Content: View>(_ title: String, padsHeader: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Spacing.headingToContent) {
            SectionHeader(title)
                .padding(.horizontal, padsHeader ? Spacing.screenGutter : 0)
            content()
        }
    }

    private var isAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    /// The root-gate screens, pushed here so they can be reviewed without
    /// breaking the session (B1.1, B1.2, B1.7, B1.8). "Try again" on the
    /// pushed Restore failed screen would re-run the real session check.
    private var shellScreens: some View {
        VStack(spacing: 0) {
            NavigationLink { LaunchView() } label: { SettingsRowLabel(symbol: nil, title: "Launch") }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("specimen.shell.launch")
            NavigationLink { PrivacyCover() } label: { SettingsRowLabel(symbol: nil, title: "Privacy cover") }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("specimen.shell.privacy")
            NavigationLink {
                RestoreFailedView(services: services, error: .notConnected)
            } label: { SettingsRowLabel(symbol: nil, title: "Restore failed") }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("specimen.shell.restoreFailed")
            NavigationLink { NotConfiguredView() } label: { SettingsRowLabel(symbol: nil, title: "Not configured") }
                .buttonStyle(RowButtonStyle())
                .accessibilityIdentifier("specimen.shell.notConfigured")
        }
    }

    // MARK: Tokens

    private var typeScale: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(TypeToken.allCases, id: \.self) { token in
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    Text(token.isFigure ? "$3,020.12" : "Emergency fund")
                        .textStyle(token)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                    Text("\(String(describing: token)) \(Int(token.size))")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        }
    }

    private var swatches: some View {
        var tokens: [(String, Color)] = [
            ("canvas", Palette.canvas), ("headerBand", Palette.headerBand), ("surface", Palette.surface),
            ("fill", Palette.fill), ("fillPressed", Palette.fillPressed), ("selectionPill", Palette.selectionPill),
            ("divider", Palette.divider),
            ("cardBorder", Palette.cardBorder), ("controlBorder", Palette.controlBorder), ("chevron", Palette.chevron),
            ("textPrimary", Palette.textPrimary), ("textSecondary", Palette.textSecondary), ("textTertiary", Palette.textTertiary),
            ("ctaBackground", Palette.ctaBackground), ("ctaPressed", Palette.ctaPressed), ("ctaDisabled", Palette.ctaDisabledBackground),
            ("jadeText", Palette.jadeText), ("jadeFill", Palette.jadeFill), ("jadeTint", Palette.jadeTint),
            ("amberText", Palette.amberText), ("amberTint", Palette.amberTint), ("redText", Palette.redText),
            ("redTint", Palette.redTint), ("progressTrack", Palette.progressTrack), ("sheetCanvas", Palette.sheetCanvas),
            ("bandRaised", Palette.bandRaised), ("bandRaisedNeutral", Palette.bandRaisedNeutral),
        ]
        tokens += IdentityTint.allCases.map { tint in ("identity \(String(describing: tint))", tint.color) }
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.space2), count: 3), spacing: Spacing.space2) {
            ForEach(tokens, id: \.0) { token in
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                        .fill(token.1)
                        .frame(height: 36)
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
                                .strokeBorder(Palette.cardBorder, lineWidth: Size.hairline)
                        }
                    Text(token.0)
                        .textStyle(.footnoteEmphasis)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
    }

    // MARK: Components

    private var balance: some View {
        VStack(alignment: .leading, spacing: Spacing.space10) {
            BalanceCard(
                state: .loaded(.init(
                    total: Money(cents: 302_012), available: Money(cents: 148_076),
                    inGoals: Money(cents: 153_936), pending: Money(cents: 2_500)
                )),
                actions: .init(addMoney: {}, moveToGoal: {}, cashOut: {}, history: {})
            )
            DisclosureFooter()
            BalanceCard(state: .loading, actions: .init(addMoney: {}, moveToGoal: {}, cashOut: {}, history: {}))
        }
    }

    private var buttons: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            MoolaButton("Review") {}
            MoolaButton("Confirm with Face ID", systemImage: "faceid") {}
            MoolaButton("Confirm with Face ID", systemImage: "faceid", loadingTitle: "Confirming\u{2026}", isLoading: true) {}
            VStack(spacing: Spacing.space2) {
                MoolaButton("Create goal") {}.disabled(true)
                DisabledReasonLine(text: "Add a goal name and a target amount to continue.")
            }
            MoolaButton("Move to balance", kind: .secondary) {}
            MoolaButton("Delete goal", kind: .destructive) {}
            let pair = isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Spacing.space3))
                : AnyLayout(HStackLayout(spacing: Spacing.space3))
            pair {
                MoolaButton("Accept", size: .small, fillsWidth: true) {}
                MoolaButton("Decline", kind: .secondary, size: .small, fillsWidth: true) {}
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.space6) {
                    TextLinkButton("Cash out", systemImage: "arrow.up.right") {}
                    TextLinkButton("History", systemImage: "list.bullet.rectangle.portrait") {}
                }
                VStack(alignment: .leading, spacing: 0) {
                    TextLinkButton("Cash out", systemImage: "arrow.up.right") {}
                    TextLinkButton("History", systemImage: "list.bullet.rectangle.portrait") {}
                }
            }
            TextLinkButton("Edit amount") {}
        }
    }

    private var goals: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your goals", actionTitle: "See all", actionHint: "Opens Savings.") {}
                .padding(.horizontal, Spacing.screenGutter)
            VStack(spacing: 0) {
                Button {} label: { GoalCard(fund, layout: .row) }.buttonStyle(RowButtonStyle())
                goalDivider
                Button {} label: { GoalCard(trip, layout: .row) }.buttonStyle(RowButtonStyle())
                goalDivider
                Button {} label: { GoalCard(laptop, layout: .row) }.buttonStyle(RowButtonStyle())
            }
            .padding(.top, Spacing.space1)
            let tiles = isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Spacing.gridGap))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.gridGap))
            tiles {
                Button {} label: { GoalCard(fund) }.buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))
                Button {} label: { GoalCard(trip) }.buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.space8)
            IdentityBand(tint: GoalTint.color(forAPIKey: fund.colorKey)) {
                GoalCard(fund, layout: .detail, dateLine: "Target date Apr 21, 2027 \u{00B7} 77 weeks left")
                    .padding(.top, Spacing.space4)
            }
            .padding(.top, Spacing.space8)
        }
    }

    private var goalDivider: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: Size.hairline)
            .padding(.leading, 80)
            .padding(.trailing, Spacing.screenGutter)
    }

    private var emoji: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            ChipFlowLayout(spacing: Spacing.space3) {
                EmojiTile(emoji: GoalIcon.goal.emoji, colorKey: GoalIcon.apiColor, fallbackName: nil, size: .s32)
                EmojiTile(emoji: GoalIcon.emergencyFund.emoji, colorKey: GoalIcon.apiColor, fallbackName: nil, size: .s52)
                EmojiTile(emoji: GoalIcon.pets.emoji, colorKey: GoalIcon.apiColor, fallbackName: nil, size: .s56)
                EmojiTile(emoji: GoalIcon.tech.emoji, colorKey: GoalIcon.apiColor, fallbackName: nil, size: .s72)
                EmojiTile(emoji: nil, colorKey: nil, fallbackName: "Laptop", size: .s52)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.gridGap), count: isAccessibilitySize ? 3 : 4), spacing: Spacing.gridGap) {
                ForEach(GoalIcon.allCases, id: \.self) { icon in
                    EmojiPickerCell(
                        emoji: icon.emoji, label: icon.label, identifier: "specimen.icon.\(icon.rawValue)",
                        isSelected: icon == selectedIcon
                    ) { selectedIcon = icon }
                }
            }
            .sensoryFeedback(.selection, trigger: selectedIcon)
        }
    }

    private var groups: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            VStack(spacing: Spacing.gridGap) {
                Button {} label: { GroupCard(susu) }.buttonStyle(PressableCardButtonStyle(restingFill: Palette.canvas))
                Button {} label: { GroupCard(forming) }.buttonStyle(PressableCardButtonStyle(restingFill: Palette.canvas))
                InviteCard(circleName: "Office savers", inviterName: "Esi", contribution: Money(cents: 2_500), frequency: .weekly, onAccept: {}, onDecline: {})
            }
            .padding(.horizontal, Spacing.screenGutter)
            // One group's people in distinct colours (A1.9): the stack and the rows agree.
            VStack(alignment: .leading, spacing: Spacing.space4) {
                AvatarStack(names: ["kofi", "esi", "yaw", "ama", nil, "abena"])
                    .padding(.horizontal, Spacing.screenGutter)
                VStack(alignment: .leading, spacing: 0) {
                    SectionHeader("Members", count: 3)
                        .padding(.horizontal, Spacing.screenGutter)
                        .padding(.bottom, Spacing.space1)
                    MemberRow(name: "ama", isUnnamed: false, isYou: true, kind: .takeTurns, payoutState: .upcoming, payoutRound: 4, isGroupActive: true, contributedThisRound: true)
                    MemberRow(name: "kofi", isUnnamed: false, isYou: false, kind: .takeTurns, payoutState: .paid, payoutRound: 1, isGroupActive: true, contributedThisRound: true)
                    MemberRow(name: "Member", isUnnamed: true, isYou: false, kind: .takeTurns, payoutState: .paid, payoutRound: 1, isGroupActive: true, contributedThisRound: false)
                }
            }
            .identityTints(forKeys: ["kofi", "esi", "yaw", "ama", "abena"])
            RoundTimeline(entries: [
                .init(round: 1, name: "kofi", isUnnamed: false, state: .paid, isYou: false),
                .init(round: 2, name: "esi", isUnnamed: false, state: .paid, isYou: false),
                .init(round: 3, name: "ama", isUnnamed: false, state: .current, isYou: true),
                .init(round: 4, name: "yaw", isUnnamed: false, state: .upcoming, isYou: false),
            ], currentRound: 3)
            VStack(alignment: .leading, spacing: Spacing.space3) {
                SaveTogetherProgress(currentRound: 4, totalRounds: 6, isCompleted: false)
                ChoiceCard(title: "Take turns", description: "Everyone pays in each round and one person receives the pot.", isSelected: true) {}
                ChoiceCard(title: "Save together", description: "Everyone pays in each round and gets their own savings back at the end.", isSelected: false) {}
            }
            .padding(.horizontal, Spacing.screenGutter)
        }
    }

    /// Premium bar P5 and P8 (DESIGN.md Part K): the person raised on a card,
    /// the neutral avatar, and the ruling 55 identity tiles in every tint.
    private var identity: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Button {} label: {
                PersonCardLabel(name: "Ama Owusu", username: "ama", email: "ama@moolahub.test", avatarName: "AO", identityKey: "ama")
            }
            .buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))
            HStack(spacing: Spacing.space3) {
                AvatarView(name: "AO", size: 64)
                AvatarView(name: nil, size: 64)
                ForEach(["esi", "abena"], id: \.self) { name in
                    AvatarView(name: name, identityKey: name)
                }
            }
            HStack(spacing: Spacing.space3) {
                ForEach(IdentityTint.allCases, id: \.self) { tint in
                    IdentityTile(systemImage: "creditcard", tint: tint)
                }
            }
            HStack(spacing: Spacing.space3) {
                ForEach(IdentityTint.allCases, id: \.self) { tint in
                    IdentityTile(systemImage: "creditcard", tint: tint, size: .identity)
                }
            }
            // In a row: the tile takes the symbol media column, the title stays at x = 52.
            HStack(spacing: Spacing.space3) {
                IdentityTile(systemImage: "creditcard", tint: .ocean)
                Text("A row with an identity tile")
                    .textStyle(.headline)
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .padding(.horizontal, Spacing.screenGutter)
    }

    private var activity: some View {
        VStack(spacing: 0) {
            ActivityRow(kind: .deposit, title: "Test money added", subtitle: "5:00 PM", amount: Money(cents: 10_000), status: .done) {}
            ActivityRow(kind: .goalAllocate, title: "Moved to Emergency fund", subtitle: "4:12 PM", amount: Money(cents: -5_000), status: .processing) {}
            ActivityRow(kind: .contribution, title: "Family susu \u{00B7} round 3", subtitle: "Yesterday", amount: Money(cents: -10_000), status: .failed) {}
            ActivityRow(kind: .goalRelease, title: "Moved from Trip to Accra", subtitle: "Sat, Oct 24", amount: Money(cents: 2_000), status: .done, symbol: nil) {}
            ActivityRow(kind: .contribution, title: "Round 1", subtitle: "Oct 12 at 2:05 PM", amount: Money(cents: -2_040), status: .done, symbol: nil, labelStyle: .titleFirst)
        }
    }

    /// The signed-in account's three newest moves (real data, `GET /activity`);
    /// each row opens its receipt through the app-level sheet path
    /// (`AppSheet.activityReceipt`, B2.7), as Activity and Home rows will.
    private var liveReceipts: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recentMovesError {
                ErrorBanner(recentMovesError)
                    .padding(.horizontal, Spacing.screenGutter)
            } else if recentMoves.isEmpty {
                Text("No activity on this account yet.")
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Spacing.screenGutter)
            }
            ForEach(recentMoves) { item in
                ActivityRow(item) { receiptItem = item }
                    .accessibilityIdentifier("specimen.receipt.\(item.id)")
            }
        }
        .task { await loadRecentMoves() }
        .sheet(item: $receiptItem) { item in
            services.navigator.sheetView(for: .activityReceipt(item))
        }
    }

    private func loadRecentMoves() async {
        do throws(APIError) {
            recentMoves = Array(try await services.api.send(API.Activity.list(limit: 3)).prefix(3))
            recentMovesError = nil
        } catch {
            recentMovesError = error.message(for: .screen)
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            HStack(spacing: Spacing.space8) {
                ReceiptSymbol(status: .processing)
                ReceiptSymbol(status: .done)
                ReceiptSymbol(status: .failed)
            }
            .frame(maxWidth: .infinity)
            VStack(spacing: 0) {
                DetailRowView(DetailRow("From", .text("Balance")))
                DetailRowView(DetailRow("To", .goal(name: "Emergency fund", emoji: GoalIcon.emergencyFund.emoji, colorKey: GoalIcon.apiColor)))
                DetailRowView(DetailRow("Fee", .fee(.zero)))
                DetailRowView(DetailRow("Amount", .money(Money(cents: 5_000))))
                DetailRowView(DetailRow("Status", .status(.done)))
            }
            ChipFlowLayout(spacing: Spacing.space2) {
                StatusPill(status: .done)
                StatusPill(status: .processing)
                StatusPill(status: .failed)
                StatusPill("Invited", tone: .neutral)
            }
            VStack(alignment: .leading, spacing: Spacing.space1) {
                PaceText(.onTrack, percentText: "41%")
                PaceText(.behind(periods: 2, frequency: .weekly), percentText: "31%")
                PaceText(.reached, percentText: "100%")
                PaceText(.pastTargetDate, mayBeOutOfDate: true, percentText: "0%")
            }
            ProgressBar(fraction: 0.41)
            ProgressBar(fraction: 0.75, height: 6)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: Spacing.fieldToNextLabel) {
            MoolaTextField("Legal name \u{00B7} private", text: $name, placeholder: "e.g. Ama Mensah")
            MoolaTextField("Goal name", text: $filled, hint: "\(filled.count)/40")
            MoolaTextField("Password", text: $password, error: "Password must be at least 8 characters.", isSecure: true)
            PickerField(label: "Target amount", value: nil, placeholder: "$0") {}
            PickerField(label: "Date of birth", value: "Apr 21, 1993", placeholder: "Choose a date", trailingSymbol: "calendar") {}
            ReadOnlyField(label: "Email", value: "ama@moolahub.test") { StatusPill("Verified", tone: .jade) }
            CodeField(code: $code, accessibilityLabel: "Verification code", identifier: "specimen.code", error: nil, isFocused: $codeFocused)
            ChipFlowLayout(spacing: Spacing.space2) {
                RemovableChip(text: "kofi@moolahub.test") {}
                RemovableChip(text: "esi@moolahub.test") {}
            }
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            ErrorBanner("You don't have enough available for that.", title: "Didn't go through. Nothing was taken.")
            ErrorBanner("We couldn't confirm this move. Check Activity before you try again.", retryTitle: "View activity") {}
            NoticeBanner("You've been signed out. Please sign in again.", tone: .neutral)
            NoticeBanner("Your password has been reset. Sign in with your new password.", tone: .jade)
            NoticeBanner("This is a test version of MoolaHub. Test money isn't real and can't be cashed out.", title: "Test money", systemImage: "testtube.2", tone: .amber)
            Toast("Goal created.")
                .frame(maxWidth: .infinity)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(symbol: "person.text.rectangle", title: "Profile") {}
            SettingsRow(symbol: "lock.shield", title: "Security") {}
            SettingsGroupDivider()
            SettingsRow(symbol: "wrench.and.screwdriver", title: "Technical details", value: "Off") {}
            SettingsValueRow(title: "Version", value: "0.1.0 (1)")
            SettingsGroupDivider(textColumnX: Spacing.screenGutter)
            SettingsToggleRow(symbol: "faceid", title: "Lock with Face ID", isOn: $toggleOn)
            SettingsGroupFootnote("MoolaHub asks for Face ID when you open it, and after a minute in the background.", textColumnX: 52)
            SettingsSelectableRow(title: "Everything", subtitle: "All notifications: group activity, goal milestones, money added, reminders and tips.", badge: "Recommended", isSelected: true) {}
            SettingsSelectableRow(title: "Essential", subtitle: "Important updates only, like payouts, pay-in due dates and account activity.", isSelected: false) {}
            SettingsGroupDivider()
            SettingsRow(symbol: "rectangle.portrait.and.arrow.right", title: "Sign out", tone: .destructive) {}
            VStack(spacing: 0) {
                TechnicalDetailsRow(label: "Network", value: "Specimen network")
                TechnicalDetailsRow(label: "Account address", value: nil)
            }
            .padding(.horizontal, Spacing.screenGutter)
        }
    }

    private var states: some View {
        VStack(alignment: .leading, spacing: Spacing.space10) {
            EmptyState(title: "No goals yet", message: "Set a target and a date. We'll track your progress.", actionTitle: "Create goal") {}
            ErrorState(title: "We couldn't load your goals", message: "We couldn't reach MoolaHub. Check your connection and try again.") {}
            LoadingPlaceholder(label: "Loading your goals\u{2026}") {
                SkeletonCard()
            }
        }
    }
}
#endif
