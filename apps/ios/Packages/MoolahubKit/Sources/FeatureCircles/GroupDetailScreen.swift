import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Group detail (DESIGN.md v2 B4.13 to B4.23): the identity band (members
/// stack, status line, payout figure on `headerBand`), the facts and the one
/// action, then Build your group (forming), Payout order or Progress,
/// Members, Your pay-ins and Technical details. No containers: the band is a
/// ground, everything else sits on the page.
struct GroupDetailScreen: View {
    private let services: AppServices
    private let groupID: String

    @State private var detail: RemoteResource<CircleDetail>
    @State private var hasLoaded = false
    @State private var toast: String?
    @State private var payInGroup: CircleDetail?
    @State private var showsInvite = false
    @State private var confirmsStart = false
    @State private var confirmsDelete = false
    @State private var isStarting = false
    @State private var isDeleting = false
    @State private var actionError: String?
    @State private var failureTick = 0
    @State private var deleteTick = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices, groupID: String) {
        self.services = services
        self.groupID = groupID
        let api = services.api
        _detail = State(initialValue: RemoteResource(cacheKey: .group(groupID), cache: services.cache) {
            try await api.send(API.Groups.get(groupID))
        })
    }

    /// The band shows while loading and once loaded; never-loaded and
    /// not-found states sit on `canvas` (there is no group to identify).
    private var showsBand: Bool {
        switch detail.phase {
        case .loading, .loaded: true
        case .failed: false
        }
    }

    var body: some View {
        ScrollView {
            content
        }
        .modifier(IdentityBandScreen(tint: showsBand ? Palette.headerBand : Palette.canvas))
        .accessibilityIdentifier("groups.detail")
        .navigationTitle(detail.value?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if detail.value?.canDelete == true {
                ToolbarItem(placement: .primaryAction) {
                    moreMenu
                }
            }
        }
        .refreshable { await detail.refresh() }
        .task {
            if let message = GroupsToastCenter.shared.take(for: .detail(groupID)) {
                toast = message
            }
            if hasLoaded {
                await detail.refresh()
            } else {
                hasLoaded = true
                await detail.load()
            }
        }
        .toast($toast)
        .sheet(item: $payInGroup, onDismiss: refreshAfterAction) { group in
            PayInSheet(services: services, group: group)
        }
        .sheet(isPresented: $showsInvite, onDismiss: refreshAfterAction) {
            InviteSheet(services: services, groupID: groupID, detail: detail)
        }
        .sensoryFeedback(.error, trigger: failureTick)
        .sensoryFeedback(.impact(weight: .heavy), trigger: deleteTick)
    }

    private var moreMenu: some View {
        Menu {
            Button("Delete group", systemImage: "trash", role: .destructive) {
                confirmsDelete = true
            }
            // Icon and title in the system's one destructive red.
            .tint(Palette.systemDestructive)
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .disabled(isDeleting)
        .accessibilityIdentifier("groups.detail.menu")
        // B4.22: attached to the menu, so the iOS 26 popover points at "More".
        .confirmationDialog("Delete this group?", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete group", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the group and any pending invites.")
        }
    }

    private func refreshAfterAction() {
        Task { await detail.refresh() }
    }

    private var stateAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    // MARK: States (B4.23)

    @ViewBuilder
    private var content: some View {
        switch detail.phase {
        case .loading:
            loadingView
        case .failed(let error):
            if error.status == 404 {
                ErrorState(
                    title: GroupsCopy.notFound,
                    message: nil,
                    retryTitle: GroupsCopy.backToGroups,
                    retryKind: .primary
                ) {
                    services.navigator.select(.groups)
                    services.navigator.popToRoot()
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
            } else {
                ErrorState(
                    title: GroupsCopy.detailErrorTitle,
                    message: error.message(for: .screen),
                    isRetrying: detail.isLoading
                ) {
                    Task { await detail.refresh() }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.top, Spacing.space6)
            }
        case .loaded:
            if let group = detail.value {
                loaded(group)
            }
        }
    }

    /// Loading (B4.23): the band as loaded with the stack, status, label and
    /// figure as blocks; then three fact rows, the action and a header.
    private var loadingView: some View {
        LoadingPlaceholder(label: GroupsCopy.loadingGroup) {
            VStack(alignment: .leading, spacing: 0) {
                IdentityBand(tint: Palette.headerBand) {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: -10) {
                            ForEach(0..<4, id: \.self) { _ in
                                SkeletonBlock(width: 32, height: 32, cornerRadius: 16)
                                    .padding(2)
                                    .background(Circle().fill(Palette.canvas))
                            }
                        }
                        .padding(.top, Spacing.space4)
                        SkeletonTextLine(.subheadline, leading: 0.5)
                            .padding(.top, Spacing.space4)
                        SkeletonTextLine(.subheadline, leading: 0.35)
                            .padding(.top, Spacing.space4)
                        SkeletonTextLine(.displayAmount, leading: 0.5)
                            .padding(.top, Spacing.space1)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<3, id: \.self) { _ in
                            ZStack {
                                SkeletonTextLine(.body, leading: 0.4)
                                SkeletonTextLine(.body, trailing: 0.2)
                            }
                            .padding(.vertical, Spacing.space2)
                            .frame(minHeight: 48)
                        }
                    }
                    .padding(.top, Spacing.space4)
                    SkeletonBar(widthFraction: 1, height: Size.buttonHeight, radius: Radius.control)
                        .padding(.top, Spacing.space6)
                    SkeletonTextLine(.title3, leading: 0.35)
                        .padding(.top, Spacing.sectionGap)
                }
                .padding(.horizontal, Spacing.screenGutter)
                .padding(.bottom, Spacing.space8)
                .modifier(BelowIdentityBand())
            }
        }
    }

    // MARK: Loaded (B4.13)

    private func loaded(_ group: CircleDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            IdentityBand(tint: Palette.headerBand) {
                identity(group)
            }
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    facts(group)
                        .padding(.top, Spacing.space4)
                    if !group.feeRate.isZero {
                        Text(GroupsCopy.feeNote(group.feeRate))
                            .textStyle(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("groups.detail.feeNote")
                            .padding(.top, Spacing.space2)
                    }
                    if let action = mainAction(group) {
                        mainActionView(action, group: group)
                            .padding(.top, Spacing.space6)
                    }
                }
                .padding(.horizontal, Spacing.screenGutter)
                .animation(stateAnimation, value: mainAction(group))

                if group.groupStatus == .forming {
                    buildYourGroup(group)
                        .padding(.top, Spacing.sectionGap)
                }
                switch group.kind {
                case .takeTurns:
                    payoutOrder(group)
                        .padding(.top, Spacing.sectionGap)
                case .saveTogether:
                    if group.groupStatus != .forming {
                        progress(group)
                            .padding(.top, Spacing.sectionGap)
                    }
                }
                members(group)
                    .padding(.top, Spacing.sectionGap)
                payIns(group)
                    .padding(.top, Spacing.sectionGap)
                if showsContract(group), let address = group.contractAddress {
                    technicalDetails(address)
                        .padding(.top, Spacing.sectionGap)
                }
            }
            .padding(.bottom, Spacing.space8)
            .modifier(BelowIdentityBand())
        }
    }

    private var hasStatusBlock: Bool {
        detail.error != nil || actionError != nil || detail.updatedText() != nil
    }

    /// The identity block (A8.32): status block when needed, the members
    /// stack, the status line and the payout figure, the screen's one hero.
    private func identity(_ group: CircleDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if hasStatusBlock {
                statusBlock
                    .padding(.top, Spacing.space4)
            }
            AvatarStack(names: stackNames(group))
                .padding(.top, hasStatusBlock ? Spacing.space6 : Spacing.space4)
            Text(GroupsCopy.statusLine(group))
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space4)
            payoutBlock(group)
                .padding(.top, Spacing.space4)
        }
        .animation(stateAnimation, value: hasStatusBlock)
    }

    /// Refresh failed (with "Try again"), an action error (no retry; it clears
    /// on the next action), then the freshness line 8 below (ruling 11).
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if let error = detail.error {
                ErrorBanner(error.message(for: .screen)) {
                    Task { await detail.refresh() }
                }
                .transition(.opacity)
            }
            if let actionError {
                ErrorBanner(actionError)
                    .accessibilityIdentifier("groups.detail.error")
                    .transition(.opacity)
            }
            if let updated = detail.updatedText() {
                Text(updated)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    /// Members in payout order (take turns) or API order (save together);
    /// nil is the API's "Member" (no username).
    private func stackNames(_ group: CircleDetail) -> [String?] {
        let members = group.kind == .takeTurns
            ? group.members.sorted { $0.payoutRound < $1.payoutRound }
            : group.members
        return members.map { $0.isUnnamed ? nil : $0.name }
    }

    private func payoutBlock(_ group: CircleDetail) -> some View {
        let label = GroupsCopy.payoutLabel(group.kind)
        return VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(label)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            MoneyText(group.payout, style: .displayAmount)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(group.payout.accessibilityText())")
        .accessibilityIdentifier("groups.detail.payout")
    }

    /// Facts as `DetailRow`s (A8.17): "You pay in each round", "Your turn"
    /// (take turns), "Round" (active only).
    private func facts(_ group: CircleDetail) -> some View {
        VStack(spacing: 0) {
            DetailRowView(DetailRow("You pay in each round", .money(group.contribution)))
            if group.kind == .takeTurns, let turn = group.myPayoutRound, turn > 0 {
                DetailRowView(DetailRow("Your turn", .text("Round \(turn)")))
            }
            if group.groupStatus == .active {
                DetailRowView(DetailRow("Round", .text("\(group.currentRound) of \(group.totalRounds)")))
                    .accessibilityIdentifier("groups.detail.round")
            }
        }
    }

    // MARK: The one action (B4.13 to B4.16, B4.21)

    private enum MainAction: Hashable {
        case payIn, paid, start, notStarted, finished
    }

    private func mainAction(_ group: CircleDetail) -> MainAction? {
        switch group.groupStatus {
        case .active:
            if group.canContribute == true { return .payIn }
            if group.myContributionStatus == "paid" { return .paid }
            // Can't pay in and not paid: the API gives no reason, and the
            // Members section shows the person's "Not yet" (B4.13).
            return nil
        case .forming:
            if group.isCreator == true {
                return group.canStart == true ? .start : nil
            }
            return .notStarted
        case .completed:
            return .finished
        case .other:
            return nil
        }
    }

    @ViewBuilder
    private func mainActionView(_ action: MainAction, group: CircleDetail) -> some View {
        switch action {
        case .payIn:
            MoolaButton("Pay in \(group.contribution.formatted())") {
                actionError = nil
                payInGroup = group
            }
            .accessibilityIdentifier("groups.detail.payIn")
            .transition(.opacity)
        case .paid:
            StatusPill("Paid in this round", tone: .jade)
                .accessibilityIdentifier("groups.detail.paidIn")
                .transition(.opacity)
        case .start:
            MoolaButton("Start group", loadingTitle: "Starting\u{2026}", isLoading: isStarting) {
                actionError = nil
                confirmsStart = true
            }
            .accessibilityIdentifier("groups.detail.start")
            // B4.27: attached to the button that opens it.
            .confirmationDialog("Start this group?", isPresented: $confirmsStart, titleVisibility: .visible) {
                Button("Start group") { start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Rounds begin now and the payout order is set.")
            }
        case .notStarted:
            Text(GroupsCopy.notStartedYet)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        case .finished:
            Text(GroupsCopy.completedBody(group.kind))
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sections

    /// Build your group (B4.15 creator, B4.16 member).
    private func buildYourGroup(_ group: CircleDetail) -> some View {
        let memberCount = group.memberCount ?? group.members.count
        let pending = group.pendingInvites ?? []
        let showsHint = group.isCreator == true && group.targetMembers == nil && memberCount < 2
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader("Build your group")
                Text(GroupsCopy.formingBody(group))
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("groups.detail.formingBody")
                    .padding(.top, Spacing.headingToContent)
                if group.canInvite == true {
                    MoolaButton("Invite people", kind: .secondary) {
                        actionError = nil
                        showsInvite = true
                    }
                    .accessibilityIdentifier("groups.detail.invite")
                    .padding(.top, Spacing.space4)
                }
            }
            .padding(.horizontal, Spacing.screenGutter)
            if !pending.isEmpty {
                // Display rows with no leading symbol: this screen's media
                // column is the members' (A3.1, B4.15).
                VStack(spacing: 0) {
                    ForEach(pending) { invite in
                        SettingsValueRow(title: invite.email) {
                            StatusPill("Invited", tone: .neutral)
                        }
                        .accessibilityLabel("\(invite.email). Invited.")
                    }
                }
                .padding(.top, Spacing.space2)
            }
            if showsHint {
                Text(GroupsCopy.inviteOneMore)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.space2)
            }
        }
    }

    /// Payout order (B4.17): the timeline is full width (nodes at x 42,
    /// text at x 80) and starts 8 below the header frame.
    private func payoutOrder(_ group: CircleDetail) -> some View {
        let username = services.session.currentUser?.username
        let entries = group.members.map { member in
            RoundTimelineEntry(
                round: member.payoutRound,
                name: member.name,
                isUnnamed: member.isUnnamed,
                state: member.payoutState,
                isYou: member.isCurrentUser(username: username)
            )
        }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Payout order")
                .padding(.horizontal, Spacing.screenGutter)
            RoundTimeline(entries: entries, currentRound: group.currentRound)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("groups.detail.payoutOrder")
                .padding(.top, Spacing.space2)
        }
    }

    /// Save-together progress (B4.18).
    private func progress(_ group: CircleDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Progress")
            SaveTogetherProgress(
                currentRound: group.currentRound,
                totalRounds: group.totalRounds,
                isCompleted: group.groupStatus == .completed
            )
            .accessibilityElement(children: .contain)
            .padding(.top, Spacing.headingToContent)
        }
        .padding(.horizontal, Spacing.screenGutter)
    }

    /// Members (B4.19): 76 pt rows, 52 pt avatars at the gutter, text at x 80,
    /// the "you" highlight; the list starts 4 below the header frame.
    private func members(_ group: CircleDetail) -> some View {
        let username = services.session.currentUser?.username
        let isActive = group.groupStatus == .active
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Members (\(group.members.count))")
                .padding(.horizontal, Spacing.screenGutter)
            VStack(spacing: 0) {
                ForEach(group.members) { member in
                    MemberRow(member: member, kind: group.kind, isGroupActive: isActive, currentUsername: username)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("groups.detail.members")
            .padding(.top, Spacing.headingToContent - Spacing.space3)
        }
    }

    /// Your pay-ins (B4.20): title-first activity rows with no symbol.
    private func payIns(_ group: CircleDetail) -> some View {
        let history = (group.history ?? []).sorted { $0.round < $1.round }
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your pay-ins")
                .padding(.horizontal, Spacing.screenGutter)
            if history.isEmpty {
                Text(GroupsCopy.noPayIns)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.horizontal, Spacing.screenGutter)
                    .padding(.top, Spacing.headingToContent)
            } else {
                VStack(spacing: 0) {
                    ForEach(history) { item in
                        ActivityRow(
                            kind: .contribution,
                            title: "Round \(item.round)",
                            subtitle: MoolaDates.dateAndTime(item.createdAt),
                            amount: item.amount,
                            status: item.moveStatus,
                            symbol: nil,
                            labelStyle: .titleFirst
                        )
                    }
                }
                .padding(.top, Spacing.headingToContent - Spacing.space3)
            }
        }
    }

    private func showsContract(_ group: CircleDetail) -> Bool {
        services.settings.showTechnicalDetails && !(group.contractAddress ?? "").isEmpty
    }

    /// Technical details (B4.20), only with the setting on.
    private func technicalDetails(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Technical details")
            TechnicalDetailsRow(label: "Group contract", value: address)
                .padding(.top, Spacing.headingToContent - Spacing.space3)
        }
        .padding(.horizontal, Spacing.screenGutter)
    }

    // MARK: Actions

    private func start() {
        guard !isStarting else { return }
        isStarting = true
        actionError = nil
        Task {
            do throws(APIError) {
                _ = try await services.api.send(API.Groups.start(groupID: groupID))
                await detail.refresh()
                isStarting = false
            } catch {
                isStarting = false
                guard error != .cancelled, error != .sessionExpired else { return }
                actionError = error.message(for: .action)
                failureTick += 1
                await detail.refresh()
            }
        }
    }

    private func delete() {
        guard !isDeleting else { return }
        isDeleting = true
        actionError = nil
        deleteTick += 1
        Task {
            do throws(APIError) {
                _ = try await services.api.send(API.Groups.delete(groupID: groupID))
                isDeleting = false
                GroupsToastCenter.shared.post("Group deleted.", to: .list)
                services.navigator.select(.groups)
                services.navigator.popToRoot()
            } catch {
                isDeleting = false
                guard error != .cancelled, error != .sessionExpired else { return }
                actionError = error.message(for: .action)
                failureTick += 1
                await detail.refresh()
            }
        }
    }
}
