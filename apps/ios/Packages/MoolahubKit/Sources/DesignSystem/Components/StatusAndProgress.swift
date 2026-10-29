import Domain
import SwiftUI

/// Pill tones (DESIGN.md v2 A8.10): jade, amber, red, neutral.
public enum PillTone: Sendable {
    case jade, amber, red, neutral

    var background: Color {
        switch self {
        case .jade: Palette.jadeTint
        case .amber: Palette.amberTint
        case .red: Palette.redTint
        case .neutral: Palette.fill
        }
    }

    var foreground: Color {
        switch self {
        case .jade: Palette.jadeText
        case .amber: Palette.amberText
        case .red: Palette.redText
        case .neutral: Palette.textSecondary
        }
    }
}

/// A text-only status pill, used only where the status is the point (A8.10):
/// the receipt's Status value, "Paid in this round", "Verified", "Invited".
/// Everywhere else status is a word (`PaceText`, `textSecondary` words).
/// Capsule, min height 22, 8 pt side padding, `footnoteEmphasis`, never
/// truncated (when even one line cannot fit, it wraps in a rounded rectangle).
public struct StatusPill: View {
    let label: String
    let tone: PillTone
    let spokenLabel: String?

    public init(_ label: String, tone: PillTone, accessibilityLabel: String? = nil) {
        self.label = label
        self.tone = tone
        self.spokenLabel = accessibilityLabel
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            pill(wraps: false)
                .fixedSize()
            pill(wraps: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel ?? label)
    }

    private func pill(wraps: Bool) -> some View {
        Text(label)
            .textStyle(.footnoteEmphasis)
            .lineLimit(wraps ? nil : 1)
            .fixedSize(horizontal: false, vertical: wraps)
            .foregroundStyle(tone.foreground)
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, wraps ? 3 : 0)
            .frame(minHeight: 22)
            .background(tone.background, in: RoundedRectangle(cornerRadius: wraps ? Radius.small : 11, style: .continuous))
    }
}

extension StatusPill {
    /// A money move's status (J0.5): Done jade, Processing… neutral, Didn't go through red.
    public init(status: MoveStatus) {
        switch status {
        case .done: self.init(status.label, tone: .jade, accessibilityLabel: status.accessibilityLabel)
        case .processing: self.init(status.label, tone: .neutral, accessibilityLabel: status.accessibilityLabel)
        case .failed: self.init(status.label, tone: .red, accessibilityLabel: status.accessibilityLabel)
        }
    }
}

/// A goal's pace as a coloured word (A8.10, W9.1): "Goal reached" `jadeText`,
/// "On track" `textSecondary`, "{n} … behind" and "Past target date"
/// `amberText`; "May be out of date" (amber) replaces the word when the
/// goal's balance could not be read. Optionally preceded by "{percent} · " in
/// `textSecondary` (one `Text` built by interpolation, A2.5 rule 10). Size from
/// its context: `subheadline` in rows, `footnote` in tiles and headers.
/// Cross-fades when the word changes (A5.5).
public struct PaceText: View {
    let pace: GoalPace
    let mayBeOutOfDate: Bool
    let percentText: String?
    let token: TypeToken

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(_ pace: GoalPace, mayBeOutOfDate: Bool = false, percentText: String? = nil, token: TypeToken = .subheadline) {
        self.pace = pace
        self.mayBeOutOfDate = mayBeOutOfDate
        self.percentText = percentText
        self.token = token
    }

    /// The word shown ("On track", "May be out of date", …).
    public var word: String { mayBeOutOfDate ? GoalWords.mayBeOutOfDate : pace.label }

    /// The word's colour.
    public var color: Color {
        if mayBeOutOfDate { return Palette.amberText }
        switch pace {
        case .reached: return Palette.jadeText
        case .onTrack: return Palette.textSecondary
        case .pastTargetDate, .behind: return Palette.amberText
        }
    }

    public var body: some View {
        Group {
            if let percentText {
                Text("\(Text(verbatim: "\(percentText)\(String.lineEndMiddleDot)").foregroundStyle(Palette.textSecondary))\(Text(word).foregroundStyle(color))")
            } else {
                Text(word).foregroundStyle(color)
            }
        }
        .textStyle(token)
        .contentTransition(.opacity)
        .animation(Motion.animation(Motion.standard, reduceMotion: reduceMotion), value: word)
    }
}

/// Capsule progress bar (A8.7): `progressTrack` track (`canvas` on an identity
/// band), `jadeFill` fill. Height 4 in rows, tiles and group cards; 6 in detail
/// headers and save-together progress. A non-zero amount shows at least the
/// bar's height of fill. No animation on appear; a value that changes while
/// visible animates its width with `Motion.figure` (none under Reduce Motion).
public struct ProgressBar: View {
    let fraction: Double
    let height: CGFloat
    let hasProgress: Bool
    let track: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rowIsPressed) private var rowIsPressed

    /// - Parameters:
    ///   - fraction: 0…1 (`GoalProgress.fraction`), capped at 1.
    ///   - hasProgress: true when the saved amount is above zero.
    ///   - track: `GoalTint.bandRaised(forAPIKey:)` on an identity band (B3.11, A1.5).
    public init(fraction: Double, height: CGFloat = 4, hasProgress: Bool? = nil, track: Color = Palette.progressTrack) {
        self.fraction = min(1, max(0, fraction.isFinite ? fraction : 0))
        self.height = height
        self.hasProgress = hasProgress ?? (fraction > 0)
        self.track = track
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // In a pressed row the track would match the press fill.
                Capsule().fill(rowIsPressed && track == Palette.progressTrack ? Palette.canvas : track)
                Capsule()
                    .fill(Palette.jadeFill)
                    .frame(width: fillWidth(total: geometry.size.width))
            }
            .animation(reduceMotion ? nil : Motion.figure, value: fraction)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((fraction * 100).rounded(.down))) percent")
    }

    private func fillWidth(total: CGFloat) -> CGFloat {
        guard hasProgress else { return 0 }
        return min(total, max(height, total * CGFloat(fraction)))
    }
}

#Preview("Pills, pace and progress") {
    VStack(alignment: .leading, spacing: 12) {
        StatusPill(status: .done)
        StatusPill(status: .processing)
        StatusPill(status: .failed)
        StatusPill("Paid in this round", tone: .jade)
        PaceText(.onTrack, percentText: "41%")
        PaceText(.behind(periods: 2, frequency: .weekly), percentText: "12%")
        PaceText(.reached, percentText: "100%", token: .footnote)
        PaceText(.onTrack, mayBeOutOfDate: true)
        ProgressBar(fraction: 0.42)
        ProgressBar(fraction: 0.001, height: 6)
        ProgressBar(fraction: 0)
    }
    .padding()
    .moolaCanvas()
}
