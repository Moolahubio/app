import Domain
import SwiftUI

/// Home's balance (DESIGN.md v2 A8.2): no container, the balance as type on
/// the page (the caller places it at the gutter). "Total balance"
/// (`subheadline` `textSecondary`), the total (`displayHero`), "Available … ·
/// In goals …", the processing and stale lines when they apply; 20 pt; two
/// 80 pt action tiles ("Add money", "Move to goal") 12 pt apart; 4 pt; the
/// link row ("Cash out", "History"). One column at accessibility sizes.
public struct BalanceCard: View {
    public struct Figures: Hashable, Sendable {
        public let total: Money
        public let available: Money
        public let inGoals: Money
        public let pending: Money
        /// `balanceUnavailable`: show the amounts with the "last known" line.
        public let isStale: Bool

        public init(total: Money, available: Money, inGoals: Money, pending: Money = .zero, isStale: Bool = false) {
            self.total = total
            self.available = available
            self.inGoals = inGoals
            self.pending = pending
            self.isStale = isStale
        }

        public init(_ summary: DashboardSummary) {
            self.init(
                total: summary.total, available: summary.available, inGoals: summary.inGoals,
                pending: summary.pending, isStale: summary.balanceUnavailable == true
            )
        }
    }

    public enum State {
        /// The label shows; the amounts are skeletons; tiles and links are disabled.
        case loading
        case loaded(Figures)
        /// Nothing loaded (ruling 28): "We couldn't load your balance", the W6
        /// screen message and one small "Try again". The screen's only retry.
        case loadFailed(message: String, isRetrying: Bool, retry: () -> Void)
    }

    public struct Actions {
        public var addMoney: () -> Void
        public var moveToGoal: () -> Void
        public var cashOut: () -> Void
        public var history: () -> Void

        public init(addMoney: @escaping () -> Void, moveToGoal: @escaping () -> Void, cashOut: @escaping () -> Void, history: @escaping () -> Void) {
            self.addMoney = addMoney
            self.moveToGoal = moveToGoal
            self.cashOut = cashOut
            self.history = history
        }
    }

    let state: State
    let actions: Actions

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var lineSymbolSize: CGFloat = 13

    public init(state: State, actions: Actions) {
        self.state = state
        self.actions = actions
    }

    private var isLoaded: Bool {
        if case .loaded = state { return true }
        return false
    }

    private var isLoading: Bool {
        if case .loading = state { return true }
        return false
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            actionTiles
                .padding(.top, Spacing.space5)
            linkRow
                .padding(.top, Spacing.space1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var header: some View {
        switch state {
        case .loading:
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text("Total balance")
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                LoadingPlaceholder(label: "Loading your balance\u{2026}") {
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        // `displayHero` cap height (28.2, capped at AX2 like the figure) and
                        // the `subheadline` sub-line (9.9), each scaling with its style (A5.7).
                        SkeletonBar(widthFraction: 0.6, height: TypeToken.displayHero.capHeight, relativeTo: TypeToken.displayHero.relativeTo)
                            .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                            .padding(.vertical, 9)
                        SkeletonBar(widthFraction: 0.7, height: TypeToken.subheadline.capHeight, relativeTo: TypeToken.subheadline.relativeTo)
                    }
                }
            }
        case .loaded(let figures):
            loadedHeader(figures)
        case .loadFailed(let message, let isRetrying, let retry):
            failedHeader(message: message, isRetrying: isRetrying, retry: retry)
        }
    }

    private func loadedHeader(_ figures: Figures) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Spacing.space1) {
                Text("Total balance")
                    .textStyle(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                MoneyText(figures.total, style: .displayHero)
                Text(verbatim: "Available \(figures.available.formatted())\(String.lineEndMiddleDot)In goals \(figures.inGoals.formatted())")
                    .textStyle(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Total balance")
            .accessibilityValue(
                "\(figures.total.accessibilityText()). Available \(figures.available.accessibilityText()). In goals \(figures.inGoals.accessibilityText())."
            )
            if figures.pending.cents > 0 {
                statusLine(symbol: "clock", color: Palette.textSecondary) {
                    Text("\(figures.pending.formatted()) processing").monospacedDigit()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(figures.pending.accessibilityText()) processing")
                .padding(.top, Spacing.space2)
            }
            if figures.isStale {
                statusLine(symbol: "exclamationmark.circle", color: Palette.amberText) {
                    Text("Showing your last known balance. We'll update it shortly.")
                }
                .accessibilityElement(children: .combine)
                .padding(.top, Spacing.space2)
            }
        }
    }

    private func statusLine(symbol: String, color: Color, @ViewBuilder text: () -> Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
            Image(systemName: symbol)
                .font(.system(size: lineSymbolSize, weight: .regular))
                .accessibilityHidden(true)
            text()
                .textStyle(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(color)
    }

    private func failedHeader(message: String, isRetrying: Bool, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Total balance")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
            Text("We couldn't load your balance")
                .textStyle(.headline)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space1)
            Text(message)
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space1)
            MoolaButton("Try again", kind: .secondary, size: .small, loadingTitle: "Trying again\u{2026}", isLoading: isRetrying, action: retry)
                .padding(.top, Spacing.space3)
        }
    }

    @ViewBuilder
    private var actionTiles: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Spacing.gridGap))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.gridGap))
        layout {
            QuickActionButton(title: "Add money", systemImage: "plus.circle", action: actions.addMoney)
                .disabled(isLoading)
            QuickActionButton(title: "Move to goal", systemImage: "tray.and.arrow.down", action: actions.moveToGoal)
                .disabled(!isLoaded)
                .accessibilityHint(isLoaded || isLoading ? "" : "Available when your balance loads.")
        }
    }

    /// "Cash out" and "History" (A8.3, ruling 53): ink links with leading
    /// symbols, 24 pt apart, on a 44 pt row; History moves under Cash out
    /// when they don't fit on one line.
    private var linkRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.space6) {
                cashOutLink
                historyLink
            }
            VStack(alignment: .leading, spacing: 0) {
                cashOutLink
                historyLink
            }
        }
        .disabled(isLoading)
    }

    private var cashOutLink: some View {
        TextLinkButton("Cash out", systemImage: "arrow.up.right", action: actions.cashOut)
    }

    private var historyLink: some View {
        TextLinkButton("History", systemImage: "list.bullet.rectangle.portrait", action: actions.history)
    }
}

/// An action tile (A8.3): one column of a 2-column row,
/// 80 pt min, `surface`, radius 14; a 22 pt symbol centred above the label
/// (`headline`, centred, up to 2 lines), 8 pt apart, 12 pt padding. Pressed
/// `fillPressed` and 0.98; disabled symbol and label `textTertiary`.
/// Increase Contrast adds a 1 pt `cardBorder`. One button labelled with the
/// visible text ("Add money", "Move to goal": tested).
public struct QuickActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    public init(title: String, systemImage: String, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            QuickActionLabel(title: title, systemImage: systemImage)
        }
        .buttonStyle(PressableCardButtonStyle(restingFill: Palette.surface))
        .accessibilityLabel(title)
    }
}

private struct QuickActionLabel: View {
    let title: String
    let systemImage: String

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .callout) private var symbolSize: CGFloat = 22
    /// One symbol slot for every tile, so the labels of two tiles sit on one
    /// baseline although `tray.and.arrow.down` is taller than `plus.circle`.
    @ScaledMetric(relativeTo: .callout) private var symbolSlot: CGFloat = 26

    var body: some View {
        VStack(spacing: Spacing.space2) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .regular))
                .frame(height: symbolSlot)
                .accessibilityHidden(true)
            Text(title)
                .textStyle(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isEnabled ? Palette.textPrimary : Palette.textTertiary)
        .padding(Spacing.space3)
        .frame(maxWidth: .infinity, minHeight: 80)
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.cardBorder, lineWidth: Size.hairline)
            }
        }
        .contentShape(Rectangle())
    }
}

#Preview("Balance") {
    let actions = BalanceCard.Actions(addMoney: {}, moveToGoal: {}, cashOut: {}, history: {})
    ScrollView {
        VStack(alignment: .leading, spacing: 40) {
            BalanceCard(
                state: .loaded(.init(total: Money(cents: 302_012), available: Money(cents: 148_076), inGoals: Money(cents: 153_936), pending: Money(cents: 2_500))),
                actions: actions
            )
            BalanceCard(state: .loading, actions: actions)
            BalanceCard(state: .loadFailed(message: "We couldn't reach MoolaHub. Check your connection and try again.", isRetrying: false, retry: {}), actions: actions)
        }
        .padding(16)
    }
    .moolaCanvas()
}
