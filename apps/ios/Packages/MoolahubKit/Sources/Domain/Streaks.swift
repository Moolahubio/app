import Foundation

// The savings streak's derived values (streaks.md ST.1.3, R1 to R13) and every
// streak sentence that depends on data (SPEC §6.2). Pure: every function takes
// the overview, `now` and the device `Calendar` (its time zone and locale), so
// tests are deterministic. Home, Account, Savings, Groups and FeatureStreaks
// all read their streak words from here, so they never disagree.

/// R2's result: the status the screen names.
public enum StreakDisplayStatus: Hashable, Sendable {
    /// No streak (or it broke): `hero` is nil or its count is 0.
    case none
    case active
    /// A freeze covered the last missed period.
    case frozen
    case onBreak
    /// A status iOS does not know: the count shows, with no status word.
    case unknown
}

/// R7: the tier from every badge collected (it never drops).
public enum StreakTier: Hashable, Sendable {
    case none, bronze, silver, gold
}

/// One quarter cell of R8's grid.
public struct StreakQuarter: Hashable, Sendable {
    public let year: Int
    /// 1 to 4.
    public let quarter: Int
    public let collected: Bool

    public init(year: Int, quarter: Int, collected: Bool) {
        self.year = year
        self.quarter = quarter
        self.collected = collected
    }

    /// "Q2" (ST-14).
    public var label: String { "Q\(quarter)" }

    /// "Collected" / "Not yet" (ST-14).
    public var word: String { collected ? "Collected" : "Not yet" }

    /// "Q2 2026, collected" / "Q2 2026, not collected yet" (ST-14).
    public var spoken: String {
        collected ? "\(label) \(year), collected" : "\(label) \(year), not collected yet"
    }
}

/// One year of R8's grid: Q1 to Q4.
public struct StreakQuarterRow: Hashable, Sendable {
    public let year: Int
    public let quarters: [StreakQuarter]
}

/// R11's result: the receipt footnote after a save.
public enum StreakReceiptNote: Hashable, Sendable {
    case starts(StreakFrequency)
    case keepsGoing(StreakFrequency)

    /// "This starts your weekly streak." (ST-70) / "This keeps your weekly
    /// streak going." (ST-71).
    public var text: String {
        switch self {
        case .starts(let frequency): "This starts your \(frequency.rawValue) streak."
        case .keepsGoing(let frequency): "This keeps your \(frequency.rawValue) streak going."
        }
    }
}

// MARK: - Rules

public enum StreakRules {
    /// R1. The open period is saved only while it is still open: a period whose
    /// `currentPeriodEnd <= now` (a cached snapshot, or a server that has not
    /// settled it) counts as not saved.
    public static func isSavedThisPeriod(_ overview: StreakOverview, now: Date) -> Bool {
        guard overview.currentPeriodSatisfied, let end = overview.currentPeriodEnd else { return false }
        return end > now
    }

    /// R2, in order: no streak; on a break; frozen; active (a "paused" streak
    /// whose break already ended is active); anything else unknown.
    public static func displayStatus(_ overview: StreakOverview) -> StreakDisplayStatus {
        guard let hero = overview.hero, hero.count > 0 else { return .none }
        if overview.vacation.active { return .onBreak }
        switch hero.status {
        case "frozen": return .frozen
        case "active", "paused": return .active
        default: return .unknown
        }
    }

    /// R5. The at-risk notice: never on a closed period or during a break.
    public static func showsAtRisk(_ overview: StreakOverview, now: Date) -> Bool {
        guard overview.atRisk, let end = overview.currentPeriodEnd, end > now else { return false }
        return displayStatus(overview) != .onBreak
    }

    /// R7, the server's `tierForOrder`: 0 none, 1 to 3 bronze, 4 to 7 silver,
    /// 8 and more gold. Pass `badges.count`.
    public static func tier(count: Int) -> StreakTier {
        switch count {
        case ...0: .none
        case 1...3: .bronze
        case 4...7: .silver
        default: .gold
        }
    }

    /// R8. The device calendar's current year always, plus every other year
    /// with a badge; newest first; Q1 to Q4 each.
    public static func quarterRows(badges: [StreakBadge], now: Date, calendar: Calendar) -> [StreakQuarterRow] {
        let currentYear = calendar.component(.year, from: now)
        let years = Set(badges.map(\.year)).union([currentYear]).sorted(by: >)
        return years.map { year in
            StreakQuarterRow(year: year, quarters: (1...4).map { quarter in
                StreakQuarter(
                    year: year, quarter: quarter,
                    collected: badges.contains { $0.year == year && $0.quarterIndex == quarter }
                )
            })
        }
    }

    /// R9. When a break started now ends: `now + days × 24 h`, as the server
    /// computes it.
    public static func breakEnd(days: StreakBreakDays, now: Date) -> Date {
        now.addingTimeInterval(TimeInterval(days.days) * 86_400)
    }

    /// R10. The year the frequency can change again: `nextChangeYear`, else
    /// the device calendar's next year.
    public static func nextYear(_ overview: StreakOverview, now: Date, calendar: Calendar) -> Int {
        overview.nextChangeYear ?? calendar.component(.year, from: now) + 1
    }

    /// R11 (ST.8.2). A footnote only when the save visibly moved the streak:
    /// both reads exist, `after` has a streak saved this period, and the
    /// streak is new, its count changed or its period moved. The satisfied
    /// flag alone is never the test. A missing read gives none (never a guess).
    public static func receiptNote(before: StreakOverview?, after: StreakOverview?, now: Date) -> StreakReceiptNote? {
        guard let before, let after, let hero = after.hero, hero.count >= 1,
              isSavedThisPeriod(after, now: now)
        else { return nil }
        let moved = before.hero == nil
            || before.hero?.count != hero.count
            || before.currentPeriodEnd != after.currentPeriodEnd
        guard moved else { return nil }
        let frequency = after.effectiveFrequency
        return hero.count == 1 ? .starts(frequency) : .keepsGoing(frequency)
    }

    /// R12. Months of saving on the share card: `3 × earnedQuarters` while the
    /// streak is alive (active, frozen or on a break) and at least one quarter
    /// is earned; else nil.
    public static func monthsOfSaving(_ overview: StreakOverview) -> Int? {
        switch displayStatus(overview) {
        case .active, .frozen, .onBreak:
            let quarters = overview.badgeProgress.earnedQuarters
            return quarters >= 1 ? 3 * quarters : nil
        case .none, .unknown:
            return nil
        }
    }
}

/// R13: which badge the New badge sheet celebrates.
public enum StreakBadgeSeen {
    /// `seen == nil` (the first live read for this user on this device) seeds
    /// the list with every badge and celebrates nothing. Otherwise `pending` is
    /// the newest unseen badge by (year, quarter), and `seen` is unchanged.
    public static func evaluate(badges: [StreakBadge], seen: [String]?) -> (seen: [String], pending: StreakBadge?) {
        guard let seen else { return (badges.map(\.badgeKey), nil) }
        let pending = badges
            .filter { !seen.contains($0.badgeKey) }
            .max { ($0.year, $0.quarterIndex) < ($1.year, $1.quarterIndex) }
        return (seen, pending)
    }
}

// MARK: - Words

/// The Home row's two lines (ST.7, SPEC §1.4): the title is also its
/// VoiceOver label, the sub-line its value.
public struct StreakRowWords: Hashable, Sendable {
    public let title: String
    public let subtitle: String
}

public enum StreakWords {
    /// R3: "day" / "days", "week" / "weeks", "month" / "months"; singular only
    /// for exactly 1.
    public static func unitWord(count: Int, frequency: StreakFrequency) -> String {
        count == 1 ? singularUnit(frequency) : pluralUnit(frequency)
    }

    /// R4: "today", "this week", "this month".
    public static func periodPhrase(frequency: StreakFrequency) -> String {
        switch frequency {
        case .daily: "today"
        case .weekly: "this week"
        case .monthly: "this month"
        }
    }

    /// "Daily", "Weekly", "Monthly" for the three server values; nil for
    /// anything else, so a row that names the frequency shows no value.
    public static func frequencyName(_ raw: String) -> String? {
        switch StreakFrequency(rawValue: raw) {
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case nil: nil
        }
    }

    /// ST-03, the hero's unit line: "week so far" for 1, "weeks in a row"
    /// otherwise.
    public static func unitLine(count: Int, frequency: StreakFrequency) -> String {
        count == 1 ? "\(singularUnit(frequency)) so far" : "\(pluralUnit(frequency)) in a row"
    }

    /// ST-04: "Active", "Covered by a freeze", "On a break", "No streak yet";
    /// nil for an unknown status.
    public static func statusWord(_ status: StreakDisplayStatus) -> String? {
        switch status {
        case .active: "Active"
        case .frozen: "Covered by a freeze"
        case .onBreak: "On a break"
        case .none: "No streak yet"
        case .unknown: nil
        }
    }

    /// ST-05: "Saved this week" / "Not saved this week yet".
    public static func savedLine(saved: Bool, frequency: StreakFrequency) -> String {
        let period = periodPhrase(frequency: frequency)
        return saved ? "Saved \(period)" : "Not saved \(period) yet"
    }

    /// ST-06: "On a break until Nov 8" (the year added outside the current
    /// one); "On a break" when the end is not known.
    public static func onBreakLine(_ overview: StreakOverview, now: Date, calendar: Calendar) -> String {
        guard let end = overview.vacation.end else { return "On a break" }
        return "On a break until \(day(end, now: now, calendar: calendar, month: .abbreviated))"
    }

    /// The Streak screen's status line: "Active · Saved this week" (ST-04 ·
    /// ST-05), the break line (ST-06), or ST-05 alone for an unknown status;
    /// nil with no streak.
    public static func statusLine(_ overview: StreakOverview, now: Date, calendar: Calendar) -> String? {
        let status = StreakRules.displayStatus(overview)
        let saved = savedLine(saved: StreakRules.isSavedThisPeriod(overview, now: now), frequency: overview.effectiveFrequency)
        switch status {
        case .none: return nil
        case .onBreak: return onBreakLine(overview, now: now, calendar: calendar)
        case .active, .frozen, .unknown:
            guard let word = statusWord(status) else { return saved }
            return "\(word) \u{00B7} \(saved)"
        }
    }

    /// The hero's VoiceOver value: "1 week so far. Active. Saved this week.";
    /// "3 weeks in a row. On a break until November 8."; "No streak yet. Save
    /// once this week to start your streak.".
    public static func heroSpoken(_ overview: StreakOverview, now: Date, calendar: Calendar) -> String {
        let status = StreakRules.displayStatus(overview)
        let frequency = overview.effectiveFrequency
        guard let count = overview.hero?.count, status != .none else {
            return "No streak yet. \(noStreakLine(overview))"
        }
        let figure = "\(count) \(unitLine(count: count, frequency: frequency))."
        let saved = savedLine(saved: StreakRules.isSavedThisPeriod(overview, now: now), frequency: frequency)
        if status == .onBreak {
            guard let end = overview.vacation.end else { return "\(figure) On a break." }
            return "\(figure) On a break until \(day(end, now: now, calendar: calendar, month: .wide))."
        }
        guard let word = statusWord(status) else { return "\(figure) \(saved)." }
        return "\(figure) \(word). \(saved)."
    }

    /// ST-07, under "No streak yet": "Save once this week to start your
    /// streak." ("…a new streak." after an earlier streak).
    public static func noStreakLine(_ overview: StreakOverview) -> String {
        let period = periodPhrase(frequency: overview.effectiveFrequency)
        return overview.lifetimeBest > 0
            ? "Save once \(period) to start a new streak."
            : "Save once \(period) to start your streak."
    }

    /// ST-08 with R6's deadline, in the device zone: "Save once today to keep
    /// your streak.", "…by tomorrow…", "…by Sunday, Oct 25…" (the period's last
    /// day when it ends at a local midnight), or "…before Oct 25 at 8:00 PM…"
    /// (the exact end when it does not, before the server has the device's
    /// zone). Nil without a period end. Whether it shows is R5's.
    public static func atRiskNotice(_ overview: StreakOverview, now: Date, calendar: Calendar) -> String? {
        guard let end = overview.currentPeriodEnd else { return nil }
        return "Save once \(atRiskDeadline(end: end, now: now, calendar: calendar)) to keep your streak."
    }

    /// R6's deadline phrase: "today", "by tomorrow", "by Sunday, Oct 25" or
    /// "before Oct 25 at 8:00 PM", in the device zone (D-31).
    public static func atRiskDeadline(end: Date, now: Date, calendar: Calendar) -> String {
        guard calendar.startOfDay(for: end) == end else {
            var style = dateStyle(calendar).month(.abbreviated).day().hour().minute()
            if !calendar.isDate(end, equalTo: now, toGranularity: .year) { style = style.year() }
            return "before \(end.formatted(style))"
        }
        let lastDay = end.addingTimeInterval(-1)
        if calendar.isDate(lastDay, inSameDayAs: now) { return "today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(lastDay, inSameDayAs: tomorrow) {
            return "by tomorrow"
        }
        return "by \(day(lastDay, now: now, calendar: calendar, month: .abbreviated, weekday: .wide))"
    }

    /// ST-11: "No badge yet", "Bronze saver", "Silver saver", "Gold saver".
    public static func tierTitle(_ tier: StreakTier) -> String {
        switch tier {
        case .none: "No badge yet"
        case .bronze: "Bronze saver"
        case .silver: "Silver saver"
        case .gold: "Gold saver"
        }
    }

    /// ST-13, the days line under the tier.
    public static func badgeDaysLine(_ overview: StreakOverview) -> String {
        if StreakRules.displayStatus(overview) == .onBreak { return "Badge progress is paused during your break." }
        guard let days = overview.badgeProgress.daysToNext else {
            return "Keep a streak going for three months to get a badge."
        }
        switch days {
        case ...0: return "Your next badge is on its way."
        case 1: return "Next badge in about 1 day."
        default: return "Next badge in about \(days) days."
        }
    }

    /// ST-17: "You can change this once a year." / "You can change this again
    /// in 2027." (R10).
    public static func frequencyLockNote(_ overview: StreakOverview, now: Date, calendar: Calendar) -> String {
        overview.canChangeFrequency
            ? "You can change this once a year."
            : "You can change this again in \(StreakRules.nextYear(overview, now: now, calendar: calendar))."
    }

    /// ST-18's value: "1 available" (no cap: the API sends none).
    public static func freezesValue(_ overview: StreakOverview) -> String {
        "\(overview.freezes.balance) available"
    }

    /// ST-18's footnote, with the period's unit.
    public static func freezesNote(frequency: StreakFrequency) -> String {
        "One freeze can cover a missed \(singularUnit(frequency)) in any three months, and you get a new one every three months."
    }

    /// ST-19, the break row's value on a break: "Until Nov 8".
    public static func breakUntilValue(_ end: Date, now: Date, calendar: Calendar) -> String {
        "Until \(day(end, now: now, calendar: calendar, month: .abbreviated))"
    }

    /// ST-19, the break row's value once this year's break is used: "Again in
    /// 2027" (the device's next year).
    public static func breakAgainValue(now: Date, calendar: Calendar) -> String {
        "Again in \(calendar.component(.year, from: now) + 1)"
    }

    /// ST-33's dialog title: "Change to monthly?".
    public static func frequencyChangeTitle(to frequency: StreakFrequency) -> String {
        "Change to \(frequency.rawValue)?"
    }

    /// ST-33's confirming button: "Change to monthly".
    public static func frequencyChangeButton(to frequency: StreakFrequency) -> String {
        "Change to \(frequency.rawValue)"
    }

    /// ST-34, the confirmation's message: the count carries over in the new
    /// unit and a new period starts unsaved.
    public static func frequencyChangeMessage(_ overview: StreakOverview, to frequency: StreakFrequency, now: Date, calendar: Calendar) -> String {
        let units = pluralUnit(frequency)
        let yearly = "You can change this once a year, so your next change is in \(StreakRules.nextYear(overview, now: now, calendar: calendar))."
        let status = StreakRules.displayStatus(overview)
        guard let count = overview.hero?.count, status != .none else {
            return "Your streak will count \(units). \(yearly)"
        }
        let stays = "Your streak stays at \(count), counted in \(units) from now."
        if status == .onBreak { return "\(stays) \(yearly)" }
        return "\(stays) Save once \(periodPhrase(frequency: frequency)) to keep it going. \(yearly)"
    }

    /// ST-41, the break sheet's body.
    public static func breakSheetBody(frequency: StreakFrequency) -> String {
        "Your streak pauses, so a missed \(singularUnit(frequency)) won't end it."
    }

    /// ST-42: "14 days" / "1 day".
    public static func breakLength(_ days: StreakBreakDays) -> String {
        days.days == 1 ? "1 day" : "\(days.days) days"
    }

    /// ST-43: "Until Sun, Nov 8" (R9's end).
    public static func breakSheetUntil(_ days: StreakBreakDays, now: Date, calendar: Calendar) -> String {
        "Until \(breakEndDay(days, now: now, calendar: calendar))"
    }

    /// ST-45: "Start a 14-day break?".
    public static func startBreakTitle(_ days: StreakBreakDays) -> String {
        "Start a \(days.days)-day break?"
    }

    /// ST-46, the start dialog's message.
    public static func startBreakMessage(_ days: StreakBreakDays, now: Date, calendar: Calendar) -> String {
        "Your streak pauses until \(breakEndDay(days, now: now, calendar: calendar)). You get one break a year, and ending it early still uses it."
    }

    /// Home's row (SPEC §1.4) after a successful read: "No streak yet" / "Save
    /// once to start a streak"; else "1 week" over "Saved this week", "One
    /// save keeps your weekly streak going" or the break line.
    public static func homeRow(_ overview: StreakOverview, now: Date, calendar: Calendar) -> StreakRowWords {
        let status = StreakRules.displayStatus(overview)
        guard let count = overview.hero?.count, status != .none else {
            return StreakRowWords(title: "No streak yet", subtitle: "Save once to start a streak")
        }
        let frequency = overview.effectiveFrequency
        let title = "\(count) \(unitWord(count: count, frequency: frequency))"
        if status == .onBreak {
            return StreakRowWords(title: title, subtitle: onBreakLine(overview, now: now, calendar: calendar))
        }
        if StreakRules.isSavedThisPeriod(overview, now: now) {
            return StreakRowWords(title: title, subtitle: savedLine(saved: true, frequency: frequency))
        }
        return StreakRowWords(title: title, subtitle: "One save keeps your \(frequency.rawValue) streak going")
    }

    /// ST-81: "Q2 2026 · Bronze", the tier (R7 of every badge collected) with
    /// no "saver".
    public static func badgeLine(_ badge: StreakBadge, badgeCount: Int) -> String {
        let quarter = "Q\(badge.quarterIndex) \(badge.year)"
        guard let tier = tierName(StreakRules.tier(count: badgeCount)) else { return quarter }
        return "\(quarter) \u{00B7} \(tier)"
    }

    /// ST-82: "Three months of steady saving." for the first badge, "Another
    /// three months of steady saving." after it.
    public static func badgeBody(badgeCount: Int) -> String {
        badgeCount <= 1 ? "Three months of steady saving." : "Another three months of steady saving."
    }

    /// ST-90: "6 months of saving".
    public static func monthsLine(_ months: Int) -> String {
        "\(months) months of saving"
    }

    /// ST-91: "$1,580.00 saved in goals" (W4 exact).
    public static func amountLine(_ amount: Money) -> String {
        "\(amount.formatted()) saved in goals"
    }

    /// ST-92: "2026 badges".
    public static func yearBadges(_ year: Int) -> String {
        "\(year) badges"
    }

    // MARK: Helpers

    static func singularUnit(_ frequency: StreakFrequency) -> String {
        switch frequency {
        case .daily: "day"
        case .weekly: "week"
        case .monthly: "month"
        }
    }

    static func pluralUnit(_ frequency: StreakFrequency) -> String {
        switch frequency {
        case .daily: "days"
        case .weekly: "weeks"
        case .monthly: "months"
        }
    }

    static func tierName(_ tier: StreakTier) -> String? {
        switch tier {
        case .none: nil
        case .bronze: "Bronze"
        case .silver: "Silver"
        case .gold: "Gold"
        }
    }

    /// "Sun, Nov 8" for R9's end.
    private static func breakEndDay(_ days: StreakBreakDays, now: Date, calendar: Calendar) -> String {
        day(StreakRules.breakEnd(days: days, now: now), now: now, calendar: calendar, month: .abbreviated, weekday: .abbreviated)
    }

    /// A day in the device's calendar, zone and locale: "Nov 8", "Sunday, Oct
    /// 25"; the year is added outside the current one.
    private static func day(
        _ date: Date, now: Date, calendar: Calendar,
        month: Date.FormatStyle.Symbol.Month, weekday: Date.FormatStyle.Symbol.Weekday? = nil
    ) -> String {
        var style = dateStyle(calendar).month(month).day()
        if let weekday { style = style.weekday(weekday) }
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) { style = style.year() }
        return date.formatted(style)
    }

    private static func dateStyle(_ calendar: Calendar) -> Date.FormatStyle {
        var style = Date.FormatStyle.dateTime
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .autoupdatingCurrent
        return style
    }
}

// MARK: - Share card (ST.10)

/// The words on the share card and its VoiceOver value (ST-98), built from the
/// same parts the card draws. The amount is drawn only when the person turns
/// it on and the caller has a live, non-zero figure.
public struct StreakShareCard: Hashable, Sendable {
    public let count: Int
    /// "13 weeks in a row" without the figure: "weeks in a row" (ST-03).
    public let unitLine: String
    /// "3 months of saving" (ST-90, R12).
    public let monthsLine: String?
    /// "Bronze saver" when at least one badge exists (ST-11).
    public let tierWord: String?
    /// "$1,580.00 saved in goals" (ST-91), only when switched on.
    public let amountLine: String?
    /// The card's year: the device calendar's current year.
    public let year: Int
    /// "2026 badges" (ST-92).
    public let yearLabel: String
    /// Q1 to Q4 of `year`.
    public let quarters: [StreakQuarter]
    /// ST-98.
    public let spokenValue: String

    /// - Parameter amountSaved: the goal savings to show, nil when the switch
    ///   is off or no live figure was offered.
    public init(overview: StreakOverview, amountSaved: Money?, now: Date, calendar: Calendar) {
        let count = overview.hero?.count ?? 0
        let year = calendar.component(.year, from: now)
        let quarters = StreakRules.quarterRows(badges: overview.badges, now: now, calendar: calendar)
            .first { $0.year == year }?.quarters ?? []
        self.count = count
        unitLine = StreakWords.unitLine(count: count, frequency: overview.effectiveFrequency)
        monthsLine = StreakRules.monthsOfSaving(overview).map(StreakWords.monthsLine)
        tierWord = overview.badges.isEmpty ? nil : StreakWords.tierTitle(StreakRules.tier(count: overview.badges.count))
        amountLine = amountSaved.map(StreakWords.amountLine)
        self.year = year
        yearLabel = StreakWords.yearBadges(year)
        self.quarters = quarters

        var parts = ["\(count) \(unitLine)"]
        if let monthsLine { parts.append(monthsLine) }
        if let tierWord { parts.append(tierWord) }
        if let amountSaved { parts.append("\(amountSaved.accessibilityText()) saved in goals") }
        let collected = quarters.filter(\.collected).map(\.label)
        parts.append(collected.isEmpty
            ? "\(yearLabel): none collected yet"
            : "\(yearLabel): \(Self.list(collected)) collected")
        spokenValue = parts.joined(separator: ". ") + "."
    }

    /// The figure as drawn.
    public var countText: String { "\(count)" }

    /// Every string the card draws, top to bottom.
    public var strings: [String] {
        [countText, unitLine] + [monthsLine, tierWord, amountLine].compactMap { $0 } + [yearLabel]
            + quarters.flatMap { [$0.label, $0.word] }
    }

    /// "Q2", "Q1 and Q2", "Q1, Q2 and Q3".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }
}
