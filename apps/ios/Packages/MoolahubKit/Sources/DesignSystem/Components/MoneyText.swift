import Domain
import SwiftUI

/// An amount standing on its own (DESIGN.md v2 A8.4, W4): fixed en_US
/// formatting, SF Pro Rounded with tabular digits through its token, the sign
/// and colour rules of A1.8 rule 3, full-name VoiceOver label ("1,240.50 US
/// dollars", with "plus"/"minus" for direction). Hero figures never truncate:
/// `lineLimit(1)` and `minimumScaleFactor(0.6)`. A value that changes while
/// visible rolls with `numericText` (`Motion.figure`); nothing counts up on
/// appear (A5.5). Pass nil when the amount is unavailable: it renders nothing
/// and the parent shows an error, never `$0.00`.
///
/// An amount inside a sentence is not a `MoneyText`: format it with
/// `money.formatted(...)` inside the sentence's `Text` and `.monospacedDigit()`.
public struct MoneyText: View {
    let money: Money?
    let presentation: MoneyPresentation
    let direction: MoneyDirection
    let style: TypeToken
    let color: Color?
    let strikethrough: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// - Parameters:
    ///   - direction: `.moneyIn` draws "+$" in `jadeText`; `.moneyOut` draws "−$" in `textPrimary`.
    ///   - color: overrides the rule colour (rare; a failed amount passes `strikethrough`).
    ///   - strikethrough: a failed move: `textTertiary` with a strikethrough (A1.8 rule 3).
    public init(
        _ money: Money?,
        presentation: MoneyPresentation = .exact,
        direction: MoneyDirection = .none,
        style: TypeToken = .amountRow,
        color: Color? = nil,
        strikethrough: Bool = false
    ) {
        self.money = money
        self.presentation = presentation
        self.direction = direction
        self.style = style
        self.color = color
        self.strikethrough = strikethrough
    }

    public var body: some View {
        if let money {
            let isHero = style.isDisplayAmount || style == .amountCard
            Text(money.formatted(presentation, direction: direction))
                .strikethrough(strikethrough)
                .textStyle(style)
                .foregroundStyle(resolvedColor(for: money))
                .lineLimit(1)
                .minimumScaleFactor(isHero ? 0.6 : 1)
                .contentTransition(reduceMotion ? .opacity : .numericText(value: Double(money.cents)))
                .animation(Motion.animation(Motion.figure, reduceMotion: reduceMotion), value: money.cents)
                .accessibilityLabel(money.accessibilityText(direction: direction))
        }
    }

    private func resolvedColor(for money: Money) -> Color {
        if strikethrough { return color ?? Palette.textTertiary }
        if let color { return color }
        return direction == .moneyIn && money.cents != 0 ? Palette.jadeText : Palette.textPrimary
    }
}

#Preview("MoneyText") {
    VStack(alignment: .leading, spacing: 12) {
        MoneyText(Money(cents: 302_012), style: .displayHero)
        MoneyText(Money(cents: 500_000), presentation: .wholeIfRound, style: .amountCard)
        MoneyText(Money(cents: 5_000), direction: .moneyIn)
        MoneyText(Money(cents: 2_000), direction: .moneyOut)
        MoneyText(Money(cents: 2_000), direction: .moneyOut, strikethrough: true)
        MoneyText(Money(cents: 0), style: .amountRow)
    }
    .padding()
    .moolaCanvas()
}
