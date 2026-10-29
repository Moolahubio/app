import SwiftUI

/// Red-tint error banner inside the margins (DESIGN.md v2 A8.23): radius 10,
/// padding 12; `exclamationmark.triangle.fill` 16 pt `redText` in a 20 pt slot
/// (both scale with the text); an optional title (`subheadlineEmphasis`) 2 pt
/// above the message (`subheadline`); an optional trailing plain action named
/// by the caller ("Try again"; "View activity" after an uncertain money move).
/// One combined accessibility element, announced on appear. At accessibility
/// sizes the action moves under the message so the message keeps the width.
/// A money move's refusal: title "Didn't go through. Nothing was taken." (J0.7).
public struct ErrorBanner: View {
    let title: String?
    let message: String
    let retryTitle: String
    let retry: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var symbolSize: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var symbolSlot: CGFloat = 20

    public init(_ message: String, title: String? = nil, retryTitle: String = "Try again", retry: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.retry = retry
    }

    public var body: some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(Palette.redText)
                .frame(width: symbolSlot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .textStyle(.subheadlineEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(message)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if stacked, retry != nil {
                    action.padding(.top, Spacing.space1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !stacked, retry != nil {
                action
            }
        }
        .padding(Spacing.space3)
        .background(Palette.redTint, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .onAppear {
            AccessibilityNotification.Announcement([title, message].compactMap { $0 }.joined(separator: " ")).post()
        }
    }

    @ViewBuilder
    private var action: some View {
        if let retry {
            Button(action: retry) {
                Text(retryTitle)
                    .textStyle(.subheadlineEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: Size.minimumTapTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The one action of a `NoticeBanner` (A8.23 amendment, SPEC §5.2, D-02): the
/// visible action word, also a Voice Control input label; the banner's
/// VoiceOver label (default "{title}. {message}"); an optional hint; what a
/// tap does.
public struct NoticeAction {
    let title: String
    let spokenLabel: String?
    let hint: String?
    let perform: @MainActor () -> Void

    public init(_ title: String, spokenLabel: String? = nil, hint: String? = nil, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.spokenLabel = spokenLabel
        self.hint = hint
        self.perform = perform
    }
}

/// An informational banner in a tone (A8.23): neutral (`surface`,
/// `info.circle`), positive `.jade` (`jadeTint`, `checkmark.circle.fill`),
/// warning `.amber` (`amberTint`, `exclamationmark.circle`; the test-money
/// notice passes `testtube.2`). Radius 10, padding 12; symbol 16 pt in a 20 pt
/// slot in the tone's colour; optional title (`subheadlineEmphasis`) above the
/// message (`subheadline`), both `textPrimary`. One accessibility element.
///
/// With a `NoticeAction` (SPEC §5.2; neutral tone only this wave) the whole
/// banner is one button: `PressableCardButtonStyle` at radius 10 (`surface`,
/// pressed `fillPressed`, 0.98), the caller's symbol (the action's own A7.3
/// symbol), the action word (`subheadlineEmphasis`) trailing 12 pt after the
/// text column on the message's first baseline, or under the message (4 pt,
/// leading) at accessibility sizes. Increase Contrast adds a 1 pt
/// `cardBorder`. One element, trait button: label `spokenLabel` or
/// "{title}. {message}", the caller's hint, input labels the action word and
/// the title; not announced; no haptic. The caller's identifier lands on the
/// button.
public struct NoticeBanner: View {
    let title: String?
    let message: String
    let systemImage: String?
    let tone: PillTone
    let action: NoticeAction?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .footnote) private var symbolSize: CGFloat = 16
    @ScaledMetric(relativeTo: .footnote) private var symbolSlot: CGFloat = 20

    public init(_ message: String, title: String? = nil, systemImage: String? = nil, tone: PillTone) {
        self.init(message, title: title, systemImage: systemImage, tone: tone, action: nil)
    }

    /// A notice with one action: the whole banner is the button (SPEC §5.2).
    public init(_ message: String, title: String? = nil, systemImage: String? = nil, tone: PillTone, action: NoticeAction?) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tone = tone
        self.action = action
    }

    private var background: Color {
        tone == .neutral ? Palette.surface : tone.background
    }

    private var symbol: String {
        if let systemImage { return systemImage }
        switch tone {
        case .neutral: return "info.circle"
        case .jade: return "checkmark.circle.fill"
        case .amber: return "exclamationmark.circle"
        case .red: return "exclamationmark.triangle.fill"
        }
    }

    public var body: some View {
        if let action {
            actionBanner(action)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                symbolView
                textColumn(actionBelow: nil)
            }
            .padding(Spacing.space3)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private var symbolView: some View {
        Image(systemName: symbol)
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(tone.foreground)
            .frame(width: symbolSlot)
            .accessibilityHidden(true)
    }

    /// Title (2 pt above) and message; at accessibility sizes an action word
    /// passed here sits 4 pt under the message, leading.
    private func textColumn(actionBelow: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title {
                Text(title)
                    .textStyle(.subheadlineEmphasis)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(message)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .alignmentGuide(.noticeMessageBaseline) { $0[.firstTextBaseline] }
            if let actionBelow {
                // 4 pt under the message: the column's 2 plus 2.
                actionWord(actionBelow)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionWord(_ title: String) -> some View {
        Text(title)
            .textStyle(.subheadlineEmphasis)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func actionBanner(_ action: NoticeAction) -> some View {
        let stacked = dynamicTypeSize.isAccessibilitySize
        let shape = RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
        return Button {
            action.perform()
        } label: {
            // The symbol sits on the title's first baseline; the action word
            // on the message's (SPEC §5.2), through a guide the message sets.
            HStack(alignment: .noticeMessageBaseline, spacing: Spacing.space3) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    symbolView
                    textColumn(actionBelow: stacked ? action.title : nil)
                }
                if !stacked {
                    actionWord(action.title)
                        .alignmentGuide(.noticeMessageBaseline) { $0[.firstTextBaseline] }
                }
            }
            .padding(Spacing.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                if contrast == .increased { shape.strokeBorder(Palette.cardBorder, lineWidth: Size.hairline) }
            }
            .contentShape(shape)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(action.spokenLabel ?? [title, message].compactMap { $0 }.joined(separator: ". "))
        }
        .buttonStyle(PressableCardButtonStyle(restingFill: background, cornerRadius: Radius.medium))
        .accessibilityHint(action.hint ?? "")
        .accessibilityInputLabels([action.title] + [title].compactMap { $0 })
    }
}

extension VerticalAlignment {
    /// The first baseline of a NoticeBanner's message (SPEC §5.2): the action
    /// word sits on it even when a title is above the message.
    fileprivate enum NoticeMessageBaseline: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.firstTextBaseline] }
    }

    fileprivate static let noticeMessageBaseline = VerticalAlignment(NoticeMessageBaseline.self)
}

/// A non-money confirmation (A8.23, A9.5): an ink capsule (`ctaBackground`),
/// `checkmark.circle.fill` 16 pt Medium, 8 pt, the message in
/// `subheadlineEmphasis` `ctaForeground`; padding 16 × 12; min height 44.
/// The one custom shadow in the app (it floats), light mode only. Never for
/// money moves (they end on a receipt). Attach with `.toast($message)`.
public struct Toast: View {
    let message: String

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .footnote) private var symbolSize: CGFloat = 16

    public init(_ message: String) {
        self.message = message
    }

    public var body: some View {
        HStack(spacing: Spacing.space2) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: symbolSize, weight: .medium))
                .accessibilityHidden(true)
            Text(message)
                .textStyle(.subheadlineEmphasis)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.ctaForeground)
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: Size.minimumTapTarget)
        .background(Palette.ctaBackground, in: Capsule())
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.10), radius: 16, x: 0, y: 6)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Shows `message` as a toast for 3 seconds, 8 pt below the top safe area
    /// (tap to dismiss; a new one replaces the old). Non-money confirmations only.
    /// The toast floats above the navigation bar and sheets in a window of its
    /// own (`ToastWindow`); the binding is set back to nil once it is handed over.
    public func toast(_ message: Binding<String?>) -> some View {
        modifier(ToastModifier(message: message))
    }
}

/// "Held as USDC · Not a bank deposit · Not insured" (A8.22, W7): `footnote`
/// `textSecondary`, then `info.circle` at the footnote size after the text
/// (inline, so it follows the last word when the line wraps), leading at the
/// gutter; a plain button with a 44 pt hit region that opens "About your
/// balance".
public struct DisclosureFooter: View {
    @State private var showsDetails = false

    public init() {}

    public var body: some View {
        Button {
            showsDetails = true
        } label: {
            // The symbol flows inline after the last word (a no-break space
            // keeps it on the last word's line when the text wraps at large
            // sizes), at the footnote size; each dot ends its line.
            Text("\(Disclosure.footer.keepingMiddleDotsAtLineEnds)\u{00A0}\(Image(systemName: "info.circle"))")
                .textStyle(.footnote)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(Palette.textSecondary)
                .frame(maxWidth: .infinity, minHeight: Size.minimumTapTarget, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Held as USDC. Not a bank deposit. Not insured.")
        .accessibilityHint("Shows details.")
        .sheet(isPresented: $showsDetails) {
            AboutBalanceSheet()
        }
    }
}

/// The full balance disclosure (A8.22, B2.2), the info sheet pattern (A3.2):
/// `title2` 24 pt below the sheet's top edge, the verbatim text 16 pt below in
/// `body`, a pinned primary "Done". `SheetChrome([.medium, .large])`.
public struct AboutBalanceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleFocused: Bool

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space4) {
                Text("About your balance")
                    .textStyle(.title2)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($titleFocused)
                Text(Disclosure.aboutBalance)
                    .textStyle(.body)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.sheetPadding)
            .padding(.top, Spacing.space6)
            .padding(.bottom, Spacing.space6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(PinnedActionBar(inset: Spacing.sheetPadding, ground: .sheet) {
            MoolaButton("Done") { dismiss() }
        })
        .sheetChrome([.medium, .large])
        .onAppear { titleFocused = true }
    }
}

/// Verbatim disclosure copy (W7). The only places "USDC" may appear besides
/// About and legal, Technical details and Developer settings.
public enum Disclosure {
    public static let footer = "Held as USDC \u{00B7} Not a bank deposit \u{00B7} Not insured"
    public static let aboutBalance = "Your balance is held as USDC, a US-dollar digital currency issued by Circle. MoolaHub is not a bank. Your balance is not a bank deposit and is not FDIC-insured or government-backed."
    #if DEBUG
    /// Debug builds only, with Add test money (SPEC §8.2 item 9).
    public static let testMoney = "This build of MoolaHub uses test money only. Nothing in it is real money and nothing can be cashed out."
    #endif
}

#if DEBUG
#Preview("Feedback") {
    VStack(spacing: 16) {
        ErrorBanner("We couldn't load your invitations.") {}
        ErrorBanner("You don't have enough available.", title: "Didn't go through. Nothing was taken.")
        NoticeBanner("This is a test version of MoolaHub. Test money isn't real and can't be cashed out.", title: "Test money", systemImage: "testtube.2", tone: .amber)
        NoticeBanner("Your password has been reset. Sign in with your new password.", tone: .jade)
        NoticeBanner("You've been signed out. Please sign in again.", tone: .neutral)
        NoticeBanner(
            "$100.00 to Family susu for round 3 of 4.", title: "Your next pay-in", systemImage: "arrow.turn.up.right", tone: .neutral,
            action: NoticeAction("Pay in", hint: "Opens Family susu and its pay-in.") {}
        )
        Toast("Password updated.")
        DisclosureFooter()
    }
    .padding()
    .moolaCanvas()
}
#endif
