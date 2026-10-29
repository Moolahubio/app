import Domain
import SwiftUI

// MARK: - GroupCard (DESIGN.md v2 A8.8; v1 "CircleCard")

/// Plain values for a group card.
public struct GroupCardModel: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let kind: GroupKind
    public let status: GroupStatus
    public let frequency: GroupFrequency?
    public let contribution: Money
    public let payout: Money
    public let memberCount: Int
    public let targetMembers: Int?
    public let currentRound: Int
    public let totalRounds: Int
    public let myPayoutRound: Int?

    public init(
        id: String, name: String, kind: GroupKind, status: GroupStatus, frequency: GroupFrequency?,
        contribution: Money, payout: Money, memberCount: Int, targetMembers: Int?,
        currentRound: Int, totalRounds: Int, myPayoutRound: Int?
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.status = status
        self.frequency = frequency
        self.contribution = contribution
        self.payout = payout
        self.memberCount = memberCount
        self.targetMembers = targetMembers
        self.currentRound = currentRound
        self.totalRounds = totalRounds
        self.myPayoutRound = myPayoutRound
    }

    public init(_ summary: CircleSummary) {
        self.init(
            id: summary.id, name: summary.name, kind: summary.kind, status: summary.groupStatus,
            frequency: summary.groupFrequency, contribution: summary.contribution, payout: summary.payout,
            memberCount: summary.memberCount, targetMembers: summary.targetMembers,
            currentRound: summary.currentRound, totalRounds: summary.totalRounds,
            myPayoutRound: summary.myPayoutRound
        )
    }

    /// "Take turns · Monthly · 4 members" for active and completed groups;
    /// "Take turns · Monthly" for forming ones (their footer counts who
    /// joined); a missing frequency drops its part (W9.2, W10-SG-11).
    var typeLine: String {
        GroupWords.typeLine(kind: kind, frequency: frequency, status: status, memberCount: memberCount)
    }

    /// "4 members." appended to the spoken label whenever the type line shows
    /// the count (savings-groups §3.3), after the footer, so every tested
    /// substring stays intact.
    var memberCountSpoken: String? {
        switch status {
        case .active, .completed: "\(GroupWords.memberCount(memberCount))."
        case .forming, .other: nil
        }
    }

    var payoutLabel: String { kind == .takeTurns ? "Your payout" : "You get back" }

    var footer: String {
        switch status {
        case .active:
            var text = "Round \(currentRound) of \(totalRounds)"
            if kind == .takeTurns, let myPayoutRound, myPayoutRound > 0 {
                text += " \u{00B7} Your turn: round \(myPayoutRound)"
            }
            return text
        case .forming, .other:
            if let targetMembers {
                return "\(memberCount) of \(targetMembers) joined. Starts when everyone joins."
            }
            return "\(memberCount) joined. Not started yet."
        case .completed:
            return "Finished"
        }
    }

    var roundsFraction: Double {
        guard totalRounds > 0 else { return 0 }
        return Double(min(max(currentRound, 0), totalRounds)) / Double(totalRounds)
    }
}

/// DESIGN.md v1 called this component "CircleCard"; the UI word is "group".
public typealias CircleCard = GroupCard
public typealias CircleCardModel = GroupCardModel

/// A group as an outlined card (A8.8): it belongs to other people too. Name
/// (`bodyEmphasis`) with the status word trailing (`footnote` `textSecondary`
/// for every status); the type line; two facts ("Each round", "Your payout" /
/// "You get back"); active groups add a 4 pt rounds bar; the footer. No media,
/// no pill, no symbol. The card is a button: wrap it in a `Button` with
/// `PressableCardButtonStyle(restingFill: Palette.canvas)`, which draws the
/// `canvas` fill (ruling 31); the card draws the border. At accessibility sizes
/// the status word moves under the type line and the facts stack.
public struct GroupCard: View {
    let model: GroupCardModel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ model: GroupCardModel) {
        self.model = model
    }

    public var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            if accessibilitySize {
                name
                typeLine.padding(.top, Spacing.space1)
                statusWord.padding(.top, Spacing.space1)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    name
                    Spacer(minLength: 0)
                    statusWord
                }
                typeLine.padding(.top, Spacing.space1)
            }
            let facts = accessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space3))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.space3))
            facts {
                fact(label: "Each round", money: model.contribution)
                fact(label: model.payoutLabel, money: model.payout)
            }
            .padding(.top, Spacing.space4)
            if model.status == .active {
                ProgressBar(fraction: model.roundsFraction, height: 4, hasProgress: model.currentRound > 0)
                    .accessibilityHidden(true)
                    .padding(.top, Spacing.space3)
            }
            Text(model.footer.keepingMiddleDotsAtLineEnds)
                .textStyle(.footnote)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, model.status == .active ? Spacing.space2 : Spacing.space3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .outlinedCardStyle(fill: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Opens group.")
        .accessibilityAddTraits(.isButton)
    }

    private var name: some View {
        Text(model.name)
            .textStyle(.bodyEmphasis)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var statusWord: some View {
        Text(model.status.label)
            .textStyle(.footnote)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize()
    }

    private var typeLine: some View {
        Text(model.typeLine.keepingMiddleDotsAtLineEnds)
            .textStyle(.subheadline)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func fact(label: String, money: Money) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(label)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            MoneyText(money, style: .amountRow)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        let frequency = model.frequency?.label ?? ""
        let text = "\(model.name). \(model.kind.label), \(frequency). \(model.status.label). Each round \(model.contribution.accessibilityText()). \(model.payoutLabel) \(model.payout.accessibilityText()). \(model.footer)"
        guard let count = model.memberCountSpoken else { return text }
        return text.hasSuffix(".") ? "\(text) \(count)" : "\(text). \(count)"
    }
}

// MARK: - InviteCard (A8.9)

/// An invitation as an outlined card (A8.9): "Invitation" (`footnote`), the
/// group name (`bodyEmphasis`), "{inviter} invited you", "{contribution}
/// {frequency word}" (`body`, tabular digits); then "Accept" (small primary)
/// and "Decline" (small secondary), equal width, 12 pt apart (stacked at
/// accessibility sizes). The body is not tappable, only its buttons. A
/// failure shows under the buttons in `redText`. The caller applies the
/// identifier `groups.invite.<circleName>`.
public struct InviteCard: View {
    public enum Phase: Equatable, Sendable {
        case idle, accepting, declining
        case failed(String)
    }

    let circleName: String
    let inviterName: String
    let contribution: Money
    let frequency: GroupFrequency?
    let phase: Phase
    let onAccept: () -> Void
    let onDecline: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        circleName: String, inviterName: String, contribution: Money, frequency: GroupFrequency?,
        phase: Phase = .idle, onAccept: @escaping () -> Void, onDecline: @escaping () -> Void
    ) {
        self.circleName = circleName
        self.inviterName = inviterName
        self.contribution = contribution
        self.frequency = frequency
        self.phase = phase
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Invitation")
                .textStyle(.footnote)
                .foregroundStyle(Palette.textSecondary)
            Text(circleName)
                .textStyle(.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space1)
            Text("\(inviterName) invited you")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            Text("\(contribution.formatted()) \(frequency?.word ?? "")")
                .textStyle(.body)
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .accessibilityLabel("\(contribution.accessibilityText()) \(frequency?.word ?? "")")
                .padding(.top, Spacing.space2)
            let buttons = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Spacing.space3))
                : AnyLayout(HStackLayout(spacing: Spacing.space3))
            buttons {
                MoolaButton("Accept", size: .small, loadingTitle: "Joining\u{2026}", isLoading: phase == .accepting, fillsWidth: true, action: onAccept)
                MoolaButton("Decline", kind: .secondary, size: .small, loadingTitle: "Declining\u{2026}", isLoading: phase == .declining, fillsWidth: true, action: onDecline)
            }
            .disabled(phase == .accepting || phase == .declining)
            .padding(.top, Spacing.space4)
            if case .failed(let message) = phase {
                Text(message)
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.redText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .outlinedCardStyle()
    }
}

// MARK: - People (A8.13)

/// Initials avatar (A8.13; premium bar DS-2): a circle with the first two
/// letters of the username, upper-cased, in SF Pro Medium at a size already on
/// the type scale (12 at 32 pt, 19 at 52, 26 at 64). With an `identityKey` the
/// circle is the person's `IdentityTint` and the initials are
/// `identityForeground` (white); without one, and for the "Member" fallback
/// (`person.fill` at 0.45 × the diameter, 29 pt at 64), it is a `fill` circle
/// with `textPrimary` initials, never grey on grey (P1). Increase Contrast adds
/// a 1 pt `cardBorder`. The 64 pt Account avatar is fixed at every text size
/// with its initials capped at `.large`. Always hidden from VoiceOver (the row
/// or header names the person).
public struct AvatarView: View {
    let name: String?
    let size: CGFloat
    let identityKey: String?

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.identityTints) private var identityTints

    /// - Parameter identityKey: the person's handle (`CircleMember.name`, or
    ///   `AuthUser.username ?? AuthUser.name` for you), so the same person has
    ///   the same colour on every screen, or their list's distinct colour
    ///   inside `identityTints(forKeys:)`. Nil draws the neutral circle.
    public init(name: String?, size: CGFloat = Size.avatar, identityKey: String? = nil) {
        self.name = name
        self.size = size
        self.identityKey = identityKey
    }

    static func initials(_ name: String?) -> String? {
        guard let name else { return nil }
        let letters = name.filter { $0.isLetter || $0.isNumber }.prefix(2)
        return letters.isEmpty ? nil : letters.uppercased()
    }

    static func initialSize(for side: CGFloat) -> CGFloat {
        switch side {
        case ..<40: 12
        case ..<60: 19
        default: 26
        }
    }

    public var body: some View {
        let initials = Self.initials(name)
        // The "Member" fallback stays neutral even with a key: it is nobody's colour.
        let tint = initials == nil ? nil : identityKey.map { identityTints[$0] ?? IdentityTint.for(key: $0) }
        ZStack {
            Circle().fill(tint?.color ?? Palette.fill)
            if let initials {
                Text(verbatim: initials)
                    .font(.system(size: Self.initialSize(for: size), weight: .medium))
                    .foregroundStyle(tint == nil ? Palette.textPrimary : Palette.identityForeground)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size >= 60 ? 29 : size * 0.45))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .frame(width: size, height: size)
        .overlay {
            if contrast == .increased { Circle().strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }
}

/// The members of a group as overlapping initials circles, the first member
/// on top (A8.13, ruling 32; the top of Group detail): 32 pt circles in a 2 pt
/// `canvas` ring, a 26 pt pitch, at most 5 circles; with 6 or more members, 4
/// circles and a neutral "+{n}" capsule (`fill`, `textSecondary`). Each named
/// member is their `IdentityTint` (keyed on the name, the same colour as their
/// `MemberRow`; distinct inside `identityTints(forKeys:)`) with ONE white
/// initial, 12 pt Medium (premium bar DS-2; two letters on a 26 pt pitch read
/// as a word string, TASTE-13); nil (the API's "Member") is a `fill` circle
/// with `person.fill` in `textPrimary`. Fixed size; Increase Contrast adds a
/// 1 pt `cardBorder`. Decorative: hidden from VoiceOver (the Members section
/// names everyone). Only real member names from the API, in payout order
/// (take turns) or API order (save together).
public struct AvatarStack: View {
    let names: [String?]
    let maxVisible: Int

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.identityTints) private var identityTints

    public init(names: [String?], maxVisible: Int = 5) {
        self.names = names
        self.maxVisible = max(2, maxVisible)
    }

    private static let fillSide: CGFloat = 32
    private static let ring: CGFloat = 2
    private static let pitch: CGFloat = 26

    private var shown: [String?] {
        names.count > maxVisible ? Array(names.prefix(maxVisible - 1)) : names
    }

    private var overflow: Int { names.count > maxVisible ? names.count - (maxVisible - 1) : 0 }

    public var body: some View {
        HStack(spacing: Self.pitch - (Self.fillSide + 2 * Self.ring)) {
            ForEach(Array(shown.enumerated()), id: \.offset) { index, name in
                circle(name)
                    .zIndex(Double(shown.count - index))
            }
            if overflow > 0 {
                countCapsule
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }

    private func circle(_ name: String?) -> some View {
        let initial = AvatarView.initials(name).map { String($0.prefix(1)) }
        let tint = initial == nil ? nil : name.map { identityTints[$0] ?? IdentityTint.for(key: $0) }
        return ZStack {
            Circle().fill(tint?.color ?? Palette.fill)
            if let initial {
                Text(verbatim: initial)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint == nil ? Palette.textPrimary : Palette.identityForeground)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: Self.fillSide * 0.45))
                    .foregroundStyle(Palette.textPrimary)
            }
        }
        .frame(width: Self.fillSide, height: Self.fillSide)
        .overlay {
            if contrast == .increased { Circle().strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
        }
        .padding(Self.ring)
        .background(Circle().fill(Palette.canvas))
    }

    private var countCapsule: some View {
        Text(verbatim: "+\(overflow)")
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: Self.fillSide, minHeight: Self.fillSide)
            .background(Capsule().fill(Palette.fill))
            .overlay {
                if contrast == .increased { Capsule().strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
            }
            .padding(Self.ring)
            .background(Capsule().fill(Palette.canvas))
    }
}

/// A member (A8.13): full width; a 52 pt avatar at the gutter (the member's
/// `IdentityTint`, keyed on the name; the "Member" fallback stays neutral),
/// text at x = 80: "@{name}" (`headline`, ruling 56) plus " (you)" (`body`
/// weight, `textSecondary`), 2 pt, the sub-line
/// (`subheadline` `textSecondary`; `GroupWords.memberSecondary`: a paid-out
/// save-together member reads "Savings returned"); trailing, in active groups
/// only, "Paid in" or "Not yet" (`subheadline` `textSecondary`). 76 pt min;
/// no dividers. The signed-in user's row has the inset selection pill.
public struct MemberRow: View {
    let name: String
    let isUnnamed: Bool
    let isYou: Bool
    let kind: GroupKind
    let payoutState: MemberPayoutState
    let payoutRound: Int
    let isGroupActive: Bool
    let contributedThisRound: Bool
    let paidOut: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledTypeFont(.body) private var youFont

    public init(
        name: String, isUnnamed: Bool, isYou: Bool, kind: GroupKind, payoutState: MemberPayoutState,
        payoutRound: Int, isGroupActive: Bool, contributedThisRound: Bool, paidOut: Bool = false
    ) {
        self.name = name
        self.isUnnamed = isUnnamed
        self.isYou = isYou
        self.kind = kind
        self.payoutState = payoutState
        self.payoutRound = payoutRound
        self.isGroupActive = isGroupActive
        self.contributedThisRound = contributedThisRound
        self.paidOut = paidOut
    }

    /// Convenience from an API member; "you" is matched by username (W9.3).
    public init(member: CircleMember, kind: GroupKind, isGroupActive: Bool, currentUsername: String?) {
        self.init(
            name: member.name, isUnnamed: member.isUnnamed, isYou: member.isCurrentUser(username: currentUsername),
            kind: kind, payoutState: member.payoutState, payoutRound: member.payoutRound,
            isGroupActive: isGroupActive, contributedThisRound: member.contributedThisRound == true,
            paidOut: member.paidOut
        )
    }

    private var displayName: String { isUnnamed ? "Member" : "@\(name)" }

    private var secondary: String {
        GroupWords.memberSecondary(kind: kind, state: payoutState, payoutRound: payoutRound, paidOut: paidOut)
    }

    private var statusWord: some View {
        Text(contributedThisRound ? "Paid in" : "Not yet")
            .textStyle(.subheadline)
            .foregroundStyle(Palette.textSecondary)
    }

    public var body: some View {
        // At accessibility sizes the pay-in word moves under the text, so the
        // name and sub-line keep the full text column (A2.5 rule 8).
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: stacked ? .top : .center, spacing: Spacing.space3) {
            AvatarView(name: isUnnamed ? nil : name, size: Size.avatar, identityKey: isUnnamed ? nil : name)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text(displayName).foregroundStyle(Palette.textPrimary))\(Text(isYou ? " (you)" : "").font(youFont).foregroundStyle(Palette.textSecondary))")
                    .textStyle(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(secondary)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if stacked, isGroupActive {
                    statusWord
                }
            }
            .frame(maxWidth: stacked ? .infinity : nil, alignment: .leading)
            if !stacked {
                Spacer(minLength: Spacing.space2)
                if isGroupActive {
                    statusWord
                }
            }
        }
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: 76)
        .insetSelectionPill(isYou)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(displayName)\(isYou ? ", you" : ""). \(secondary).\(isGroupActive ? (contributedThisRound ? " Paid in." : " Not yet.") : "")"
        )
    }
}

// MARK: - RoundTimeline and SaveTogetherProgress (A8.14)

public struct RoundTimelineEntry: Hashable, Sendable, Identifiable {
    public let round: Int
    public let name: String
    public let isUnnamed: Bool
    public let state: MemberPayoutState
    public let isYou: Bool

    public var id: Int { round }

    public init(round: Int, name: String, isUnnamed: Bool, state: MemberPayoutState, isYou: Bool) {
        self.round = round
        self.name = name
        self.isUnnamed = isUnnamed
        self.state = state
        self.isYou = isYou
    }
}

/// Take-turns payout order (A8.14): full-width rows 72 pt apart; a 20 pt node
/// centred at x = 42 (paid: `jadeFill` with a `canvas` check; current: a 2 pt
/// `textPrimary` ring with an 8 pt dot; upcoming: a 1.5 pt `controlBorder`
/// ring) joined by a 2 pt `divider` connector; text at x = 80: "Round {n}"
/// (`footnote`), "@{name}" (`headline`) plus " (you)" (`body` weight,
/// `textSecondary`, as in `MemberRow`), the state word (`subheadline`
/// `textSecondary`) and " · Your turn" (`jadeText`) on the person's current
/// round. The person's row has the inset selection pill. One element per
/// row: "Round {n}, {name}, {state}{, your turn}.".
/// For save-together groups use `SaveTogetherProgress`.
public struct RoundTimeline: View {
    let entries: [RoundTimelineEntry]
    let currentRound: Int

    public init(entries: [RoundTimelineEntry], currentRound: Int) {
        self.entries = entries.sorted { $0.round < $1.round }
        self.currentRound = currentRound
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                RoundTimelineRow(
                    entry: entry,
                    isFirst: index == 0,
                    isLast: index == entries.count - 1,
                    currentRound: currentRound
                )
            }
        }
    }
}

struct RoundTimelineRow: View {
    let entry: RoundTimelineEntry
    let isFirst: Bool
    let isLast: Bool
    let currentRound: Int

    @ScaledTypeFont(.subheadlineEmphasis) private var emphasis
    @ScaledTypeFont(.body) private var youFont

    private var name: String { entry.isUnnamed ? "Member" : "@\(entry.name)" }
    private var yourTurn: Bool { entry.isYou && entry.state == .current }

    private var stateText: String {
        switch entry.state {
        case .paid: return "Received"
        case .current: return "Receiving now"
        case .upcoming, .other: return entry.round == currentRound + 1 ? "Up next" : "Upcoming"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            node
                .frame(width: 20, height: 20)
                .padding(.leading, 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Round \(entry.round)")
                    .textStyle(.footnote)
                    .foregroundStyle(Palette.textSecondary)
                Text("\(Text(name).foregroundStyle(Palette.textPrimary))\(Text(entry.isYou ? " (you)" : "").font(youFont).foregroundStyle(Palette.textSecondary))")
                    .textStyle(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(Text(stateText).foregroundStyle(Palette.textSecondary))\(yourTurnText)")
                    .textStyle(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 28)
            .padding(.vertical, Spacing.space2)
            Spacer(minLength: Spacing.screenGutter)
        }
        .frame(minHeight: 72)
        .background(alignment: .topLeading) { connectors }
        .insetSelectionPill(entry.isYou)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Round \(entry.round), \(name), \(stateText)\(yourTurn ? ", your turn" : "").")
    }

    private var yourTurnText: Text {
        guard yourTurn else { return Text(verbatim: "") }
        return Text(verbatim: "\(String.lineEndMiddleDot)Your turn").font(emphasis).foregroundStyle(Palette.jadeText)
    }

    @ViewBuilder
    private var node: some View {
        ZStack {
            Circle().fill(Palette.canvas)
            switch entry.state {
            case .paid:
                Circle().fill(Palette.jadeFill)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Palette.canvas)
            case .current:
                Circle().strokeBorder(Palette.textPrimary, lineWidth: Size.selectionRing)
                Circle().fill(Palette.textPrimary).frame(width: 8, height: 8)
            case .upcoming, .other:
                Circle().strokeBorder(Palette.controlBorder, lineWidth: Size.focusBorder)
            }
        }
        .accessibilityHidden(true)
    }

    /// 2 pt `divider` connectors above and below the node (x 41 to 43).
    private var connectors: some View {
        GeometryReader { geometry in
            let middle = geometry.size.height / 2
            Path { path in
                if !isFirst { path.addRect(CGRect(x: 41, y: 0, width: 2, height: middle - 10)) }
                if !isLast { path.addRect(CGRect(x: 41, y: middle + 10, width: 2, height: geometry.size.height - middle - 10)) }
            }
            .fill(Palette.divider)
        }
        .accessibilityHidden(true)
    }
}

/// Save-together progress (A8.14): a 6 pt bar of current / total rounds; 8 pt;
/// "Round {current} of {total}" (`headline`); 4 pt; "Everyone gets their own
/// savings back after round {total}." or "Savings returned." (`subheadline`
/// `textSecondary`; tested exactly).
public struct SaveTogetherProgress: View {
    let currentRound: Int
    let totalRounds: Int
    let isCompleted: Bool

    public init(currentRound: Int, totalRounds: Int, isCompleted: Bool) {
        self.currentRound = currentRound
        self.totalRounds = totalRounds
        self.isCompleted = isCompleted
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgressBar(
                fraction: totalRounds > 0 ? Double(min(currentRound, totalRounds)) / Double(totalRounds) : 0,
                height: 6,
                hasProgress: currentRound > 0
            )
            Text("Round \(currentRound) of \(totalRounds)")
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, Spacing.space2)
            Text(isCompleted ? "Savings returned." : "Everyone gets their own savings back after round \(totalRounds).")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space1)
        }
    }
}

// MARK: - ChoiceCard (A8.29)

/// A single choice as an outlined card (Create group "How it works", A8.29):
/// title (`headline`) and description (`subheadline` `textSecondary`), a
/// trailing radio (22 pt `circle` in `controlBorder`, or
/// `largecircle.fill.circle` in `ctaBackground` when selected). The selected
/// card's border becomes 2 pt `ctaBackground`; `.isSelected`. Pressed like an
/// outlined card. Put `.sensoryFeedback(.selection, trigger:)` on the group.
/// Identifiers from the caller (`groups.create.takeTurns`, `groups.create.saveTogether`).
public struct ChoiceCard: View {
    let title: String
    let description: String
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var radioSize: CGFloat = 22

    public init(title: String, description: String, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.description = description
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
        Button(action: action) {
            HStack(alignment: .top, spacing: Spacing.space3) {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    Text(title)
                        .textStyle(.headline)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(description)
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: radioSize, weight: .regular))
                    .foregroundStyle(isSelected ? Palette.ctaBackground : Palette.controlBorder)
                    .accessibilityHidden(true)
            }
            .multilineTextAlignment(.leading)
            .outlinedCardStyle(fill: false)
            .overlay {
                if isSelected { shape.strokeBorder(Palette.ctaBackground, lineWidth: Size.selectionRing) }
            }
            .contentShape(shape)
        }
        .buttonStyle(PressableCardButtonStyle(restingFill: Palette.canvas))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#Preview("Group components") {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            Button {} label: {
                GroupCard(GroupCardModel(id: "1", name: "Family susu", kind: .takeTurns, status: .active, frequency: .monthly, contribution: Money(cents: 10_000), payout: Money(cents: 40_000), memberCount: 4, targetMembers: 4, currentRound: 3, totalRounds: 4, myPayoutRound: 4))
            }
            .buttonStyle(PressableCardButtonStyle(restingFill: Palette.canvas))
            .padding(.horizontal, 16)
            InviteCard(circleName: "Wedding fund", inviterName: "Esi", contribution: Money(cents: 5_000), frequency: .biweekly, onAccept: {}, onDecline: {})
                .padding(.horizontal, 16)
            AvatarStack(names: ["kofi", "esi", "yaw", "ama", nil, "abena"])
                .padding(.horizontal, 16)
            MemberRow(name: "ama", isUnnamed: false, isYou: true, kind: .takeTurns, payoutState: .upcoming, payoutRound: 4, isGroupActive: true, contributedThisRound: false)
            MemberRow(name: "Member", isUnnamed: true, isYou: false, kind: .takeTurns, payoutState: .paid, payoutRound: 1, isGroupActive: true, contributedThisRound: true)
            MemberRow(name: "esi", isUnnamed: false, isYou: false, kind: .saveTogether, payoutState: .upcoming, payoutRound: 0, isGroupActive: false, contributedThisRound: false, paidOut: true)
            RoundTimeline(entries: [
                .init(round: 1, name: "kofi", isUnnamed: false, state: .paid, isYou: false),
                .init(round: 2, name: "esi", isUnnamed: false, state: .paid, isYou: false),
                .init(round: 3, name: "ama", isUnnamed: false, state: .current, isYou: true),
                .init(round: 4, name: "yaw", isUnnamed: false, state: .upcoming, isYou: false),
            ], currentRound: 3)
            SaveTogetherProgress(currentRound: 4, totalRounds: 6, isCompleted: false)
                .padding(.horizontal, 16)
            ChoiceCard(title: "Take turns", description: "Everyone pays in each round and one person receives the pot.", isSelected: true) {}
                .padding(.horizontal, 16)
        }
    }
    .moolaCanvas()
}
