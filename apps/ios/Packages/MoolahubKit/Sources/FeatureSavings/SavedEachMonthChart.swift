import Charts
import DesignSystem
import Domain
import SwiftUI

/// One bar of "Saved each month": a calendar month and what moved in.
struct MonthlySaved: Identifiable, Hashable, Sendable {
    let monthStart: Date
    /// Plotted as `Int` cents (never `Double` money).
    let cents: Int
    /// Axis label ("Oct").
    let label: String
    /// VoiceOver ("October 2026").
    let spokenMonth: String

    var id: Date { monthStart }
}

/// Builds the bars from a goal's `history` only (DESIGN.md v2 B3.11): the
/// last 6 calendar months including this one; y = the sum of positive,
/// not-failed `amountCents` in that month. When exactly 25 items came back
/// (the API's cap), months before the oldest returned item are dropped and
/// the chart says "Based on your latest 25 moves.".
struct SavedEachMonthData: Hashable, Sendable {
    static let historyCap = 25
    static let monthCount = 6

    let bars: [MonthlySaved]
    /// "Based on your latest 25 moves."
    let isCapped: Bool
    /// False: show the one sentence instead of a chart (B3.12).
    let hasPositiveHistory: Bool

    init(history: [GoalHistoryItem], now: Date = Date(), calendar: Calendar = .current) {
        let positive = history.filter { $0.amountCents > 0 && $0.status != .failed }
        hasPositiveHistory = !positive.isEmpty
        isCapped = history.count == Self.historyCap

        let thisMonth = calendar.dateInterval(of: .month, for: now)?.start ?? now
        var months: [Date] = (0..<Self.monthCount).reversed().compactMap {
            calendar.date(byAdding: .month, value: -$0, to: thisMonth)
        }
        if isCapped, let oldest = history.map(\.createdAt).min(),
           let oldestMonth = calendar.dateInterval(of: .month, for: oldest)?.start
        {
            months = months.filter { $0 >= oldestMonth }
        }

        bars = months.map { start in
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            let total = positive
                .filter { $0.createdAt >= start && $0.createdAt < end }
                .reduce(Int64(0)) { $0 + $1.amountCents }
            return MonthlySaved(
                monthStart: start,
                cents: Int(clamping: total),
                label: start.formatted(.dateTime.month(.abbreviated)),
                spokenMonth: start.formatted(.dateTime.month(.wide).year())
            )
        }
    }

    /// The tallest month (the latest of equal ones), which carries its value.
    var labelledBar: MonthlySaved? {
        guard let top = bars.map(\.cents).max(), top > 0 else { return nil }
        return bars.last { $0.cents == top }
    }
}

/// "Saved each month" (B3.11; A1.8 rule 7, ruling 29): Swift Charts
/// `BarMark`s 20 pt wide with square corners in `jadeFill`, one series; no
/// gridlines, no y-axis labels and no axis lines; the tallest bar carries its
/// value (`footnote` `textSecondary`, `wholeIfRound`) 4 pt above it; month
/// abbreviations under the bars. A 180 pt frame: 20 pt for the value over a
/// 160 pt plot (240 at accessibility sizes). No container. With no positive
/// history, one sentence in its place (B3.12).
struct SavedEachMonthChart: View {
    let data: SavedEachMonthData

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if data.hasPositiveHistory {
            VStack(alignment: .leading, spacing: 0) {
                chart
                if data.isCapped {
                    Text("Based on your latest 25 moves.")
                        .textStyle(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .padding(.top, Spacing.space2)
                }
            }
        } else {
            Text("Your monthly saving shows up here after your first move.")
                .textStyle(.subheadline)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("savings.chart.empty")
        }
    }

    private var chart: some View {
        let labelled = data.labelledBar
        let top = labelled?.cents ?? 1
        return Chart(data.bars) { bar in
            BarMark(
                x: .value("Month", bar.label),
                y: .value("Moved in", bar.cents),
                width: .fixed(20)
            )
            .foregroundStyle(Palette.jadeFill)
            .annotation(position: .top, spacing: Spacing.space1) {
                if bar.id == labelled?.id {
                    Text(Money(cents: Int64(bar.cents)).formatted(.wholeIfRound))
                        .textStyle(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textSecondary)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityLabel(bar.spokenMonth)
            .accessibilityValue("\(Money(cents: Int64(bar.cents)).accessibilityText()) moved in")
        }
        .chartYScale(domain: 0...max(top, 1))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let label = value.as(String.self) {
                        Text(label)
                            .textStyle(.footnote)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
            }
        }
        .padding(.top, 20)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 240 : 180)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Saved each month, last 6 months")
        .accessibilityIgnoresInvertColors(true)
        .accessibilityIdentifier("savings.chart")
    }
}
