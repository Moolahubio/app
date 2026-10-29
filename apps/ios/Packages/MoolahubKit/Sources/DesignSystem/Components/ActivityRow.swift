import Domain
import SwiftUI

/// One money move in a list (DESIGN.md v2 A8.19; rulings 25 and 46). Full
/// width with its content at the gutter, 64 pt min, 12 pt vertical padding.
/// A leading 18 pt symbol (W9.4, `textSecondary`) in a 24 pt slot with the
/// text at x = 52, or no symbol and the text at the gutter (Home's Recent
/// activity and pay-in rows pass `symbol: nil`). Title (`headline`, 16
/// Medium since ruling 56; the server's `description`, one line); 2 pt; the
/// caller's sub-line (`subheadline` `textSecondary`) followed by
/// " · Processing…" (grey) or " · Didn't go through" (`redText`). Trailing
/// amount (`amountRow`) on the title's first baseline: "+$" `jadeText` in,
/// "−$" `textPrimary` out, a failed move `textTertiary` struck through; none
/// when the API sends no amount. No dividers. At accessibility sizes it
/// stacks (symbol, title, amount, sub-line). With an `action` it is a
/// `RowButtonStyle` button ("Shows details."), which opens the move's
/// receipt (`AppSheet.activityReceipt`).
///
/// VoiceOver: "{word}. {description}. {plus/minus} {amount}. {status}.
/// {time}."; the `.titleFirst` style (pay-ins, `symbol: nil`, unsigned
/// amount) reads "Round {n}, {amount}. {status}. {date}.".
///
/// The status is a `PayInStatus` (savings-groups §3.5): every `MoveStatus`
/// initializer wraps its value in `.known(_)`; the pay-in overload also takes
/// `.unavailable` (no Activity move matched), drawn as " · Status
/// unavailable" (grey: nothing was refused), the amount in `textPrimary`,
/// unsigned, never struck through.
public struct ActivityRow: View {
    public enum LabelStyle: Sendable {
        /// Activity, Home and goal history rows: signed, coloured amounts.
        case standard
        /// Pay-in rows on Group detail: unsigned `textPrimary` amount; the label begins with the title.
        case titleFirst
    }

    let kind: ActivityKind
    let title: String
    let subtitle: String
    let amount: Money?
    let status: PayInStatus
    let symbol: String?
    let labelStyle: LabelStyle
    let action: (() -> Void)?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 18
    @ScaledMetric(relativeTo: .callout) private var symbolSlot: CGFloat = 24

    /// - Parameters:
    ///   - title: the server's `description` (already plain language).
    ///   - subtitle: the time (Activity), the B2 D7 day (Home) or the W5 date and time (history, pay-ins).
    ///   - amount: signed relative to the balance (positive = in). Nil hides it.
    ///   - symbol: nil for no symbol (Home, pay-ins); `kind.symbolName` otherwise.
    public init(
        kind: ActivityKind,
        title: String,
        subtitle: String,
        amount: Money?,
        status: MoveStatus,
        symbol: String?,
        labelStyle: LabelStyle = .standard,
        action: (() -> Void)? = nil
    ) {
        self.init(
            kind: kind, title: title, subtitle: subtitle, amount: amount, status: PayInStatus.known(status),
            symbol: symbol, labelStyle: labelStyle, action: action
        )
    }

    /// A pay-in row whose status may be unknown (savings-groups §3.5, SPEC
    /// §8.3): `.unavailable` reads "Status unavailable"; `.known(_)` draws
    /// exactly as the `MoveStatus` initializers do.
    public init(
        kind: ActivityKind,
        title: String,
        subtitle: String,
        amount: Money?,
        status: PayInStatus,
        symbol: String?,
        labelStyle: LabelStyle = .titleFirst,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.amount = amount
        self.status = status
        self.symbol = symbol
        self.labelStyle = labelStyle
        self.action = action
    }

    /// A row with its kind's symbol (W9.4).
    public init(
        kind: ActivityKind,
        title: String,
        subtitle: String,
        amount: Money?,
        status: MoveStatus,
        labelStyle: LabelStyle = .standard,
        action: (() -> Void)? = nil
    ) {
        self.init(
            kind: kind, title: title, subtitle: subtitle, amount: amount, status: status,
            symbol: kind.symbolName, labelStyle: labelStyle, action: action
        )
    }

    /// An API activity item with its kind's symbol; the sub-line defaults to the time.
    public init(_ item: ActivityItem, subtitle: String? = nil, action: (() -> Void)? = nil) {
        self.init(
            kind: item.kind, title: item.description,
            subtitle: subtitle ?? item.createdAt.formatted(.dateTime.hour().minute()),
            amount: item.amount, status: item.status, symbol: item.kind.symbolName, action: action
        )
    }

    /// An API activity item with an explicit symbol (`nil`: Home's rows, no symbol).
    public init(_ item: ActivityItem, subtitle: String? = nil, symbol: String?, action: (() -> Void)? = nil) {
        self.init(
            kind: item.kind, title: item.description,
            subtitle: subtitle ?? item.createdAt.formatted(.dateTime.hour().minute()),
            amount: item.amount, status: item.status, symbol: symbol, action: action
        )
    }

    private var direction: MoneyDirection {
        guard labelStyle == .standard, let amount else { return .none }
        return amount.cents > 0 ? .moneyIn : (amount.cents < 0 ? .moneyOut : .none)
    }

    private var isFailed: Bool { status == .known(.failed) }

    private var magnitude: Money? {
        amount.map { Money(cents: $0.cents == .min ? .max : abs($0.cents)) }
    }

    public var body: some View {
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var standard: some View {
        HStack(alignment: .center, spacing: Spacing.space3) {
            if symbol != nil {
                glyph.frame(width: symbolSlot, height: symbolSlot)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    titleText
                        .textStyle(.headline)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    amountText
                        .layoutPriority(1)
                }
                statusLine
            }
        }
        .padding(.vertical, Spacing.space3)
        .frame(minHeight: 64)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Spacing.space1) {
            if symbol != nil {
                glyph
            }
            titleText
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            amountText
            statusLine
        }
        .padding(.vertical, Spacing.space3)
    }

    /// The title as drawn: a pay-in's "{group} · round {n}" keeps its dot at
    /// the end of a line when it wraps at accessibility sizes. The row's
    /// spoken label is built from the plain title.
    private var titleText: Text {
        Text(verbatim: title.keepingMiddleDotsAtLineEnds)
    }

    private var glyph: some View {
        Image(systemName: symbol ?? kind.symbolName)
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(Palette.textSecondary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var amountText: some View {
        if let magnitude {
            MoneyText(
                magnitude,
                direction: direction,
                style: .amountRow,
                color: labelStyle == .titleFirst && !isFailed ? Palette.textPrimary : nil,
                strikethrough: isFailed
            )
        }
    }

    /// One `Text` built by interpolation (A2.5 rule 10), so it wraps as one line.
    private var statusLine: some View {
        let suffix: Text = switch status {
        case .known(.processing): Text(verbatim: "\(String.lineEndMiddleDot)\(MoveStatus.processing.label)").foregroundStyle(Palette.textSecondary)
        case .known(.failed): Text(verbatim: "\(String.lineEndMiddleDot)\(MoveStatus.failed.label)").foregroundStyle(Palette.redText)
        case .known(.done): Text(verbatim: "")
        case .unavailable: Text(verbatim: "\(String.lineEndMiddleDot)\(status.accessibilityLabel)").foregroundStyle(Palette.textSecondary)
        }
        return Text("\(Text(subtitle).foregroundStyle(Palette.textSecondary))\(suffix)")
            .textStyle(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var accessibilityText: String {
        switch labelStyle {
        case .standard:
            var parts = [kind.spokenWord, title]
            if let magnitude {
                parts.append(magnitude.accessibilityText(direction: direction))
            }
            parts.append(status.accessibilityLabel)
            parts.append(subtitle)
            return parts.joined(separator: ". ") + "."
        case .titleFirst:
            var first = title
            if let magnitude {
                first += ", \(magnitude.accessibilityText())"
            }
            return [first, status.accessibilityLabel, subtitle].joined(separator: ". ") + "."
        }
    }
}

#if DEBUG
#Preview("Activity rows") {
    VStack(spacing: 0) {
        ActivityRow(kind: .deposit, title: "Test money added", subtitle: "9:41 AM", amount: Money(cents: 10_000), status: .done) {}
        ActivityRow(kind: .goalAllocate, title: "Moved to Emergency fund", subtitle: "9:12 AM", amount: Money(cents: -5_000), status: .processing)
        ActivityRow(kind: .contribution, title: "Family susu \u{00B7} round 3", subtitle: "Yesterday", amount: Money(cents: -10_000), status: .failed, symbol: nil)
        ActivityRow(kind: .contribution, title: "Round 1", subtitle: "Oct 12 at 2:05 PM", amount: Money(cents: -2_040), status: .done, symbol: nil, labelStyle: .titleFirst)
        ActivityRow(kind: .contribution, title: "Round 2", subtitle: "Oct 19 at 2:05 PM", amount: Money(cents: -2_040), status: PayInStatus.unavailable, symbol: nil)
    }
    .moolaCanvas()
}
#endif
