import Domain
import SwiftUI

/// Plain values a GoalCard shows (DESIGN.md v2 A8.6). The goal's identity is
/// its own API `emoji` (raw, not the 12-icon mapping) on a tile tinted by the
/// API `color` (A1.5, A7.5).
public struct GoalCardModel: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// The API `emoji`, raw ("🛟" from the web stays "🛟").
    public let emoji: String?
    /// The API `color` ("jade" is the only value in the data).
    public let colorKey: String?
    public let saved: Money
    public let target: Money
    public let pace: GoalPace
    /// UTC-midnight deadline.
    public let deadline: Date
    /// Whether the saved figure can be drawn (SPEC §5.1, D-04): `.shown`,
    /// `.shownStale` ("May be out of date" in the pace slot, no next line) or
    /// `.unknown` ("Saved amount unavailable" in the figure's place).
    public let figureState: GoalFigureState
    /// The next step, already in words (rows draw `rowText`, tiles
    /// `tileText`); drawn only while the figure is `.shown`.
    public let nextLine: GoalNextLine?
    /// "Target date April 21, 2027." Read only by the tile's VoiceOver value.
    public let targetDateSpoken: String?

    public init(
        id: String, name: String, emoji: String?, colorKey: String?, saved: Money, target: Money,
        pace: GoalPace, deadline: Date, figureState: GoalFigureState = .shown, nextLine: GoalNextLine? = nil,
        targetDateSpoken: String? = nil
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.colorKey = colorKey
        self.saved = saved
        self.target = target
        self.pace = pace
        self.deadline = deadline
        self.figureState = figureState
        self.nextLine = nextLine
        self.targetDateSpoken = targetDateSpoken
    }

    /// Maps an API goal (pace computed on device, W9.1). A nil `figureState`
    /// comes from the per-goal flag alone (`GoalRowFigure.state(goal:
    /// summaryStale: false)`): the model never reads the summary, so callers
    /// that have one pass `GoalRowFigure.state(goal:summaryStale:)` and
    /// `GoalNextStep.line(goal:figure:now:calendar:)`.
    public init(
        _ goal: Goal, figureState: GoalFigureState? = nil, nextLine: GoalNextLine? = nil,
        now: Date = Date(), calendar: Calendar = .current
    ) {
        self.init(
            id: goal.id, name: goal.name, emoji: goal.emoji, colorKey: goal.color, saved: goal.saved, target: goal.target,
            pace: goal.pace(now: now, calendar: calendar), deadline: goal.deadline,
            figureState: figureState ?? GoalRowFigure.state(goal: goal, summaryStale: false),
            nextLine: nextLine,
            targetDateSpoken: GoalWords.targetDateSpoken(goal.deadline)
        )
    }

    /// Transitional (D-39): Home's pre-wave row mapping
    /// (`FeatureHome/HomeSections.swift`, `model(for:)`, its only caller) still
    /// marks every goal stale with this form while the summary's balance read
    /// failed. `true` is `.shownStale`. Lane H moves Home to `figureState`
    /// (`GoalRowFigure.state(goal:summaryStale:)`); delete this initializer
    /// and `mayBeOutOfDate` below in the same merge.
    public init(
        id: String, name: String, emoji: String?, colorKey: String?, saved: Money, target: Money,
        pace: GoalPace, deadline: Date, mayBeOutOfDate: Bool
    ) {
        self.init(
            id: id, name: name, emoji: emoji, colorKey: colorKey, saved: saved, target: target,
            pace: pace, deadline: deadline, figureState: mayBeOutOfDate ? .shownStale : .shown
        )
    }

    /// Transitional (D-39), for the same Home mapping: true whenever the
    /// figure is not plainly shown, so that mapping never turns an
    /// `.unknown` goal back into a drawn $0.00. Remove with the initializer above.
    public var mayBeOutOfDate: Bool { figureState != .shown }

    var percentText: String { GoalProgress.percentText(saved: saved, target: target) }
    var fraction: Double { GoalProgress.fraction(saved: saved, target: target) }

    /// The next line drawn: only for a `.shown` figure (§5.1).
    var shownNextLine: GoalNextLine? { figureState == .shown ? nextLine : nil }

    /// W10-SG-23: Domain's `GoalWords.figureSpoken` ("{saved} saved of
    /// {target}. {pct} percent. {pace}.", "May be out of date." in the pace's
    /// place, or "Saved amount unavailable. Target {target}."), then the next
    /// step for a `.shown` figure.
    var accessibilityValue: String {
        [GoalWords.figureSpoken(figureState, saved: saved, target: target, pace: pace), shownNextLine?.spoken]
            .compactMap { $0 }
            .joined(separator: " ")
    }
}

/// A goal (A8.6), in one of three layouts:
///
/// - `.row` (Home "Your goals", Move to goal "Choose a goal"): full width, the
///   52 pt `EmojiTile` at the gutter, text at x = 80; name (`bodyEmphasis`) and
///   saved (`amountRow`); "{percent} · {pace}" and "of {target}"; a 4 pt bar;
///   with a next line, "Next $381.82 this month" (`footnote`) 8 pt under the
///   bar. 86 pt min (111.3 with the next line). Wrap in a `Button` with
///   `RowButtonStyle()`; separate rows with a `divider` from x = 80 to
///   width − 16. At accessibility sizes it stacks.
/// - `.tile` (the Savings grid, SPEC §5.3): a tile, no outer padding; the next
///   line ("Next $381.82", one line) 2 pt under the pace line. Wrap in a
///   `Button` with `PressableCardButtonStyle(restingFill: Palette.surface)`,
///   which draws the fill (ruling 31). Tiles in a grid row share a height.
/// - `.detail` (Goal detail): the identity block for an `IdentityBand` (pass
///   `GoalTint.color(forAPIKey:)` as the band tint): the 72 pt tile and the
///   6 pt bar's track one step above the band (`GoalTint.bandRaised`: white in
///   light, `#16362A` / `#2C2C2C` in dark; premium bar DS-4), the saved
///   figure (`displayAmount`), "of {target}" and two `footnote` meta lines
///   ("{percent} · {pace}" and the caller's `dateLine`, "Target date Apr 21,
///   2027 · 18 weeks left").
///
/// Figure states (SPEC §5.1): `.shownStale` draws "May be out of date"
/// (`amberText`) as the pace word and no next line; `.unknown` draws
/// `exclamationmark.circle` and "Saved amount unavailable" (`amberText`) in
/// the figure's place (rows: line 2 leading, line 1's trailing slot empty;
/// tiles and the detail hero: the figure's slot), keeps "of {target}", leaves
/// the bar's slot as clear space and draws no percent, pace or next line.
///
/// One accessibility element: label "{name}", value W10-SG-23 ("{saved} saved
/// of {target}. {percent} percent. {pace}." plus the next step; tiles add the
/// target date; `.unknown` "Saved amount unavailable. Target {target}.");
/// `hint` from the caller ("Opens goal.", Choose a goal passes "Chooses this
/// goal."); identifiers from the caller.
public struct GoalCard: View {
    public enum Layout: Sendable { case tile, row, detail }

    let model: GoalCardModel
    let layout: Layout
    let hint: String
    let dateLine: String?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The unknown figure's symbol beside `subheadline` words (rows, tiles),
    /// on the `subheadline` token's own curve.
    @ScaledMetric(relativeTo: .footnote) private var unknownSymbolSize: CGFloat = 13
    /// The unknown figure's symbol beside `headline` words (the detail hero).
    @ScaledMetric(relativeTo: .callout) private var unknownHeroSymbolSize: CGFloat = 16
    /// `displayAmount`'s line height: the hero keeps its figure's slot when
    /// the figure is unknown (SPEC §5.1).
    @ScaledMetric(relativeTo: .largeTitle) private var heroLineHeight: CGFloat = 40.1

    public init(_ model: GoalCardModel, layout: Layout = .tile, hint: String = "Opens goal.", dateLine: String? = nil) {
        self.model = model
        self.layout = layout
        self.hint = hint
        self.dateLine = dateLine
    }

    public var body: some View {
        switch layout {
        case .row:
            Group {
                if dynamicTypeSize.isAccessibilitySize { rowStacked } else { row }
            }
            .padding(.horizontal, Spacing.screenGutter)
            .modifier(GoalCardAccessibility(label: model.name, value: model.accessibilityValue, hint: hint, isButton: true))
        case .tile:
            tile
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .tileStyle(fill: false)
                .modifier(GoalCardAccessibility(label: model.name, value: tileAccessibilityValue, hint: hint, isButton: true))
        case .detail:
            detail
                .modifier(GoalCardAccessibility(label: model.name, value: detailAccessibilityValue, hint: nil, isButton: false))
        }
    }

    private var isUnknown: Bool { model.figureState == .unknown }

    /// Tiles add the target date (the date is not drawn on tiles, D-08).
    private var tileAccessibilityValue: String {
        [model.accessibilityValue, model.targetDateSpoken].compactMap { $0 }.joined(separator: " ")
    }

    /// An unknown hero adds the date line it still draws.
    private var detailAccessibilityValue: String {
        guard isUnknown, let dateLine else { return model.accessibilityValue }
        return "\(model.accessibilityValue) \(dateLine)."
    }

    private var tileEmoji: some View {
        EmojiTile(emoji: model.emoji, colorKey: model.colorKey, fallbackName: model.name, size: .s52)
    }

    /// "{percent} · {pace}", or "May be out of date" as the pace word.
    private func paceText(_ token: TypeToken) -> PaceText {
        PaceText(model.pace, mayBeOutOfDate: model.figureState == .shownStale, percentText: model.percentText, token: token)
    }

    private var ofTarget: some View {
        Text("of \(model.target.formatted(.wholeIfRound))")
            .textStyle(.amountSmall)
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)
    }

    /// The 4 pt bar, or its slot as clear space while the figure is unknown.
    @ViewBuilder
    private var bar: some View {
        if isUnknown {
            Color.clear.frame(height: 4)
        } else {
            ProgressBar(fraction: model.fraction, height: 4, hasProgress: model.saved.isPositive)
        }
    }

    /// `exclamationmark.circle`, 4 pt, "Saved amount unavailable"
    /// (`GoalWords.savedAmountUnavailable`), in `amberText` (SPEC §5.1).
    private func unknownFigure(_ token: TypeToken, symbolSize: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space1) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: symbolSize, weight: .regular))
                .accessibilityHidden(true)
            Text(GoalWords.savedAmountUnavailable)
                .textStyle(token)
        }
        .foregroundStyle(Palette.amberText)
    }

    private func nextLineText(_ text: String) -> some View {
        Text(text)
            .textStyle(.footnote)
            .foregroundStyle(Palette.textSecondary)
    }

    // MARK: Row

    private var row: some View {
        HStack(alignment: .top, spacing: Spacing.space3) {
            tileEmoji
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    Text(model.name)
                        .textStyle(.bodyEmphasis)
                        .foregroundStyle(Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    if !isUnknown {
                        MoneyText(model.saved, style: .amountRow)
                            .layoutPriority(1)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: Spacing.space3) {
                    Group {
                        if isUnknown {
                            unknownFigure(.subheadline, symbolSize: unknownSymbolSize)
                        } else {
                            paceText(.subheadline)
                        }
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                    ofTarget
                        .layoutPriority(1)
                }
                .padding(.top, Spacing.space1)
                bar
                    .padding(.top, 10)
                if let nextLine = model.shownNextLine {
                    nextLineText(nextLine.rowText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, Spacing.space2)
                }
            }
        }
        .padding(.top, Spacing.space4)
        .padding(.bottom, Size.goalRowBottomPadding)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
    }

    private var rowStacked: some View {
        VStack(alignment: .leading, spacing: 0) {
            tileEmoji
            Text(model.name)
                .textStyle(.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space2)
            if isUnknown {
                unknownFigure(.subheadline, symbolSize: unknownSymbolSize)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space1)
                ofTarget
            } else {
                MoneyText(model.saved, style: .amountRow)
                    .padding(.top, Spacing.space1)
                ofTarget
                paceText(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space1)
            }
            bar
                .padding(.top, 10)
            if let nextLine = model.shownNextLine {
                nextLineText(nextLine.rowText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
        }
        .padding(.vertical, Spacing.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Tile (SPEC §5.3)

    private var tile: some View {
        VStack(alignment: .leading, spacing: 0) {
            tileEmoji
            Text(model.name)
                .textStyle(.bodyEmphasis)
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Spacing.space3)
            if isUnknown {
                unknownFigure(.subheadline, symbolSize: unknownSymbolSize)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space1)
            } else {
                MoneyText(model.saved, style: .amountCard)
                    .padding(.top, Spacing.space1)
            }
            ofTarget
                .padding(.top, 2)
            bar
                .padding(.top, Spacing.space3)
            if !isUnknown {
                paceText(.footnote)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Spacing.space2)
            }
            if let nextLine = model.shownNextLine {
                nextLineText(nextLine.tileText)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Detail

    private var detail: some View {
        VStack(alignment: .leading, spacing: 0) {
            EmojiTile(
                emoji: model.emoji, colorKey: model.colorKey, fallbackName: model.name, size: .s72,
                groundOverride: GoalTint.bandRaised(forAPIKey: model.colorKey)
            )
            Group {
                if isUnknown {
                    unknownFigure(.headline, symbolSize: unknownHeroSymbolSize)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: heroLineHeight, alignment: .leading)
                } else {
                    MoneyText(model.saved, style: .displayAmount)
                }
            }
            .padding(.top, Spacing.space4)
            // B3.11: "of {target}" 4 pt under the saved figure.
            ofTarget
                .padding(.top, Spacing.space1)
            Group {
                if isUnknown {
                    Color.clear.frame(height: 6)
                } else {
                    ProgressBar(
                        fraction: model.fraction, height: 6, hasProgress: model.saved.isPositive,
                        track: GoalTint.bandRaised(forAPIKey: model.colorKey)
                    )
                }
            }
            .padding(.top, Spacing.space4)
            VStack(alignment: .leading, spacing: 2) {
                if !isUnknown {
                    paceText(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let dateLine {
                    Text(dateLine.keepingMiddleDotsAtLineEnds)
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, Spacing.space2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GoalCardAccessibility: ViewModifier {
    let label: String
    let value: String
    let hint: String?
    let isButton: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityHint(hint ?? "")
            .accessibilityAddTraits(isButton ? .isButton : [])
    }
}

#Preview("Goal cards") {
    let deadline = APIDate.parse("2027-03-01")!
    let fund = GoalCardModel(
        id: "1", name: "Emergency fund", emoji: "\u{2602}\u{FE0F}", colorKey: "jade", saved: Money(cents: 125_000),
        target: Money(cents: 300_000), pace: .onTrack, deadline: deadline,
        nextLine: GoalNextLine(.next(Money(cents: 38_182), .monthly)), targetDateSpoken: "Target date March 1, 2027."
    )
    let laptop = GoalCardModel(id: "2", name: "New laptop", emoji: "\u{1F4BB}", colorKey: "jade", saved: Money(cents: 33_000), target: Money(cents: 120_000), pace: .behind(periods: 1, frequency: .monthly), deadline: deadline, figureState: .shownStale)
    let unread = GoalCardModel(id: "3", name: "Rent", emoji: "\u{1F3E0}", colorKey: "jade", saved: Money(cents: 0), target: Money(cents: 90_000), pace: .onTrack, deadline: deadline, figureState: .unknown)
    ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button {} label: { GoalCard(fund) }.buttonStyle(PressableCardButtonStyle())
                Button {} label: { GoalCard(laptop) }.buttonStyle(PressableCardButtonStyle())
            }
            .padding(.horizontal, 16)
            HStack(alignment: .top, spacing: 12) {
                Button {} label: { GoalCard(unread) }.buttonStyle(PressableCardButtonStyle())
                Color.clear
            }
            .padding(.horizontal, 16)
            Button {} label: { GoalCard(fund, layout: .row) }.buttonStyle(RowButtonStyle())
            Button {} label: { GoalCard(unread, layout: .row) }.buttonStyle(RowButtonStyle())
            IdentityBand(tint: GoalTint.color(forAPIKey: "jade")) {
                GoalCard(fund, layout: .detail, dateLine: "Target date Mar 1, 2027 \u{00B7} 18 weeks left")
            }
        }
    }
    .moolaCanvas()
}
