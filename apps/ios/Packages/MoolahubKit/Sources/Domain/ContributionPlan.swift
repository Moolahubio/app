import Foundation

/// How often a goal's saver plans to put money in. Unknown API values are
/// treated as weekly, like the web's `asFrequency`.
public enum GoalFrequency: String, CaseIterable, Codable, Hashable, Sendable {
    case daily
    case weekly
    case monthly

    public init(apiValue: String?) {
        self = GoalFrequency(rawValue: apiValue ?? "") ?? .weekly
    }

    /// "Daily", "Weekly", "Monthly" (segmented control labels).
    public var label: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
}

/// Port of `artifacts/moolahub-app/src/lib/contribution-plan.ts` so web and iOS
/// show the same plan and pace. Keep it in step with the web file.
public enum ContributionPlan {
    public static let maxPeriods = 520

    /// Number of contribution periods between two dates (min 1, max 520).
    /// Daily and weekly use elapsed milliseconds rounded half up, monthly uses
    /// the calendar year and month difference in `calendar`'s time zone
    /// (the web uses the browser's local time zone).
    public static func periodsBetween(
        _ start: Date,
        _ end: Date,
        frequency: GoalFrequency,
        calendar: Calendar = .current
    ) -> Int {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite, seconds > 0 else { return 1 }
        let days = seconds / 86_400
        let periods: Int
        switch frequency {
        case .daily:
            periods = Int(days.rounded(.toNearestOrAwayFromZero))
        case .weekly:
            periods = Int((days / 7).rounded(.toNearestOrAwayFromZero))
        case .monthly:
            let startYear = calendar.component(.year, from: start)
            let startMonth = calendar.component(.month, from: start)
            let endYear = calendar.component(.year, from: end)
            let endMonth = calendar.component(.month, from: end)
            periods = (endYear - startYear) * 12 + (endMonth - startMonth)
        }
        return max(1, min(periods, maxPeriods))
    }

    /// Progressive (escalating) schedule that sums exactly to `targetCents`.
    /// step_i = floor(target × 2i / (n(n+1))); the integer remainder goes to
    /// the last steps so the plan stays non-decreasing.
    public static func progressivePlan(targetCents: Int64, periods: Int) -> [Int64] {
        let target = max(0, targetCents)
        let n = max(1, periods)
        if n == 1 { return [target] }

        let denominator = Int64(n) * Int64(n + 1)
        var plan: [Int64] = []
        plan.reserveCapacity(n)
        var allocated: Int64 = 0
        for i in 1...n {
            let step = (target * 2 * Int64(i)) / denominator
            plan.append(step)
            allocated += step
        }
        var remainder = target - allocated
        var index = n - 1
        while index >= 0 && remainder > 0 {
            plan[index] += 1
            remainder -= 1
            index -= 1
        }
        return plan
    }

    public struct NextContribution: Hashable, Sendable {
        /// 1-based step the saver is on.
        public let index: Int
        /// Steps in the plan.
        public let total: Int
        /// Suggested amount for this step.
        public let amountCents: Int64
        /// Cumulative target once this step is done.
        public let cumulativeAfterCents: Int64
    }

    /// The first step whose cumulative total exceeds what's saved, or nil when
    /// the plan is fully funded.
    public static func nextContribution(plan: [Int64], savedCents: Int64) -> NextContribution? {
        var cumulative: Int64 = 0
        for (offset, step) in plan.enumerated() {
            cumulative += step
            if savedCents < cumulative {
                return NextContribution(
                    index: offset + 1,
                    total: plan.count,
                    amountCents: step,
                    cumulativeAfterCents: cumulative
                )
            }
        }
        return nil
    }

    public struct GoalPlan: Hashable, Sendable {
        public let frequency: GoalFrequency
        public let periods: Int
        public let plan: [Int64]
        /// First non-zero step (or the first step).
        public let firstCents: Int64
        public let lastCents: Int64
    }

    public static func buildGoalPlan(
        targetCents: Int64,
        start: Date,
        deadline: Date,
        frequency: GoalFrequency,
        calendar: Calendar = .current
    ) -> GoalPlan {
        let periods = periodsBetween(start, deadline, frequency: frequency, calendar: calendar)
        let plan = progressivePlan(targetCents: targetCents, periods: periods)
        return GoalPlan(
            frequency: frequency,
            periods: periods,
            plan: plan,
            firstCents: plan.first(where: { $0 > 0 }) ?? plan.first ?? 0,
            lastCents: plan.last ?? 0
        )
    }
}

/// How a goal is doing against its plan (DESIGN.md §4.6, PlanPill).
public enum GoalPace: Hashable, Sendable {
    case reached
    case pastTargetDate
    case onTrack
    case behind(periods: Int, frequency: GoalFrequency)

    /// Evaluated in the order of DESIGN.md §4.6.
    public static func evaluate(
        targetCents: Int64,
        savedCents: Int64,
        createdAt: Date,
        deadline: Date,
        frequency: GoalFrequency,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> GoalPace {
        if savedCents >= targetCents { return .reached }
        if now > deadline { return .pastTargetDate }

        let periods = ContributionPlan.periodsBetween(createdAt, deadline, frequency: frequency, calendar: calendar)
        let plan = ContributionPlan.progressivePlan(targetCents: targetCents, periods: periods)

        var stepsDone = 0
        var cumulative: Int64 = 0
        for step in plan {
            cumulative += step
            if cumulative <= savedCents { stepsDone += 1 } else { break }
        }

        let elapsedRaw: Int
        switch frequency {
        case .daily:
            elapsedRaw = calendar.dateComponents([.day], from: createdAt, to: now).day ?? 0
        case .weekly:
            elapsedRaw = (calendar.dateComponents([.day], from: createdAt, to: now).day ?? 0) / 7
        case .monthly:
            elapsedRaw = calendar.dateComponents([.month], from: createdAt, to: now).month ?? 0
        }
        let elapsed = min(max(0, elapsedRaw), plan.count)

        let behind = elapsed - stepsDone
        return behind <= 0 ? .onTrack : .behind(periods: behind, frequency: frequency)
    }

    /// Pill copy: "Goal reached", "Past target date", "On track",
    /// "1 week behind", "3 days behind", "2 months behind".
    public var label: String {
        switch self {
        case .reached: return "Goal reached"
        case .pastTargetDate: return "Past target date"
        case .onTrack: return "On track"
        case let .behind(periods, frequency):
            let unit: String
            switch frequency {
            case .daily: unit = periods == 1 ? "day" : "days"
            case .weekly: unit = periods == 1 ? "week" : "weeks"
            case .monthly: unit = periods == 1 ? "month" : "months"
            }
            return "\(periods) \(unit) behind"
        }
    }

    /// True for "Goal reached" and "On track" (jade tone); false is amber.
    public var isPositive: Bool {
        switch self {
        case .reached, .onTrack: true
        case .pastTargetDate, .behind: false
        }
    }

    /// SF Symbol for the pill.
    public var symbolName: String {
        switch self {
        case .reached: "checkmark.seal.fill"
        case .pastTargetDate: "calendar.badge.exclamationmark"
        case .onTrack: "checkmark"
        case .behind: "clock"
        }
    }
}
