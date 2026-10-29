import APIClient
import DesignSystem
import Domain
import SwiftUI

// Feature-internal helpers for Learn: the screens' own words (SPEC §6.3,
// W10.9-ln), the error words the reader maps itself, and the measurement that
// puts the lesson title in the bar. The rules and the words built from lesson
// data (visible list, progress, categories, minutes) are Domain's
// `LearnCatalog`, shared with Home.

// MARK: - Copy (SPEC §6.3, learn.md L.12)

enum LearnCopy {
    /// ln1: the list's bar title.
    static let title = "Learn"
    /// ln3: the list's one sentence.
    static let intro = "Short lessons on saving, on your own and with a group."
    /// ln5: the featured tile's label while no visible lesson is done.
    static let startHere = "Start here"
    /// ln6: the featured tile's label once one is done; the next row's sub-line prefix.
    static let nextLesson = "Next lesson"
    /// ln7
    static let allLessons = "All lessons"
    /// ln12: a done row's value and the reader's status.
    static let done = "Done"
    /// ln13
    static let keyTakeaways = "Key takeaways"
    /// ln14
    static let markAsDone = "Mark as done"
    static let saving = "Saving\u{2026}"
    /// ln15 (W10.2)
    static let emptyTitle = "No lessons yet"
    static let emptyBody = "New lessons will show up here."
    /// ln16 (W10.2)
    static let listErrorTitle = "We couldn't load lessons"
    /// ln17 (W10.2)
    static let lessonErrorTitle = "We couldn't load this lesson"
    /// ln18 (W10.2): the reader's not-found state and a Mark as done 404.
    static let notFound = "We couldn't find that lesson."
    /// ln19 (W8)
    static let loadingLessons = "Loading lessons\u{2026}"
    static let loadingLesson = "Loading lesson\u{2026}"
    /// ln20 (W10.8)
    static let opensLesson = "Opens lesson."
    /// ln22 (W10.8): announced after a successful Mark as done.
    static let markedAsDone = "Marked as done."

    /// ln23 (W10.8): the reader's next row label, "Next lesson, {title}".
    static func nextLessonLabel(_ title: String) -> String {
        "\(nextLesson), \(title)"
    }

    /// The next row's sub-line, "Next lesson · {n} min" (ln6, ln8); "Next
    /// lesson" alone when the minutes are unknown.
    static func nextLessonSubtitle(minutes: Int) -> String {
        [nextLesson, LearnCatalog.minutesText(minutes)].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }

    /// A list row's spoken value: "{Category}, {n} minutes", plus ", done"
    /// (ln24) when the lesson is done.
    static func rowValue(_ lesson: LessonSummary) -> String {
        let spoken = LearnCatalog.rowSpoken(lesson)
        return lesson.completed ? spoken + ", done" : spoken
    }

    /// The featured tile's spoken value: "{Start here | Next lesson}.
    /// {summary} {n} minutes, {Level}." (learn.md L.3). A part the API left
    /// out is dropped.
    static func featuredValue(label: String, lesson: LessonSummary) -> String {
        var parts = [label + "."]
        if !lesson.summary.isEmpty { parts.append(lesson.summary) }
        if let meta = LearnCatalog.metaSpoken(minutes: lesson.minutes, level: lesson.level) {
            parts.append(meta + ".")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Errors the reader maps itself (learn.md L.4, L.6)

enum LessonErrors {
    /// A load answered 404 `{"error":"Lesson not found"}` or 400
    /// `{"error":"Invalid request"}`: the not-found state, never the
    /// server's words.
    static func isNotFound(_ error: APIError?) -> Bool {
        guard case .rejected(let status, _)? = error else { return false }
        return status == 404 || status == 400
    }

    /// The banner over Mark as done after a failed save (L.6's table); nil
    /// when nothing is shown (a session that expired signs out; a cancelled
    /// request belongs to a view that went away).
    static func markDoneMessage(_ error: APIError) -> String? {
        switch error {
        case .sessionExpired, .cancelled:
            return nil
        case .rejected(404, _):
            return LearnCopy.notFound
        case .rejected(400, _), .rejected(403, _), .server, .invalidResponse:
            return APIError.Copy.generic
        default:
            return error.message(for: .action)
        }
    }
}

// MARK: - The lesson title in the bar (SPEC §3.3, D-12)

/// The named coordinate space of the reader's `ScrollView`: its origin is the
/// scroll view's top, under the navigation bar.
enum LessonScrollSpace {
    static let name = "lesson.scrollSpace"
}

/// The content title's maxY in `LessonScrollSpace`, sent from a
/// `GeometryReader` behind the title. At or above 0 the title has scrolled
/// fully under the bar. No title on screen (loading, error, not found) sends
/// the default, which keeps the bar empty.
struct LessonTitleMaxYKey: PreferenceKey {
    static let defaultValue: CGFloat = .infinity

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

extension View {
    /// Reports this view's maxY in the reader's scroll space (iOS 17: a
    /// `GeometryReader` background and a `PreferenceKey`).
    func reportsLessonTitleMaxY() -> some View {
        background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: LessonTitleMaxYKey.self,
                    value: proxy.frame(in: .named(LessonScrollSpace.name)).maxY
                )
            }
        }
    }
}
