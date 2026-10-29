import Foundation

/// Learn's rules and words (learn.md L.8), shared by Home's "Keep learning"
/// and FeatureLearn so the two never disagree. Pure: no networking. A part the
/// API leaves out or sends unknown is dropped, never shown raw.
public enum LearnCatalog {
    /// Categories shown on iOS. An allow-list: a new server category stays
    /// hidden until an iOS release opts in. Crypto and remittance never show.
    public static let shownCategories: Set<String> = ["circles", "personal-finance"]

    /// Case-sensitive, like the server's keys.
    public static func isShown(category: String) -> Bool {
        shownCategories.contains(category)
    }

    /// Lessons in shown categories, server order kept.
    public static func visible(_ lessons: [LessonSummary]) -> [LessonSummary] {
        lessons.filter { isShown(category: $0.category) }
    }

    /// `done` = visible lessons marked completed; `total` = all visible.
    public static func progress(of visible: [LessonSummary]) -> (done: Int, total: Int) {
        (visible.filter(\.completed).count, visible.count)
    }

    /// The first visible lesson not yet done; nil when none.
    public static func upNext(in visible: [LessonSummary]) -> LessonSummary? {
        visible.first { !$0.completed }
    }

    /// The visible lesson right after `slug` in server order, whatever its
    /// done state; nil for the last one and when `slug` is not visible (no
    /// wrap-around, L.7).
    public static func next(after slug: String, in visible: [LessonSummary]) -> LessonSummary? {
        guard let index = visible.firstIndex(where: { $0.slug == slug }), index + 1 < visible.count else { return nil }
        return visible[index + 1]
    }

    // MARK: Words (sentence case, no emoji, no crypto words)

    /// "circles" → "Group saving", "personal-finance" → "Personal finance",
    /// else nil.
    public static func categoryName(_ key: String) -> String? {
        switch key {
        case "circles": "Group saving"
        case "personal-finance": "Personal finance"
        default: nil
        }
    }

    /// "beginner" → "Beginner" (any case), "intermediate", "advanced"; else nil.
    public static func levelName(_ key: String) -> String? {
        switch key.lowercased() {
        case "beginner": "Beginner"
        case "intermediate": "Intermediate"
        case "advanced": "Advanced"
        default: nil
        }
    }

    /// "5 min"; nil when `minutes <= 0`.
    public static func minutesText(_ minutes: Int) -> String? {
        minutes > 0 ? "\(minutes) min" : nil
    }

    /// "1 minute", "5 minutes"; nil when `minutes <= 0`.
    public static func minutesSpoken(_ minutes: Int) -> String? {
        guard minutes > 0 else { return nil }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    /// "{Category} · {n} min" ("Group saving · 5 min").
    public static func rowSubtitle(_ lesson: LessonSummary) -> String {
        [categoryName(lesson.category), minutesText(lesson.minutes)]
            .compactMap { $0 }
            .joined(separator: separator)
    }

    /// "{Category}, {n} minutes" (the row's VoiceOver value).
    public static func rowSpoken(_ lesson: LessonSummary) -> String {
        [categoryName(lesson.category), minutesSpoken(lesson.minutes)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// "{n} min · {Level}"; nil when both parts are missing.
    public static func meta(minutes: Int, level: String) -> String? {
        let parts = [minutesText(minutes), levelName(level)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: separator)
    }

    /// "{n} minutes, {Level}"; nil when both parts are missing.
    public static func metaSpoken(minutes: Int, level: String) -> String? {
        let parts = [minutesSpoken(minutes), levelName(level)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// "1 of 3 lessons done"; "0 of 1 lesson done".
    public static func progressText(done: Int, total: Int) -> String {
        total == 1 ? "\(done) of 1 lesson done" : "\(done) of \(total) lessons done"
    }

    /// Space, middle dot, space (W1).
    private static let separator = " \u{00B7} "
}
