import Domain
import SwiftUI

// The settings-row family (DESIGN.md v2 A8.21; B5 reference). Rows sit on the
// page with no container and no dividers inside a group; groups are separated
// by one `SettingsGroupDivider`. Every row is full width with its content at
// the 16 pt gutter: an optional 18 pt symbol in a 24 pt slot, the title at
// x = 52 (x = 16 without a symbol). Titles are 16 Medium (`headline`, ruling
// 56: the founder's premium bar draws every row label in primary ink at
// Medium), the symbols stay 18 pt Regular `textSecondary` a shade lighter so
// the words lead (premium bar P1, P4).

/// The family's shared geometry (A8.21; premium bar DS-1, DS-7).
enum SettingsRowMetrics {
    /// 60 pt rows, 72 with a sub-line (premium bar DS-7, P2: v2.2's 56 and 68
    /// read dense with Medium titles). `SettingsSelectableRow` keeps 68.
    static func minHeight(hasSubtitle: Bool) -> CGFloat {
        hasSubtitle ? 72 : 60
    }

    /// At accessibility sizes the leading symbol is dropped and the title takes
    /// the gutter, as A8.11 buttons drop theirs: "Notifications" in 16 Medium is
    /// 283.8 pt at AX5 (CoreText, SF Pro Medium 51 pt), wider than the 279 pt
    /// title column a 375 pt iPhone leaves after the 24 pt slot, and iOS would
    /// break it mid-word (A2.5 rule 7). Every row of the family follows, so a
    /// list keeps one left edge at every size.
    static func showsSymbol(_ size: DynamicTypeSize) -> Bool {
        !size.isAccessibilitySize
    }

    /// A group's text column for dividers and footnotes: the caller's x
    /// (52 with symbols, 16 without), or the gutter where the symbols are dropped.
    static func textColumnX(_ x: CGFloat, _ size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? Spacing.screenGutter : x
    }

    static func chevronSize(_ scaled: CGFloat, _ size: DynamicTypeSize) -> CGFloat {
        size.isAccessibilitySize ? min(scaled, 16) : scaled
    }
}

/// The 18 pt Regular leading symbol in its 24 pt slot (both scaling along
/// `.callout`), `textSecondary` unless the row says otherwise. Not drawn at
/// accessibility sizes (`SettingsRowMetrics.showsSymbol`).
struct SettingsRowSymbol: View {
    let name: String
    let color: Color

    @ScaledMetric(relativeTo: .callout) private var size: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var slot: CGFloat = 24

    init(name: String, color: Color = Palette.textSecondary) {
        self.name = name
        self.color = color
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .frame(width: slot, height: slot)
            .accessibilityHidden(true)
    }
}

/// The content of a settings row: optional leading symbol (18 pt Regular
/// `textSecondary` in a 24 pt slot), title (`headline`, 16 Medium), optional
/// sub-line (`subheadline` `textSecondary`, 2 pt below), optional trailing
/// value (`body` `textSecondary`), optional `chevron.forward` (14 pt Semibold,
/// `chevron`) 8 pt after the value. 60 pt tall (72 with a sub-line). At
/// accessibility sizes the symbol is dropped and the value moves under the
/// title. Use it as the label of a `NavigationLink` with
/// `.buttonStyle(RowButtonStyle())`, or through `SettingsRow`.
///
/// `titleLineLimit` and `subtitleLineLimit` (D-40) clamp the title and the
/// sub-line separately, with tail truncation; at accessibility sizes they are
/// ignored and everything wraps. Disabled (`.disabled(true)` on the row,
/// ST.3.5): title, sub-line and symbol in `textTertiary`, no chevron.
public struct SettingsRowLabel: View {
    public enum Tone: Sendable { case standard, destructive }

    let symbol: String?
    let title: String
    let subtitle: String?
    let value: String?
    let titleLineLimit: Int?
    let subtitleLineLimit: Int?
    let tone: Tone
    let showsChevron: Bool

    @ScaledMetric(relativeTo: .callout) private var scaledChevronSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    private var chevronSize: CGFloat { SettingsRowMetrics.chevronSize(scaledChevronSize, dynamicTypeSize) }

    public init(
        symbol: String?,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        titleLineLimit: Int? = nil,
        subtitleLineLimit: Int? = nil,
        tone: Tone = .standard,
        showsChevron: Bool = true
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.titleLineLimit = titleLineLimit
        self.subtitleLineLimit = subtitleLineLimit
        self.tone = tone
        self.showsChevron = showsChevron
    }

    private var titleColor: Color {
        guard isEnabled else { return Palette.textTertiary }
        return tone == .destructive ? Palette.redText : Palette.textPrimary
    }

    private var symbolColor: Color {
        guard isEnabled else { return Palette.textTertiary }
        return tone == .destructive ? Palette.redText : Palette.textSecondary
    }

    /// A caller's line limit; nil (every line) at accessibility sizes.
    private func lineLimit(_ limit: Int?) -> Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : limit
    }

    public var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            if let symbol, SettingsRowMetrics.showsSymbol(dynamicTypeSize) {
                SettingsRowSymbol(name: symbol, color: symbolColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.headline)
                    .foregroundStyle(titleColor)
                    .lineLimit(lineLimit(titleLineLimit))
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .textStyle(.subheadline)
                        .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textTertiary)
                        .lineLimit(lineLimit(subtitleLineLimit))
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let value, dynamicTypeSize.isAccessibilitySize {
                    Text(value)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Spacing.space2) {
                if let value, !dynamicTypeSize.isAccessibilitySize {
                    Text(value)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textSecondary)
                }
                if showsChevron, isEnabled {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: chevronSize, weight: .semibold))
                        .foregroundStyle(Palette.chevron)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: SettingsRowMetrics.minHeight(hasSubtitle: subtitle != nil))
        .contentShape(Rectangle())
    }
}

/// A navigation row (push) or an action row (sheet, dialog), or the
/// destructive "Sign out" row (`redText`, no chevron). One button whose
/// accessibility label is the title plus the value (tests read "Off" inside
/// the Technical details row). Pressed: `RowButtonStyle`. A standard row
/// draws a chevron unless `showsChevron` says otherwise (D-41: an action row
/// that opens a dialog passes `false`); the line limits are
/// `SettingsRowLabel`'s. `.disabled(true)` gives the disabled look (ST.3.5).
public struct SettingsRow: View {
    let symbol: String?
    let title: String
    let subtitle: String?
    let value: String?
    let titleLineLimit: Int?
    let subtitleLineLimit: Int?
    let tone: SettingsRowLabel.Tone
    let showsChevron: Bool?
    let action: () -> Void

    public init(
        symbol: String?,
        title: String,
        subtitle: String? = nil,
        value: String? = nil,
        titleLineLimit: Int? = nil,
        subtitleLineLimit: Int? = nil,
        tone: SettingsRowLabel.Tone = .standard,
        showsChevron: Bool? = nil,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.titleLineLimit = titleLineLimit
        self.subtitleLineLimit = subtitleLineLimit
        self.tone = tone
        self.showsChevron = showsChevron
        self.action = action
    }

    public var body: some View {
        Button(role: tone == .destructive ? .destructive : nil, action: action) {
            SettingsRowLabel(
                symbol: symbol, title: title, subtitle: subtitle, value: value,
                titleLineLimit: titleLineLimit, subtitleLineLimit: subtitleLineLimit, tone: tone,
                showsChevron: showsChevron ?? (tone == .standard)
            )
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// A display row (ruling 34): the row geometry with no press state and no
/// chevron, not a button; a trailing value ("Version" · "0.1.0 (1)",
/// "Authenticator app" · "Off") or a neutral `StatusPill("Invited", tone: .neutral)`.
/// Title `headline`; 60 pt tall (72 with a sub-line). One combined
/// accessibility element ("Version, 0.1.0 (1)"). At accessibility sizes the
/// symbol is dropped and the value moves under the title. An optional leading
/// symbol (the invited `envelope` in the Invite sheet).
public struct SettingsValueRow<Value: View>: View {
    let symbol: String?
    let title: String
    let subtitle: String?
    let value: Value

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(symbol: String? = nil, title: String, subtitle: String? = nil, @ViewBuilder value: () -> Value) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.value = value()
    }

    public var body: some View {
        let accessibilitySize = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .center, spacing: Spacing.space3) {
            if let symbol, SettingsRowMetrics.showsSymbol(dynamicTypeSize) {
                SettingsRowSymbol(name: symbol)
            }
            let layout = accessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space1))
                : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.space3))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .textStyle(.headline)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(accessibilitySize ? nil : 1)
                        .truncationMode(.middle)
                    if let subtitle {
                        Text(subtitle)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                .frame(maxWidth: accessibilitySize ? nil : .infinity, alignment: .leading)
                value
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: SettingsRowMetrics.minHeight(hasSubtitle: subtitle != nil))
        .accessibilityElement(children: .combine)
    }
}

extension SettingsValueRow where Value == SettingsValueText {
    /// A row whose value is plain text (`body` `textSecondary`, tabular digits).
    public init(symbol: String? = nil, title: String, subtitle: String? = nil, value: String) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { SettingsValueText(value) }
    }
}

/// The trailing value of a `SettingsValueRow`: `body` `textSecondary`.
public struct SettingsValueText: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .textStyle(.body)
            .monospacedDigit()
            .foregroundStyle(Palette.textSecondary)
    }
}

/// A row holding a system `Toggle` tinted `jadeFill` (A1.6); no chevron. The
/// switch keeps its system look and haptic; tests flip it as `switches[…]`.
/// Title `headline`, optional sub-line; 60 pt tall (72 with a sub-line). An
/// optional leading symbol (premium bar DS-6: "Lock with Face ID" carries its
/// `BiometryKind` glyph) takes the same 24 pt slot and 12 pt gap as
/// `SettingsRowLabel`, so the title moves to x = 52; it is dropped at
/// accessibility sizes.
public struct SettingsToggleRow: View {
    let symbol: String?
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(symbol: String? = nil, title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .center, spacing: Spacing.space3) {
                if let symbol, SettingsRowMetrics.showsSymbol(dynamicTypeSize) {
                    SettingsRowSymbol(name: symbol)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .textStyle(.headline)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle {
                        Text(subtitle)
                            .textStyle(.subheadline)
                            .foregroundStyle(Palette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(Palette.jadeFill)
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: SettingsRowMetrics.minHeight(hasSubtitle: subtitle != nil))
    }
}

/// A single-choice row (Notifications levels): no leading symbol; title
/// `headline`; an optional badge word after the title ("Recommended",
/// `footnote` `textSecondary`); when selected, the inset selection pill behind
/// the row (premium bar DS-3, P9: `surface`, radius 10, 8 pt from the sides, 2
/// pt inside the top and bottom; Increase Contrast adds a 1 pt `cardBorder`;
/// it fades between rows with `Motion.standard` and hides while the row is
/// held, under the full-width `fillPressed` band) and the trailing `checkmark`
/// (17 pt Medium, `ctaBackground`), because selection is never fill alone;
/// `.isSelected`. 68 pt tall. Put `.sensoryFeedback(.selection, trigger:)` on
/// the list. Disabled (ST.3.5; the selected row never is): title, badge and
/// sub-line in `textTertiary`, the checkmark slot empty, no pill, no press state.
public struct SettingsSelectableRow: View {
    let title: String
    let subtitle: String
    let badge: String?
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var checkSize: CGFloat = 17
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    public init(title: String, subtitle: String, badge: String? = nil, isSelected: Bool, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    let titleLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.space2))
                    titleLayout {
                        Text(title)
                            .textStyle(.headline)
                            .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
                        if let badge {
                            Text(badge)
                                .textStyle(.footnote)
                                .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textTertiary)
                        }
                    }
                    Text(subtitle)
                        .textStyle(.subheadline)
                        .foregroundStyle(isEnabled ? Palette.textSecondary : Palette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Top-aligned in the 68 pt minimum (44 + 12 + 12), so every
                // option's title sits 12 pt below its row top whether its
                // sub-line takes one line or two (B5.6's 81 pt pitch); the
                // checkmark stays centred on the row.
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                Image(systemName: "checkmark")
                    .font(.system(size: checkSize, weight: .medium))
                    .foregroundStyle(Palette.ctaBackground)
                    .opacity(isSelected && isEnabled ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.vertical, Spacing.space3)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
            .insetSelectionPill(isSelected && isEnabled)
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One quarter of the Savings streak's badge grid (SPEC §2.4): text only, the
/// quarter ("Q2", `footnoteEmphasis`, `textPrimary` when collected, else
/// `textSecondary`), 2 pt, the word ("Collected" in `jadeText`, "Not yet" in
/// `textSecondary`, `footnote`), leading in its column; 32.6 pt at the default
/// size. The state is a word, never colour alone. Not tappable. One static
/// text: "Q2 2026, collected" / "Q2 2026, not collected yet". The words are
/// Domain's `StreakQuarter`; the caller lays out the grid (4 across, 2 × 2 at
/// accessibility sizes) and passes the identifier (`streak.badge.<year>.q<n>`).
public struct QuarterBadgeCell: View {
    let quarter: StreakQuarter

    public init(_ quarter: StreakQuarter) {
        self.quarter = quarter
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(quarter.label)
                .textStyle(.footnoteEmphasis)
                .foregroundStyle(quarter.collected ? Palette.textPrimary : Palette.textSecondary)
            Text(quarter.word)
                .textStyle(.footnote)
                .foregroundStyle(quarter.collected ? Palette.jadeText : Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(quarter.spoken)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// The divider between two groups: 1 pt `divider` from the group's text column
/// (x = 52 with leading symbols, x = 16 without; the gutter at accessibility
/// sizes, where the symbols are dropped) to width − 16, 8 pt above and below.
public struct SettingsGroupDivider: View {
    let textColumnX: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(textColumnX: CGFloat = 52) {
        self.textColumnX = textColumnX
    }

    public var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: Size.hairline)
            .padding(.leading, SettingsRowMetrics.textColumnX(textColumnX, dynamicTypeSize))
            .padding(.trailing, Spacing.screenGutter)
            .padding(.vertical, Spacing.space2)
            .accessibilityHidden(true)
    }
}

/// One explanatory line under a group (`footnote` `textSecondary`) at the
/// group's text column (the gutter at accessibility sizes), 4 pt below the
/// last row and 12 pt above the divider's space. Always its own static-text
/// element (tests read these sentences); at most one per group. Pass an
/// identifier with `.accessibilityIdentifier`.
public struct SettingsGroupFootnote: View {
    let text: String
    let textColumnX: CGFloat

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ text: String, textColumnX: CGFloat = Spacing.screenGutter) {
        self.text = text
        self.textColumnX = textColumnX
    }

    public var body: some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SettingsRowMetrics.textColumnX(textColumnX, dynamicTypeSize))
            .padding(.trailing, Spacing.screenGutter)
            .padding(.top, Spacing.space1)
            .padding(.bottom, Spacing.space3)
    }
}

/// An optional group label (sentence case, `subheadline` `textSecondary`), 16 pt
/// below a group divider's space; the first row 7 pt below it (label top to
/// row top 24 pt). Replaces v1's tracked capital labels ("Your account").
public struct SettingsGroupLabel: View {
    let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .textStyle(.subheadline)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.top, Spacing.space4)
            .padding(.bottom, 7)
            .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
private struct SettingsRowsPreview: View {
    @State private var lock = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(symbol: "person.text.rectangle", title: "Profile") {}
                SettingsRow(symbol: "lock.shield", title: "Security") {}
                SettingsGroupDivider()
                SettingsRow(symbol: "wrench.and.screwdriver", title: "Technical details", value: "Off") {}
                SettingsValueRow(title: "Version", value: "0.1.0 (1)")
                SettingsGroupDivider()
                SettingsToggleRow(symbol: "faceid", title: "Lock with Face ID", isOn: $lock)
                SettingsGroupFootnote("MoolaHub asks for Face ID when you open it.", textColumnX: 52)
                SettingsSelectableRow(title: "Essential", subtitle: "Money moves and security only.", badge: "Recommended", isSelected: true) {}
                SettingsRow(symbol: "airplane", title: "Take a break") {}
                    .disabled(true)
                SettingsRow(symbol: "pause.circle", title: "Deactivate account", showsChevron: false) {}
                HStack(alignment: .top, spacing: Spacing.gridGap) {
                    ForEach(1...4, id: \.self) { quarter in
                        QuarterBadgeCell(StreakQuarter(year: 2026, quarter: quarter, collected: quarter == 2))
                    }
                }
                .padding(.horizontal, Spacing.screenGutter)
                SettingsGroupDivider(textColumnX: Spacing.screenGutter)
                SettingsRow(symbol: "rectangle.portrait.and.arrow.right", title: "Sign out", tone: .destructive) {}
            }
        }
        .moolaCanvas()
    }
}

#Preview("Settings rows") {
    SettingsRowsPreview()
}
#endif
