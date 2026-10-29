import Foundation

// The one goal figure rule (SPEC §5.1): every surface that draws a goal's saved
// amount (Home rows, Savings tiles and total, Goal detail, Choose a goal) asks
// `GoalRowFigure` whether the figure is real, and `GoalNextStep` for the next
// line. A failed balance read is never drawn as $0.00.

/// Whether a goal's saved figure can be drawn.
public enum GoalFigureState: Hashable, Sendable {
    /// The figure is the API's: draw it with the pace word and the next step.
    case shown
    /// The figure may be understated (the summary's read failed on a server
    /// without the per-goal flag): draw it with "May be out of date", no next
    /// step.
    case shownStale
    /// No real figure: "Saved amount unavailable" in its place, no percent,
    /// no bar fill, no pace word, no next step.
    case unknown
}

public enum GoalRowFigure {
    /// The per-goal `balanceUnavailable` decides when the server sends it
    /// (`true` is unknown whatever `savedCents` says: the server only sends it
    /// with a placeholder 0). Without it, `summaryStale`
    /// (`DashboardSummary.balanceUnavailable == true` from the same refresh)
    /// makes a saved figure stale and a zero unknown.
    public static func state(goal: Goal, summaryStale: Bool) -> GoalFigureState {
        switch goal.balanceUnavailable {
        case true?: return .unknown
        case false?: return .shown
        case nil:
            guard summaryStale else { return .shown }
            return goal.savedCents > 0 ? .shownStale : .unknown
        }
    }
}

/// A goal's next step, already in words (W10-SG-05, W10-SG-06, W10-SG-23).
public struct GoalNextLine: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The plan's next step and the goal's saving frequency.
        case next(Money, GoalFrequency)
        /// Past the target date: what is left to reach the target.
        case toGo(Money)
    }

    public let kind: Kind

    public init(_ kind: Kind) {
        self.kind = kind
    }

    /// Rows and Goal detail: "Next $381.82 this month" (U+00A0 after "Next" and
    /// between "this" and the period word); past the date "$1,750 to go".
    public var rowText: String {
        switch kind {
        case let .next(amount, frequency):
            "Next\u{00A0}\(amount.formatted()) \(Self.periodPhrase(frequency, space: Self.noBreakSpace))"
        case let .toGo(amount):
            Self.toGoText(amount)
        }
    }

    /// Tiles: "Next $381.82" (the period word moves to the VoiceOver value);
    /// past the date "$1,750 to go".
    public var tileText: String {
        switch kind {
        case let .next(amount, _):
            "Next\u{00A0}\(amount.formatted())"
        case let .toGo(amount):
            Self.toGoText(amount)
        }
    }

    /// "Next step 381.82 US dollars this month." or "1,750.00 US dollars to go."
    public var spoken: String {
        switch kind {
        case let .next(amount, frequency):
            "Next step \(amount.accessibilityText()) \(Self.periodPhrase(frequency, space: Self.space))."
        case let .toGo(amount):
            "\(amount.accessibilityText()) to go."
        }
    }

    private static let noBreakSpace = "\u{00A0}"
    private static let space = " "

    private static func toGoText(_ amount: Money) -> String {
        "\(amount.formatted(.wholeIfRound)) to go"
    }

    private static func periodPhrase(_ frequency: GoalFrequency, space: String) -> String {
        switch frequency {
        case .daily: "today"
        case .weekly: "this\(space)week"
        case .monthly: "this\(space)month"
        }
    }
}

public enum GoalNextStep {
    /// Only for `.shown` figures. Nil when the goal is reached (the pace word
    /// says "Goal reached"); `.toGo(target − saved)` past the target date;
    /// otherwise the plan's next step, the same `ContributionPlan` call as Goal
    /// detail's "Your plan" and Move to goal's suggested preset.
    public static func line(goal: Goal, figure: GoalFigureState, now: Date, calendar: Calendar) -> GoalNextLine? {
        guard figure == .shown, goal.savedCents < goal.targetCents else { return nil }
        if now > goal.deadline {
            return GoalNextLine(.toGo(goal.target - goal.saved))
        }
        let frequency = goal.goalFrequency
        let periods = ContributionPlan.periodsBetween(goal.createdAt, goal.deadline, frequency: frequency, calendar: calendar)
        let plan = ContributionPlan.progressivePlan(targetCents: goal.targetCents, periods: periods)
        guard let next = ContributionPlan.nextContribution(plan: plan, savedCents: goal.savedCents) else { return nil }
        return GoalNextLine(.next(Money(cents: next.amountCents), frequency))
    }
}

public enum GoalWords {
    /// W10-SG-07: an unknown figure's words, in the figure's place on every
    /// surface (SPEC §5.1).
    public static let savedAmountUnavailable = "Saved amount unavailable"

    /// A possibly stale figure's pace word (A8.10, SPEC §5.1).
    public static let mayBeOutOfDate = "May be out of date"

    /// W10-SG-23, a goal's figure as VoiceOver reads it (the label is the
    /// goal's name). `.shown`: "1,250.00 US dollars saved of 3,000.00 US
    /// dollars. 41 percent. On track."; `.shownStale`: "May be out of date."
    /// in the pace's place; `.unknown`: "Saved amount unavailable. Target
    /// 3,000.00 US dollars.". A drawn figure keeps the prefix "{saved} saved
    /// of {target}. {percent} percent." first (UI tests read it).
    public static func figureSpoken(_ state: GoalFigureState, saved: Money, target: Money, pace: GoalPace) -> String {
        switch state {
        case .shown, .shownStale:
            let word = state == .shown ? pace.label : mayBeOutOfDate
            return "\(saved.accessibilityText()) saved of \(target.accessibilityText()). "
                + "\(GoalProgress.percent(saved: saved, target: target)) percent. \(word)."
        case .unknown:
            return "\(savedAmountUnavailable). Target \(target.accessibilityText())."
        }
    }

    /// "Target date April 21, 2027." for a tile's VoiceOver value: the UTC
    /// calendar day of the deadline (a UTC-midnight instant), so nobody west of
    /// UTC hears the day before.
    public static func targetDateSpoken(_ deadline: Date, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide).day().year()
        style.timeZone = TimeZone(identifier: "UTC")!
        style.locale = locale
        return "Target date \(deadline.formatted(style))."
    }
}
