import APIClient
import Auth
import DesignSystem
import Domain
import Persistence
import SwiftUI

/// Groups tab root (DESIGN.md v2 B4.1 to B4.9): invitations first (outlined
/// cards with Accept and Decline), then your groups (outlined cards, ordered
/// Active, Forming, Completed), then the "How groups work" row. Loading is a
/// skeleton in the final layout, failures stay in the block that failed.
struct GroupsListView: View {
    private let services: AppServices

    @State private var groups: RemoteResource<[CircleSummary]>
    @State private var invites: RemoteResource<[CircleInvite]>
    @State private var hasLoaded = false
    @State private var toast: String?
    @State private var showsHowItWorks = false

    @State private var inviteStates: [String: InviteCard.Phase] = [:]
    /// Invitations answered on this screen: they leave at once (B4.6), before
    /// the reload confirms it.
    @State private var answeredInviteIDs: Set<String> = []
    @State private var pendingAccept: CircleInvite?
    @State private var pendingDecline: CircleInvite?
    @State private var failureTick = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices) {
        self.services = services
        let api = services.api
        _groups = State(initialValue: RemoteResource(cacheKey: .groups, cache: services.cache) {
            try await api.send(API.Groups.list())
        })
        _invites = State(initialValue: RemoteResource(cacheKey: .groupInvites, cache: services.cache) {
            try await api.send(API.Groups.invites())
        })
    }

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, Spacing.space8)
        }
        .accessibilityIdentifier("groups.list")
        .moolaCanvas()
        .navigationTitle("Groups")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Create group", systemImage: "plus") {
                    services.navigator.present(.createGroup)
                }
                .accessibilityIdentifier("groups.createButton")
            }
        }
        .refreshable { await reload() }
        .onAppear {
            if let message = GroupsToastCenter.shared.take(for: .list) {
                toast = message
            }
        }
        .task {
            // Runs on every appearance: first load (cache, then network), and a
            // refresh when coming back from a group or a sheet.
            if hasLoaded {
                await reload()
            } else {
                hasLoaded = true
                async let first: Void = groups.load()
                async let second: Void = invites.load()
                _ = await (first, second)
            }
        }
        .toast($toast)
        .sheet(isPresented: $showsHowItWorks) {
            HowGroupsWorkSheet()
        }
        .sensoryFeedback(.error, trigger: failureTick)
    }

    private func reload() async {
        async let first: Void = groups.refresh()
        async let second: Void = invites.refresh()
        _ = await (first, second)
    }

    private var layoutAnimation: Animation {
        Motion.animation(Motion.standard, reduceMotion: reduceMotion)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch groups.phase {
        case .loading:
            loading
        case .failed(let error):
            // B4.4, never loaded: the error in place of the content.
            ErrorState(
                title: GroupsCopy.listErrorTitle,
                message: error.message(for: .screen),
                isRetrying: groups.isLoading
            ) {
                Task { await reload() }
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.space6)
        case .loaded:
            loaded(groups.value ?? [])
        }
    }

    /// B4.2: the header at once, two group-card skeletons in the final layout.
    private var loading: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader("Your groups")
                .padding(.top, Spacing.space2)
            LoadingPlaceholder(label: GroupsCopy.loadingGroups) {
                VStack(spacing: Spacing.gridGap) {
                    GroupCardSkeleton()
                    GroupCardSkeleton()
                }
            }
            .padding(.top, Spacing.headingToContent)
        }
        .padding(.horizontal, Spacing.screenGutter)
    }

    private var shownInvites: [CircleInvite] {
        (invites.value ?? []).filter { !answeredInviteIDs.contains($0.id) }
    }

    private var hasStatusBlock: Bool {
        groups.error != nil || invites.error != nil || groups.updatedText() != nil
    }

    @ViewBuilder
    private func loaded(_ list: [CircleSummary]) -> some View {
        let pendingInvites = shownInvites
        // Content starts 8 below the large-title bar, or 24 after a status block (A3.2).
        let firstTop = hasStatusBlock ? Spacing.space6 : Spacing.space2
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if hasStatusBlock {
                    statusBlock
                        .padding(.top, Spacing.space2)
                }

                if list.isEmpty && pendingInvites.isEmpty {
                    // B4.3
                    EmptyState(
                        title: GroupsCopy.emptyTitle,
                        message: GroupsCopy.emptyBody,
                        actionTitle: "Create group"
                    ) {
                        services.navigator.present(.createGroup)
                    }
                    .padding(.top, Spacing.space6)
                }

                if !pendingInvites.isEmpty {
                    SectionHeader("Invitations (\(pendingInvites.count))")
                        .padding(.top, firstTop)
                    VStack(spacing: Spacing.gridGap) {
                        ForEach(pendingInvites) { invite in
                            inviteCard(invite)
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, Spacing.headingToContent)
                }

                if !list.isEmpty {
                    SectionHeader("Your groups")
                        .padding(.top, pendingInvites.isEmpty ? firstTop : Spacing.sectionGap)
                    VStack(spacing: Spacing.gridGap) {
                        ForEach(GroupsOrdering.sorted(list)) { group in
                            NavigationLink(value: AppDestination.groupDetail(id: group.id)) {
                                GroupCard(GroupCardModel(group))
                            }
                            .buttonStyle(PressableCardButtonStyle(restingFill: Palette.canvas))
                            .accessibilityIdentifier("groups.card")
                        }
                    }
                    .padding(.top, Spacing.headingToContent)
                }
            }
            .padding(.horizontal, Spacing.screenGutter)

            SettingsRow(symbol: "info.circle", title: GroupsCopy.howGroupsWorkTitle) {
                showsHowItWorks = true
            }
            .accessibilityIdentifier("groups.howItWorks")
            .padding(.top, Spacing.space6)
        }
        .animation(layoutAnimation, value: pendingInvites.map(\.id))
        .animation(layoutAnimation, value: invites.error != nil)
    }

    /// Status block (A3.2, ruling 11): the refresh banner, the invitations
    /// banner (B4.5), then the freshness line 8 below.
    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if let error = groups.error {
                ErrorBanner(error.message(for: .screen)) {
                    Task { await reload() }
                }
                .transition(.opacity)
            }
            if invites.error != nil {
                ErrorBanner(GroupsCopy.invitesFailed) {
                    Task { await invites.refresh() }
                }
                .accessibilityIdentifier("groups.invitesError")
                .transition(.opacity)
            }
            if let updated = groups.updatedText() {
                Text(updated)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
    }

    private func inviteCard(_ invite: CircleInvite) -> some View {
        InviteCard(
            circleName: invite.circleName,
            inviterName: invite.inviterName,
            contribution: invite.contribution,
            frequency: invite.groupFrequency,
            phase: inviteStates[invite.id] ?? .idle,
            onAccept: { pendingAccept = invite },
            onDecline: { pendingDecline = invite }
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("groups.invite.\(invite.circleName)")
        // B4.7 and B4.8: the dialogs are attached to the card that opens them,
        // so the iOS 26 popover points at it.
        .confirmationDialog(
            "Join \(invite.circleName)?",
            isPresented: Binding(
                get: { pendingAccept?.id == invite.id },
                set: { if !$0, pendingAccept?.id == invite.id { pendingAccept = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Join group") { accept(invite) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll pay in \(invite.contribution.formatted()) \(GroupsCopy.frequencyWord(invite.groupFrequency, raw: invite.frequency)).")
        }
        .confirmationDialog(
            "Decline this invitation?",
            isPresented: Binding(
                get: { pendingDecline?.id == invite.id },
                set: { if !$0, pendingDecline?.id == invite.id { pendingDecline = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Decline", role: .destructive) { decline(invite) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Actions

    private func accept(_ invite: CircleInvite) {
        pendingAccept = nil
        inviteStates[invite.id] = .accepting
        Task {
            do throws(APIError) {
                _ = try await services.api.send(API.Groups.acceptInvite(invite.id))
                answeredInviteIDs.insert(invite.id)
                toast = "You joined \(invite.circleName)."
                await reload()
                inviteStates[invite.id] = nil
            } catch {
                guard error != .cancelled, error != .sessionExpired else {
                    inviteStates[invite.id] = nil
                    return
                }
                inviteStates[invite.id] = .failed(error.message(for: .action))
                failureTick += 1
            }
        }
    }

    private func decline(_ invite: CircleInvite) {
        pendingDecline = nil
        inviteStates[invite.id] = .declining
        Task {
            do throws(APIError) {
                _ = try await services.api.send(API.Groups.declineInvite(invite.id))
                answeredInviteIDs.insert(invite.id)
                await invites.refresh()
                inviteStates[invite.id] = nil
            } catch {
                guard error != .cancelled, error != .sessionExpired else {
                    inviteStates[invite.id] = nil
                    return
                }
                inviteStates[invite.id] = .failed(error.message(for: .action))
                failureTick += 1
            }
        }
    }
}

/// An active group card's skeleton (B4.2): the outlined card at its real
/// size, with blocks where the name, type line, facts, rounds bar and footer
/// land. At accessibility sizes the facts stack, as the card does.
private struct GroupCardSkeleton: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            SkeletonTextLine(.bodyEmphasis, leading: 0.5)
            SkeletonTextLine(.subheadline, leading: 0.4)
                .padding(.top, Spacing.space1)
            let facts = stacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space3))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.space3))
            facts {
                fact
                fact
            }
            .padding(.top, Spacing.space4)
            SkeletonBar(widthFraction: 1, height: 4, radius: 2)
                .padding(.top, Spacing.space3)
            SkeletonTextLine(.footnote, leading: 0.7)
                .padding(.top, Spacing.space2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .outlinedCardStyle()
    }

    private var fact: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            SkeletonTextLine(.subheadline, leading: 0.4)
            SkeletonTextLine(.amountRow, leading: 0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// How groups work (B4.9): the info sheet pattern. No toolbar: the grabber
/// and the swipe dismiss it, and "Done" is pinned. Title (`title2`) 24 pt
/// below the sheet's top edge, three paragraphs (16, then 24 apart).
struct HowGroupsWorkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(GroupsCopy.howGroupsWorkTitle)
                    .textStyle(.title2)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                ForEach(Array(GroupsCopy.howGroupsWorkParagraphs.enumerated()), id: \.offset) { index, paragraph in
                    Text(paragraph)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, index == 0 ? Spacing.headingToContent : Spacing.space6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.top, Spacing.space6)
            .padding(.bottom, Spacing.space3)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("groups.howItWorksSheet")
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            MoolaButton("Done") { dismiss() }
        })
        .sheetChrome([.medium, .large])
        .onAppear { titleFocused = true }
    }
}
