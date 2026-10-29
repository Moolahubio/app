// DESIGN.md v2, Part B2 (Home and Activity): reference code for the proposed
// additions to Part A (P1, P2, P3, P4, P7, P10) and the activity receipt sheet
// (B2.7). Type-check it together with Part A's reference file, which defines
// Palette, TypeToken / .textStyle, Spacing, Radius, Size, Motion, MoolaButtonStyle,
// RowButtonStyle, SheetChrome, ReceiptSymbol, ReceiptStatus and SkeletonBlock:
//
//   xcrun --sdk iphonesimulator swiftc -typecheck -swift-version 6 \
//     -target arm64-apple-ios17.0-simulator \
//     A-foundations-reference.swift B2-home-activity-reference.swift
//
// Names ending in "P<n>" are the proposed shapes of Part A components; on
// adoption they keep Part A's names (ErrorBanner, SheetCloseButton, ActivityRow,
// SectionHeader, BalanceCard). Copy strings are the B2 spec's.

import SwiftUI

// MARK: - Shared helpers (money as text, fixed en_US; v1 §2.3)

enum B2Money {
    static func string(_ cents: Int, signed: Bool) -> String {
        let magnitude = Decimal(abs(cents)) / 100
        let text = magnitude.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US")))
        guard signed, cents != 0 else { return text }
        return (cents > 0 ? "+" : "\u{2212}") + text
    }

    /// "1,240.50 US dollars", with "plus" / "minus" for direction (v1 §4.3).
    static func spoken(_ cents: Int, signed: Bool) -> String {
        let magnitude = Decimal(abs(cents)) / 100
        let words = magnitude.formatted(.currency(code: "USD").presentation(.fullName).locale(Locale(identifier: "en_US")))
        guard signed, cents != 0 else { return words }
        return (cents > 0 ? "plus " : "minus ") + words
    }
}

// MARK: - P1 ErrorBanner with an optional title and a named action

/// Part A A8.23 plus: an optional title above the message (as NoticeBanner has)
/// and a caller-named action ("Try again", "View activity").
struct ErrorBannerP1: View {
    let title: String?
    let message: String
    let actionTitle: String
    let action: (() -> Void)?

    init(title: String? = nil, _ message: String, actionTitle: String = "Try again", action: (() -> Void)? = nil) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Palette.redText)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if let title {
                    Text(title)
                        .textStyle(.subheadlineEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                }
                Text(message)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let action {
                // Inside banners the plain action is `subheadlineEmphasis` (A8.11),
                // not MoolaButtonStyle's `headline`, so it draws its own label.
                Button(action: action) {
                    Text(actionTitle)
                        .textStyle(.subheadlineEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .frame(minHeight: Size.minimumTapTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Spacing.space3)
        .background(Palette.redTint, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .onAppear {
            AccessibilityNotification.Announcement([title, message].compactMap { $0 }.joined(separator: " ")).post()
        }
    }
}

// MARK: - P2 SheetCloseButton with a caller identifier (default "Close")

struct SheetCloseButtonP2: View {
    var identifier: String = "Close"
    let action: () -> Void
    var body: some View {
        if #available(iOS 26.0, *) {
            Button(role: .close, action: action)
                .accessibilityIdentifier(identifier)
        } else {
            Button("Close", systemImage: "xmark", action: action)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - P3 BalanceCard failed state with a message line and one retry

struct BalanceFailedBlockP3: View {
    let message: String
    let isRetrying: Bool
    let retry: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Total balance")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            Text("We couldn't load your balance")
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
                .padding(.top, Spacing.space1)
            Text(message)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space1)
            Button(isRetrying ? "Trying again\u{2026}" : "Try again", action: retry)
                .buttonStyle(MoolaButtonStyle(kind: .secondary, fullWidth: false, small: true))
                .disabled(isRetrying)
                .padding(.top, Spacing.space3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - P4 ActivityRow: tappable, aligned, stacked at accessibility sizes

struct ActivityRowP4: View {
    let symbol: String?         // A7.3 by activity type; nil on Home (v2.1: one text edge per screen) and for pay-ins
    let kindWord: String        // v1 §4.17 ("Money added")
    let title: String           // server `description`
    let subline: String         // time, or day per B2 D7
    let amountCents: Int?       // signed relative to the balance; nil = no amount
    let status: ReceiptStatus   // from `onchainStatus`
    let action: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 18

    var body: some View {
        if let action {
            Button(action: action) { content }
                .buttonStyle(RowButtonStyle())
                .accessibilityHint("Shows details.")
        } else {
            content
        }
    }

    private var content: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                stacked
            } else {
                standard
            }
        }
        .padding(.horizontal, Spacing.screenGutter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var standard: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            if symbol != nil { glyph.frame(width: 24, height: 24) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    Text(title)
                        .textStyle(.body)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    amount
                }
                statusLine
            }
        }
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: 64)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            if symbol != nil { glyph }
            Text(title)
                .textStyle(.body)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            amount
            statusLine
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Spacing.space3)
    }

    private var glyph: some View {
        Image(systemName: symbol ?? "")
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(Palette.textSecondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var amount: some View {
        if let cents = amountCents {
            Text(B2Money.string(cents, signed: true))
                .textStyle(.amountRow)
                .strikethrough(status == .failed)
                .foregroundStyle(status == .failed ? Palette.textTertiary : (cents > 0 ? Palette.jadeText : Palette.textPrimary))
                .lineLimit(1)
                .layoutPriority(1)
        }
    }

    /// One `Text` built by interpolation (A2.5 rule 10), so it wraps as one line at
    /// accessibility sizes. v2.1: "Processing…" is a normal state and stays
    /// `textSecondary`; only "Didn't go through" takes a status colour.
    private var statusLine: some View {
        let suffix: Text = switch status {
        case .processing: Text(verbatim: " \u{00B7} Processing\u{2026}")
        case .failed: Text(verbatim: " \u{00B7} Didn't go through").foregroundStyle(Palette.redText)
        case .done: Text(verbatim: "")
        }
        return Text("\(Text(subline))\(suffix)")
            .textStyle(.subheadline)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "{word}. {description}. {plus/minus} {amount}. {status}. {time}." (A8.19)
    private var spoken: String {
        var parts = [kindWord, title]
        if let cents = amountCents { parts.append(B2Money.spoken(cents, signed: true)) }
        switch status {
        case .done: parts.append("Done")
        case .processing: parts.append("Processing")
        case .failed: parts.append("Didn't go through, nothing was taken")
        }
        parts.append(subline)
        return parts.joined(separator: ". ") + "."
    }
}

// MARK: - P7 SectionHeader that wraps its link at accessibility sizes

struct SectionHeaderP7: View {
    let title: String
    var linkTitle: String? = nil
    var linkHint: String? = nil
    var link: (() -> Void)? = nil

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                heading
                Spacer(minLength: Spacing.space2)
                linkButton
            }
            VStack(alignment: .leading, spacing: Spacing.space1) {
                heading
                linkButton
            }
        }
    }

    private var heading: some View {
        Text(title)
            .textStyle(.title3)
            .foregroundStyle(Palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    /// v2.1 (review-prototype B1): the link's 44 pt hit region adds NO layout
    /// height. The visible label keeps the title's line height; the hit region is
    /// grown with padding that negative padding cancels, so the header's frame is
    /// the title line (22.4 pt at the default size) and the B2.1 rhythm holds.
    @ViewBuilder private var linkButton: some View {
        if let linkTitle, let link {
            Button(linkTitle, action: link)
                .buttonStyle(SectionLinkStyle())
                .accessibilityHint(linkHint ?? "")
        }
    }
}

/// "See all": `headline` ink, pressed opacity 0.5; 44 pt hit height and 8 pt of
/// extra hit width each side without changing layout.
struct SectionLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.headline)
            .foregroundStyle(Palette.textPrimary)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .padding(.vertical, 12.6)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
            .padding(.vertical, -12.6)
            .padding(.horizontal, -8)
    }
}

// MARK: - P10 Home: fixed header-band strip and band-coloured overscroll

/// The status-bar strip stays `headerBand`; pull to refresh never reveals a
/// `canvas` gap above the band. The scroll content paints its own grounds
/// (band, then `canvas`), so the backdrop shows only in the overscroll.
struct HomeHeaderBandChromeP10: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background {
                VStack(spacing: 0) {
                    Palette.headerBand.frame(height: 400)
                    Palette.canvas
                }
                .ignoresSafeArea()
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 0).background(Palette.headerBand)
            }
            .toolbar(.hidden, for: .navigationBar)
    }
}

/// Home's greeting band (A8.1) as content, for the P10 sketch.
struct GreetingBandSketch: View {
    let firstName: String
    let updatedText: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            Text(firstName.isEmpty ? "Good to see you" : "Good to see you, \(firstName)")
                .textStyle(.greeting)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("home.greeting")
            if let updatedText {
                Text(updatedText)
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
            }
        }
        .padding(.top, Spacing.space4)
        .padding(.bottom, Spacing.space5)
        .padding(.horizontal, Spacing.screenGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.headerBand)
    }
}

struct HomeChromeSketch: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                GreetingBandSketch(firstName: "Ama", updatedText: nil)
                Color.clear.frame(height: 600) // the rest of Home, on `canvas`
            }
            .background(Palette.canvas)
        }
        .accessibilityIdentifier("home.scroll")
        .modifier(HomeHeaderBandChromeP10())
    }
}

// MARK: - B2.7 Activity receipt sheet (layout sketch)

struct ActivityReceiptSketch: View {
    let title: String          // server `description`
    let kindWord: String       // v1 §4.17
    let amountCents: Int?      // signed
    let date: Date             // `createdAt`
    let status: ReceiptStatus  // from `onchainStatus`
    let done: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    ReceiptSymbol(status: status)
                        .padding(.top, Spacing.space6)
                    Text(title)
                        .textStyle(.title1)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.top, Spacing.space4)
                    if let cents = amountCents {
                        Text(B2Money.string(cents, signed: true))
                            .textStyle(.displayAmount)
                            .foregroundStyle(cents > 0 ? Palette.jadeText : Palette.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .accessibilityLabel(B2Money.spoken(cents, signed: true))
                            .accessibilityIdentifier("activity.receipt.amount")
                            .padding(.top, Spacing.space2)
                    }
                    VStack(spacing: 0) {
                        row("Type", Text(kindWord))
                        row("Date", Text(date.formatted(date: .abbreviated, time: .shortened)))
                        row("Status", Text(statusWord))
                    }
                    .padding(.top, Spacing.space8)
                    if let note {
                        Text(note)
                            .textStyle(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, Spacing.space3)
                    }
                }
                .padding(.horizontal, Spacing.sheetPadding)
            }
            .safeAreaInset(edge: .bottom) {
                Button("Done", action: done)
                    .buttonStyle(MoolaButtonStyle(kind: .primary))
                    .padding(.horizontal, Spacing.sheetPadding)
                    .padding(.top, Spacing.space3)
                    .padding(.bottom, Spacing.space2)
            }
            .accessibilityIdentifier("activity.receipt")
        }
        .modifier(SheetChrome(detents: [.large]))
    }

    private var statusWord: String {
        switch status {
        case .done: "Done"
        case .processing: "Processing\u{2026}"
        case .failed: "Didn't go through"
        }
    }

    private var note: String? {
        switch status {
        case .done: nil
        case .processing: "This can take a few minutes."
        case .failed: "Nothing was taken."
        }
    }

    private func row(_ label: String, _ value: Text) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).textStyle(.body).foregroundStyle(Palette.textSecondary)
            Spacer(minLength: Spacing.space3)
            value.textStyle(.bodyEmphasis).foregroundStyle(Palette.textPrimary)
        }
        .frame(minHeight: 48)
        .accessibilityElement(children: .combine)
    }
}
