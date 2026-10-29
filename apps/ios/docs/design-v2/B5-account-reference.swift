// DESIGN.md v2, Part B5 (Account) reference code.
// Compiles together with Part A's reference (A-foundations-reference.swift), which
// defines Palette, TypeToken / .textStyle, Spacing, Radius, Size, Motion,
// MoolaButtonStyle, RowButtonStyle, SheetChrome, SheetCloseButton, SkeletonBlock.
//
// Type-checked with (results in B5-account.md, "Verification"):
//   xcrun --sdk iphonesimulator swiftc -typecheck -swift-version 6 \
//     -target arm64-apple-ios17.0-simulator \
//     A-foundations-reference.swift B5-account-reference.swift
//
// What is here:
//   - SettingsRowLabel / SettingsRow and its variants, written from Part A A8.21 prose
//     (Part A ships no code for it), so B5's geometry can be checked.
//   - The two additions B5 proposes to Part A (B5 "Proposed additions"):
//     SettingsValueRow (a non-interactive title + value row) and SettingsGroupFootnote.
//   - AccountAvatar (A8.13 AvatarView at 64 pt) and AccountHeader.
//   - PinnedActionBar (A4.4 pinned bottom bar, iOS 26 safeAreaBar / iOS 17-18 safeAreaInset).
// Names that exist in v1 code keep their roles; nothing here is a new screen.

import SwiftUI
import UIKit

// MARK: - Rows (A8.21)

/// The content of every Account row: optional leading symbol (18 pt Regular in a
/// 24 pt slot at x = 16), title at x = 52 (x = 16 without a symbol), optional
/// sub-line 2 pt below, optional trailing value, optional chevron 8 pt after the value.
struct SettingsRowLabel: View {
    let symbol: String?
    let title: String
    var subtitle: String? = nil
    var value: String? = nil
    var tone: Tone = .standard
    var showsChevron = true

    enum Tone { case standard, destructive }

    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var symbolSlot: CGFloat = 24
    @ScaledMetric(relativeTo: .callout) private var chevronSize: CGFloat = 14
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var titleColor: Color { tone == .destructive ? Palette.redText : Palette.textPrimary }
    private var symbolColor: Color { tone == .destructive ? Palette.redText : Palette.textSecondary }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: symbolSize, weight: .regular))
                    .foregroundStyle(symbolColor)
                    .frame(width: symbolSlot, height: symbolSlot)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.body)
                    .foregroundStyle(titleColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Text(subtitle)
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A2.5 rule 8: at accessibility sizes the value moves under the title.
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
                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: chevronSize, weight: .semibold))
                        .foregroundStyle(Palette.chevron)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: subtitle == nil ? 56 : 68)
        .contentShape(Rectangle())
    }
}

/// A navigation row (push) or an action row (sheet, dialog). One button; its
/// accessibility label is the title plus the value (tests read "Off" inside
/// the Technical details row's label).
struct SettingsRow: View {
    let symbol: String?
    let title: String
    var value: String? = nil
    var tone: SettingsRowLabel.Tone = .standard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingsRowLabel(
                symbol: symbol, title: title, value: value, tone: tone,
                showsChevron: tone == .standard
            )
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// B5 proposed addition 1: a non-interactive title + value row (no chevron, no
/// press state, not a button). One accessibility element: "Version, 0.1.0 (1)".
struct SettingsValueRow<Value: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let value: () -> Value
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space1))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Spacing.space3))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: subtitle == nil ? 56 : 68)
        .accessibilityElement(children: .combine)
    }
}

/// A row that holds a system Toggle: no chevron, tint jadeFill (A1.6). The switch
/// keeps its system look and haptic; tests flip it as `switches[...]`.
struct SettingsToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(.body)
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
        .tint(Palette.jadeFill)
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: subtitle == nil ? 56 : 68)
    }
}

/// A8.21 selectable row (Notifications levels): no leading symbol, trailing
/// checkmark 17 pt Medium in ctaBackground when selected, `.isSelected`.
struct SettingsSelectableRow: View {
    let title: String
    let subtitle: String
    var badge: String? = nil          // "Recommended" (footnote, textSecondary)
    let isSelected: Bool
    let action: () -> Void

    @ScaledMetric(relativeTo: .callout) private var checkSize: CGFloat = 17
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: Spacing.space3) {
                VStack(alignment: .leading, spacing: 2) {
                    let titleLayout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.space2))
                    titleLayout {
                        Text(title)
                            .textStyle(.body)
                            .foregroundStyle(Palette.textPrimary)
                        if let badge {
                            Text(badge)
                                .textStyle(.footnote)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                    Text(subtitle)
                        .textStyle(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "checkmark")
                    .font(.system(size: checkSize, weight: .medium))
                    .foregroundStyle(Palette.ctaBackground)
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.vertical, Spacing.space3)
            .frame(minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Groups (A8.21) and the proposed group footnote

/// The divider between two groups: 1 pt `divider`, from the group's text column
/// (x = 52 with leading symbols, x = 16 without) to width − 16, 8 pt above and below.
struct SettingsGroupDivider: View {
    var textColumnX: CGFloat = 52
    var body: some View {
        Rectangle()
            .fill(Palette.divider)
            .frame(height: Size.hairline)
            .padding(.leading, textColumnX)
            .padding(.trailing, Spacing.screenGutter)
            .padding(.vertical, Spacing.space2)
            .accessibilityHidden(true)
    }
}

/// B5 proposed addition 2: one footnote under a group's last row (`footnote`,
/// `textSecondary`), 4 pt below the row frame, 12 pt of space under it, at the
/// group's text column. Its own static-text element, never merged into a row
/// (tests read these sentences as `staticTexts[...]`).
struct SettingsGroupFootnote: View {
    let text: String
    var textColumnX: CGFloat = Spacing.screenGutter
    var body: some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, textColumnX)
            .padding(.trailing, Spacing.screenGutter)
            .padding(.top, Spacing.space1)
            .padding(.bottom, Spacing.space3)
    }
}

// MARK: - Account header (A8.13 AvatarView at 64 pt)

struct AccountAvatar: View {
    let initials: String?
    var body: some View {
        ZStack {
            Circle().fill(Palette.fill)
            if let initials {
                Text(verbatim: initials)
                    .font(.system(size: 26, weight: .medium))   // 0.4 × 64 (A8.13)
                    .foregroundStyle(Palette.textSecondary)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: 29, weight: .regular))  // 0.45 × 64 (A8.13)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .frame(width: 64, height: 64)
        // v1 kept: a fixed 64 pt circle whose initials stop growing at .large.
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
    }
}

/// Identity block on the Account tab root. One left edge (x = 16): avatar,
/// then name, then "@username", then email. One accessibility element.
struct AccountHeader: View {
    let initials: String?
    let name: String
    let username: String?
    let email: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AccountAvatar(initials: initials)
            Text(name)
                .textStyle(.title3)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space3)
            if let username, !username.isEmpty {
                Text(verbatim: "@\(username)")
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.top, Spacing.space1)
            }
            Text(email)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.screenGutter)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("account.header")
    }
}

// MARK: - Pinned bottom bar (A4.4)

/// The one pinned bottom bar (A8.30, v2.1). iOS 26: `safeAreaBar` with the
/// scroll edge effect; iOS 17/18: `safeAreaInset` on an opaque ground.
/// - `inset`: 16 on screens (`Spacing.screenGutter`), 20 in sheets (`Spacing.sheetPadding`).
/// - `ground`: the iOS 17/18 bar background: `.canvas` on screens, `.sheet` (`sheetCanvas`) in sheets.
/// - `bottomPadding`: `PinnedBarMetrics.bottomPadding(...)`: 8 above the bottom safe area;
///   16 where that inset is 0 (home-button iPhones); 0 when the bar ends with a 44 pt footer row (B1.0.3).
/// - `hardEdge`: true when text sits under the button (a reason slot or a footer row), so
///   scrolled content never shows through behind it (iOS 26 `.hard` bottom edge; else `.soft`).
/// At accessibility sizes the caller puts only the main button in the bar; the banner,
/// reason line, secondary and "Edit amount" move into the scroll content (A8.30).
enum PinnedBarGround { case canvas, sheet }

enum PinnedBarMetrics {
    static func bottomPadding(bottomSafeArea: CGFloat, endsWithFooterRow: Bool) -> CGFloat {
        if endsWithFooterRow { return 0 }
        return bottomSafeArea == 0 ? Spacing.space4 : Spacing.space2
    }
}

struct PinnedActionBar<Bar: View>: ViewModifier {
    var inset: CGFloat = Spacing.screenGutter
    var ground: PinnedBarGround = .canvas
    var bottomPadding: CGFloat = Spacing.space2
    var hardEdge = false
    @ViewBuilder let bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .scrollEdgeEffectStyle(hardEdge ? .hard : .soft, for: .bottom)
                .safeAreaBar(edge: .bottom) { padded }
        } else {
            content
                .safeAreaInset(edge: .bottom) {
                    padded.background(ground == .sheet ? Palette.sheetCanvas : Palette.canvas)
                }
        }
    }

    private var padded: some View {
        bar()
            .padding(.horizontal, inset)
            .padding(.top, Spacing.space3)
            .padding(.bottom, bottomPadding)
    }
}

/// A disabled main action's reason (A9.9): `footnote`, `textSecondary`, centred,
/// 8 pt under the button. The slot is RESERVED: it keeps one line's height while
/// the action is enabled (the text fades out), so the button never moves under the
/// thumb when the form becomes valid.
struct DisabledReasonLine: View {
    let text: String
    var isShown = true
    var body: some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(Palette.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .opacity(isShown ? 1 : 0)
            .animation(Motion.standard, value: isShown)
            .accessibilityHidden(!isShown)
    }
}

// MARK: - Composition examples (the layouts B5 specifies; data is passed in)

struct AccountRootExample: View {
    var technicalDetailsOn = false
    var showsDeveloper = true
    @State private var confirmsSignOut = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                AccountHeader(initials: "AO", name: "Ama Owusu", username: "ama", email: "demo@moolahub.test")
                    .padding(.top, Spacing.space2)
                    .padding(.bottom, Spacing.space6)
                SettingsRow(symbol: "person.text.rectangle", title: "Profile") {}
                    .accessibilityIdentifier("account.row.profile")
                SettingsRow(symbol: "lock.shield", title: "Security") {}
                    .accessibilityIdentifier("account.row.security")
                SettingsRow(symbol: "bell", title: "Notifications") {}
                    .accessibilityIdentifier("account.row.notifications")
                SettingsGroupDivider()
                SettingsRow(symbol: "wrench.and.screwdriver", title: "Technical details",
                            value: technicalDetailsOn ? "On" : "Off") {}
                    .accessibilityIdentifier("account.row.technicalDetails")
                SettingsRow(symbol: "doc.text", title: "About and legal") {}
                    .accessibilityIdentifier("account.row.about")
                if showsDeveloper {
                    SettingsGroupDivider()
                    SettingsRow(symbol: "hammer", title: "Developer settings") {}
                        .accessibilityIdentifier("account.row.developerSettings")
                }
                SettingsGroupDivider()
                SettingsRow(symbol: "rectangle.portrait.and.arrow.right", title: "Sign out", tone: .destructive) {
                    confirmsSignOut = true
                }
                .accessibilityIdentifier("account.signOut")
                // Attached to the row: the iOS 26 popover points at "Sign out" (A9.4).
                .confirmationDialog("Sign out of MoolaHub?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) {}
                    Button("Cancel", role: .cancel) {}
                }
            }
            .padding(.bottom, Spacing.space8)
        }
        .moolaCanvasExample()
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.large)
    }
}

struct SecurityExample: View {
    @State private var lock = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(symbol: nil, title: "Password") {}
                    .accessibilityIdentifier("account.security.password")
                SettingsValueRow(title: "Authenticator app") {
                    Text("Off").textStyle(.body).foregroundStyle(Palette.textSecondary)
                }
                .accessibilityIdentifier("account.security.twoFactor")
                SettingsGroupFootnote(text: "You can turn two-factor on or off on the MoolaHub website.")
                SettingsGroupDivider(textColumnX: Spacing.screenGutter)
                SettingsToggleRow(title: "Lock with Face ID", isOn: $lock)
                    .accessibilityIdentifier("account.security.appLock")
                SettingsGroupFootnote(text: "MoolaHub asks for Face ID when you open it, and after a minute in the background.")
                    .accessibilityIdentifier("account.security.appLock.footnote")
            }
            .padding(.top, Spacing.space4)
        }
        .moolaCanvasExample()
        .navigationTitle("Security")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ProfileSaveBarExample: View {
    let hasChanges: Bool
    let isSaving: Bool
    var body: some View {
        ScrollView { Color.clear.frame(height: 400) }
            .modifier(PinnedActionBar(hardEdge: true) {
                VStack(spacing: Spacing.space2) {
                    Button(isSaving ? "Saving\u{2026}" : "Save changes") {}
                        .buttonStyle(MoolaButtonStyle(kind: .primary))
                        .disabled(!hasChanges)
                        .accessibilityIdentifier("account.profile.save")
                    DisabledReasonLine(text: "Change your name or username to save.", isShown: !hasChanges)
                }
            })
    }
}


// MARK: - TechnicalDetailsRow geometry (A8.31 styles; B5 proposed addition 3: geometry,
// the "not set up" variant and the accessibility-size layout)

/// Label over value, 4 pt apart (A2.5 rule 3), 12 pt vertical padding; trailing plain
/// "Copy" / "Copied" (subheadlineEmphasis + 13 pt symbol), 44 pt hit. At accessibility
/// sizes the value wraps (no truncation) and Copy moves under it.
struct TechnicalDetailsRowV2: View {
    let label: String
    let value: String?          // nil: "Not set up yet", no Copy button
    var missingText = "Not set up yet"
    @State private var copied = false
    @ScaledMetric(relativeTo: .footnote) private var copySymbol: CGFloat = 13
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.space2))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: Spacing.space3))
        layout {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text(label)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                Text(value ?? missingText)
                    .textStyle(.body)
                    .monospacedDigit()
                    .foregroundStyle(value == nil ? Palette.textSecondary : Palette.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? missingText)
            if let value {
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                    AccessibilityNotification.Announcement("Copied").post()
                } label: {
                    HStack(spacing: Spacing.space1) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: copySymbol, weight: .medium))
                        Text(copied ? "Copied" : "Copy")
                            .textStyle(.subheadlineEmphasis)
                    }
                    .foregroundStyle(Palette.textPrimary)
                    .contentTransition(.opacity)
                    .frame(minHeight: Size.minimumTapTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .animation(reduceMotion ? Motion.reduced : Motion.standard, value: copied)
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
        .padding(.horizontal, Spacing.screenGutter)
        .padding(.vertical, Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A8.21 group label (sentence case, subheadline, textSecondary), used once in B5
/// (Technical details "Your account"). Label top to first row top: 24 pt (17 pt label + 7 pt; render-measured label height).
struct SettingsGroupLabel: View {
    let text: String
    var body: some View {
        Text(text)
            .textStyle(.subheadline)
            .foregroundStyle(Palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenGutter)
            .padding(.bottom, 7)
            .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// Stand-in for v1 `.moolaCanvas()` (paints `canvas`), which is not in Part A's reference file.
    func moolaCanvasExample() -> some View { background(Palette.canvas) }
}
