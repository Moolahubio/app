import APIClient
import Auth
import DesignSystem
import Domain
import SwiftUI

/// Invite people (DESIGN.md v2 B4.24): a task sheet with one email field and
/// its one button in the content (a medium sheet with the keyboard up has no
/// room for a pinned bar), the reserved reason line, and the invited list.
/// Server messages are shown verbatim (some still say "circle", FQ26).
struct InviteSheet: View {
    private let services: AppServices
    private let groupID: String
    private let detail: RemoteResource<CircleDetail>

    @State private var email = ""
    @State private var isSending = false
    @State private var errorMessage: String?
    @State private var sentTo: String?
    @State private var failureTick = 0
    @State private var refusedTick = 0
    @AccessibilityFocusState private var titleFocused: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(services: AppServices, groupID: String, detail: RemoteResource<CircleDetail>) {
        self.services = services
        self.groupID = groupID
        self.detail = detail
    }

    private var pending: [CirclePendingInvite] { detail.value?.pendingInvites ?? [] }

    /// `targetMembers − memberCount − pendingInvites.count`, never below 0;
    /// nil for groups without a target size (never full).
    private var spotsLeft: Int? {
        guard let value = detail.value, let target = value.targetMembers else { return nil }
        let members = value.memberCount ?? value.members.count
        return max(0, target - members - pending.count)
    }

    private var isFull: Bool { spotsLeft == 0 }

    private var isEmailEmpty: Bool { email.trimmingCharacters(in: .whitespaces).isEmpty }

    private var isSendDisabled: Bool { isFull || isEmailEmpty }

    private var reason: String { isFull ? GroupsCopy.inviteFull : GroupsCopy.inviteEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .padding(.bottom, Spacing.space6)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !isSending {
                        SheetCloseButton { dismiss() }
                    }
                }
            }
        }
        .sheetChrome([.medium, .large])
        .interactiveDismissDisabled(isSending)
        .sensoryFeedback(.error, trigger: failureTick)
        .sensoryFeedback(.warning, trigger: refusedTick)
        .onAppear { titleFocused = true }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text("Invite people")
                        .textStyle(.title1)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityFocused($titleFocused)
                    if let spotsLeft {
                        Text(GroupsCopy.spotsLeft(spotsLeft))
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .accessibilityIdentifier("groups.inviteSheet.spots")
                    }
                }
                .padding(.top, Spacing.space2)

                MoolaTextField(
                    "Email",
                    text: $email,
                    placeholder: "friend@example.com",
                    error: errorMessage,
                    contentType: .emailAddress,
                    keyboard: .emailAddress,
                    autocapitalization: .never,
                    autocorrection: false
                )
                .disabled(isFull || isSending)
                .onSubmit(send)
                .padding(.top, Spacing.space6)

                if let sentTo {
                    Text("Invite sent to \(sentTo).")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.jadeText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("groups.inviteSheet.sent")
                        .padding(.top, Spacing.space2)
                        .transition(.opacity)
                }

                MoolaButton("Send invite", loadingTitle: "Sending\u{2026}", isLoading: isSending, action: send)
                    .disabled(isSendDisabled)
                    .accessibilityHint(isSendDisabled ? reason : "")
                    .accessibilityIdentifier("groups.inviteSheet.send")
                    .padding(.top, Spacing.fieldToNextLabel)

                DisabledReasonLine(text: reason, isShown: isSendDisabled && !isSending)
                    .accessibilityIdentifier(isFull ? "groups.inviteSheet.full" : "")
                    .padding(.top, Spacing.space2)
            }
            .padding(.horizontal, Spacing.sheetPadding)

            if !pending.isEmpty {
                SectionHeader("Invited")
                    .padding(.horizontal, Spacing.sheetPadding)
                    .padding(.top, Spacing.sectionGap)
                // Display rows with the `envelope` (A7.3): the symbol at the
                // sheet's 20 pt inset, the email at x 56 (the rows pad 16, plus 4).
                VStack(spacing: 0) {
                    ForEach(pending) { invite in
                        SettingsValueRow(symbol: "envelope", title: invite.email) {
                            StatusPill("Invited", tone: .neutral)
                        }
                        .padding(.horizontal, Spacing.sheetPadding - Spacing.screenGutter)
                        .accessibilityLabel("\(invite.email). Invited.")
                    }
                }
                .padding(.top, Spacing.space2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: sentTo)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: pending.map(\.id))
    }

    private func send() {
        guard !isSending, !isFull else { return }
        let address = Validation.normalizedEmail(email)
        guard !address.isEmpty else { return }
        guard Validation.isValidEmail(address) else {
            // Validation blocked the send (A6: `.warning`, not `.error`).
            errorMessage = GroupsCopy.invalidEmail
            sentTo = nil
            refusedTick += 1
            return
        }
        isSending = true
        errorMessage = nil
        sentTo = nil
        Task {
            do throws(APIError) {
                _ = try await services.api.send(API.Groups.invite(groupID: groupID, email: address))
                email = ""
                sentTo = address
                await detail.refresh()
                isSending = false
            } catch {
                isSending = false
                guard error != .cancelled, error != .sessionExpired else { return }
                errorMessage = error.message(for: .action)
                failureTick += 1
            }
        }
    }
}
