// DESIGN.md v2, Part B4 (Groups) reference code for the components this part
// proposes as additions to Part A (section B4.31). Type-checked together with
// design/v2-parts/A-foundations-reference.swift, which supplies Palette,
// TypeToken/.textStyle, Spacing, Radius, Size, Motion and RowButtonStyle:
//   xcrun --sdk iphonesimulator swiftc -typecheck -swift-version 6 \
//     -target arm64-apple-ios17.0-simulator A-foundations-reference.swift B4-groups-reference.swift
// Names prefixed `B4` are placeholders for the architect to rename into DesignSystem.

import SwiftUI
import UIKit

// MARK: - Money strings used by the examples (the app uses Domain.Money)

enum B4Money {
    static func text(_ cents: Int64) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
    }

    /// "20.40 US dollars": the wording the UI tests parse (`Money.accessibilityText()` in the app).
    static func spoken(_ cents: Int64) -> String {
        let value = (Decimal(cents) / 100).formatted(
            .number.precision(.fractionLength(2)).grouping(.automatic).locale(Locale(identifier: "en_US"))
        )
        return "\(value) US dollars"
    }
}

// MARK: - P1 AvatarStack (Group detail identity row)

/// The members of a group as overlapping initials circles, first member on top.
/// Decorative: hidden from VoiceOver (the Members section names everyone).
/// 32 pt fill circle inside a 2 pt `canvas` ring (36 pt outer), 26 pt pitch,
/// at most 5 circles; with 6 or more members, 4 circles and a "+n" capsule.
public struct B4AvatarStack: View {
    /// Usernames in display order; nil = the API's "Member" fallback.
    let names: [String?]
    let maxVisible: Int

    @Environment(\.colorSchemeContrast) private var contrast

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
        .accessibilityHidden(true)
    }

    private func circle(_ name: String?) -> some View {
        ZStack {
            Circle().fill(Palette.fill)
            if let initials = Self.initials(name) {
                Text(verbatim: initials)
                    // v2.1: 12 pt (0.375 × 32, the `footnoteEmphasis` size), so Group detail
                    // keeps 6 type sizes (review-completeness B6).
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: Self.fillSide * 0.45))
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(width: Self.fillSide, height: Self.fillSide)
        .overlay {
            if contrast == .increased { Circle().strokeBorder(Palette.cardBorder, lineWidth: 1) }
        }
        .padding(Self.ring)
        .background(Circle().fill(Palette.canvas))
    }

    private var countCapsule: some View {
        Text(verbatim: "+\(overflow)")
            .textStyle(.footnoteEmphasis)
            .monospacedDigit()
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 10)
            .frame(minWidth: Self.fillSide, minHeight: Self.fillSide)
            .background(Capsule().fill(Palette.fill))
            .overlay {
                if contrast == .increased { Capsule().strokeBorder(Palette.cardBorder, lineWidth: 1) }
            }
            .padding(Self.ring)
            .background(Capsule().fill(Palette.canvas))
    }

    /// First two letters or digits of the username, upper-cased (A8.13 rule).
    static func initials(_ name: String?) -> String? {
        guard let name else { return nil }
        let letters = name.filter { $0.isLetter || $0.isNumber }.prefix(2)
        return letters.isEmpty ? nil : letters.uppercased()
    }
}

// MARK: - P2 PayInRow ("Your pay-ins" on Group detail)

public enum B4PayInStatus: Sendable { case done, processing, failed }

/// ActivityRow geometry (A8.19) without a leading symbol: every row in the
/// section has the same meaning, so a repeated symbol would add nothing.
/// VoiceOver label starts with the title ("Round 1, 20.40 US dollars. Done. …"),
/// which `GroupsFlowUITests.groupsPayInRow(round:amount:)` matches with BEGINSWITH.
public struct B4PayInRow: View {
    let round: Int
    let amountCents: Int64
    let dateText: String
    let status: B4PayInStatus

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(round: Int, amountCents: Int64, dateText: String, status: B4PayInStatus) {
        self.round = round
        self.amountCents = amountCents
        self.dateText = dateText
        self.status = status
    }

    public var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.space1) {
                    title
                    amount
                    subline
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    VStack(alignment: .leading, spacing: 2) {
                        title
                        subline
                    }
                    Spacer(minLength: Spacing.space2)
                    amount
                }
            }
        }
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: 64)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var title: some View {
        Text(verbatim: "Round \(round)")
            .textStyle(.body)
            .foregroundStyle(Palette.textPrimary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
    }

    private var subline: some View {
        // Text interpolation, not `Text + Text` (deprecated from the iOS 26 SDK).
        Text("\(Text(verbatim: dateText).foregroundStyle(Palette.textSecondary))\(statusSuffix)")
            .textStyle(.subheadline)
    }

    private var statusSuffix: Text {
        switch status {
        case .done: Text(verbatim: "")
        case .processing: Text(verbatim: " \u{00B7} Processing\u{2026}").foregroundStyle(Palette.textSecondary)
        case .failed: Text(verbatim: " \u{00B7} Didn't go through").foregroundStyle(Palette.redText)
        }
    }

    private var amount: some View {
        Text(verbatim: B4Money.text(amountCents))
            .textStyle(.amountRow)
            .foregroundStyle(status == .failed ? Palette.textTertiary : Palette.textPrimary)
            .strikethrough(status == .failed)
            .lineLimit(1)
    }

    private var accessibilityText: String {
        let word: String
        switch status {
        case .done: word = "Done"
        case .processing: word = "Processing"
        case .failed: word = "Didn't go through, nothing was taken"
        }
        return "Round \(round), \(B4Money.spoken(amountCents)). \(word). \(dateText)."
    }
}

// MARK: - P3 RemovableChip (Create group invitation emails)

/// A 36 pt `fill` capsule holding an added email and its remove button.
/// The remove button has a 44 x 44 pt hit region and the label "Remove {email}".
public struct B4RemovableChip: View {
    let text: String
    let onRemove: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    public init(text: String, onRemove: @escaping () -> Void) {
        self.text = text
        self.onRemove = onRemove
    }

    public var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: text)
                .textStyle(.subheadlineEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 14)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: Size.minimumTapTarget, height: Size.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(MoolaButtonStyle(kind: .plain, fullWidth: false))
            .accessibilityLabel("Remove \(text)")
        }
        .frame(minHeight: Size.smallButton)
        .background(Capsule().fill(Palette.fill))
        .overlay {
            if contrast == .increased { Capsule().strokeBorder(Palette.cardBorder, lineWidth: 1) }
        }
        .frame(minHeight: Size.minimumTapTarget)
    }
}

// MARK: - P4 InvitedRow (display-only SettingsRow variant)

/// `envelope` + email + a neutral "Invited" pill. Not a control: no chevron,
/// no pressed state. One VoiceOver element "{email}. Invited." (tested).
public struct B4InvitedRow: View {
    let email: String
    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 18

    public init(email: String) { self.email = email }

    public var body: some View {
        HStack(spacing: Spacing.space3) {
            Image(systemName: "envelope")
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(Palette.textSecondary)
                .frame(width: 24)
            Text(verbatim: email)
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.space2)
            // In the app this is `StatusPill("Invited", tone: .neutral)` (A8.10).
            Text(verbatim: "Invited")
                .textStyle(.footnoteEmphasis)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Spacing.space2)
                .frame(minHeight: 22)
                .background(Capsule().fill(Palette.fill))
                .fixedSize()
        }
        .frame(minHeight: 56)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(email). Invited.")
    }
}

// MARK: - Compositions used by Group detail (tokens only)

/// "Active · Take turns · Monthly": the status word in its colour, the rest grey.
struct B4GroupStatusLine: View {
    enum Status { case active, forming, completed, other(String) }
    let status: Status
    let typeLine: String

    var body: some View {
        let rest = Text(verbatim: " \u{00B7} \(typeLine)").foregroundStyle(Palette.textSecondary)
        Text("\(Text(verbatim: word).foregroundStyle(wordColor))\(rest)")
            .textStyle(.subheadline)
    }

    private var word: String {
        switch status {
        case .active: "Active"
        case .forming: "Forming"
        case .completed: "Completed"
        case .other: "Pending"
        }
    }

    /// v2.1: every status word is `textSecondary`; the word carries the meaning
    /// (A1.8 rule 2) and colour is kept for the states that need attention.
    private var wordColor: Color { Palette.textSecondary }
}

/// Label over the hero figure ("Payout each round" / "$400.00"), one element.
struct B4PayoutBlock: View {
    let label: String
    let cents: Int64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(verbatim: label)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            Text(verbatim: B4Money.text(cents))
                .textStyle(.displayAmount)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(cents)))
                .animation(reduceMotion ? Motion.reduced : Motion.figure, value: cents)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(B4Money.spoken(cents))")
        .accessibilityIdentifier("groups.detail.payout")
    }
}

/// System Stepper on the page: the value is a standalone figure, no box.
struct B4StepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.labelToField) {
            Text(verbatim: title)
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .accessibilityHidden(true)
            Stepper(value: $value, in: range) {
                Text(verbatim: "\(value)")
                    .textStyle(.amountRow)
                    .foregroundStyle(Palette.textPrimary)
            }
            .frame(minHeight: Size.field)
            .accessibilityLabel(title)
            .accessibilityValue("\(value)")
            .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Preview-style usage (type-check only)

struct B4GroupsReferenceUsage: View {
    @State private var people = 5
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                B4AvatarStack(names: ["kofi", "esi", "yaw", "ama", nil, "abena"])
                B4GroupStatusLine(status: .active, typeLine: "Take turns \u{00B7} Monthly")
                    .padding(.top, Spacing.space4)
                B4PayoutBlock(label: "Payout each round", cents: 40_000)
                    .padding(.top, Spacing.space4)
                B4PayInRow(round: 1, amountCents: 2_040, dateText: "Oct 12 at 2:05 PM", status: .done)
                B4PayInRow(round: 2, amountCents: 2_040, dateText: "Nov 12 at 9:30 AM", status: .processing)
                B4InvitedRow(email: "kofi@moolahub.test")
                B4RemovableChip(text: "esi@moolahub.test") {}
                B4StepperRow(title: "Number of people (including you)", value: $people, range: 2...20,
                             identifier: "groups.create.people")
            }
            .padding(.horizontal, Spacing.screenGutter)
        }
        .background(Palette.canvas)
    }
}
