import Foundation
import Testing
@testable import Domain

/// learn.md L.10's unit tests, on `GET_learn_lessons.json`.
@Suite("LearnCatalog")
struct LearnCatalogTests {
    private func lessons(completed: Set<String> = [], categories: [String: String] = [:], minutes: [String: Int] = [:]) throws -> [LessonSummary] {
        let data = try Fixture.data("GET_learn_lessons")
        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let changed = objects.map { object -> [String: Any] in
            var object = object
            let slug = object["slug"] as? String ?? ""
            object["completed"] = completed.contains(slug)
            if let category = categories[slug] { object["category"] = category }
            if let value = minutes[slug] { object["minutes"] = value }
            return object
        }
        return try Fixture.decode([LessonSummary].self, object: changed)
    }

    private static let visibleSlugs = ["what-is-a-susu", "setting-savings-goals", "building-an-emergency-fund"]

    @Test func visibleKeepsGroupSavingAndPersonalFinanceInServerOrder() throws {
        #expect(LearnCatalog.visible(try lessons()).map(\.slug) == Self.visibleSlugs)
    }

    /// An allow-list: unknown categories, an empty one and a capitalised key
    /// stay hidden.
    @Test func unknownCategoriesAreHidden() throws {
        let changed = try lessons(categories: ["what-is-a-susu": "earnings", "setting-savings-goals": "", "building-an-emergency-fund": "Circles"])
        #expect(LearnCatalog.visible(changed).isEmpty)
        #expect(LearnCatalog.isShown(category: "circles"))
        #expect(!LearnCatalog.isShown(category: "crypto"))
        #expect(!LearnCatalog.isShown(category: "remittance"))
    }

    @Test func progressCountsOnlyTheVisibleList() throws {
        let hiddenDone = LearnCatalog.progress(of: LearnCatalog.visible(try lessons(completed: ["understanding-usdc"])))
        #expect(hiddenDone.done == 0)
        #expect(hiddenDone.total == 3)
        let twoDone = LearnCatalog.progress(of: LearnCatalog.visible(try lessons(completed: ["what-is-a-susu", "setting-savings-goals"])))
        #expect(twoDone.done == 2)
        #expect(twoDone.total == 3)
        #expect(LearnCatalog.progressText(done: 2, total: 3) == "2 of 3 lessons done")
    }

    @Test func upNextIsTheFirstNotDone() throws {
        #expect(LearnCatalog.upNext(in: LearnCatalog.visible(try lessons()))?.slug == "what-is-a-susu")
        let firstDone = LearnCatalog.visible(try lessons(completed: ["what-is-a-susu"]))
        #expect(LearnCatalog.upNext(in: firstDone)?.slug == "setting-savings-goals")
        let allDone = LearnCatalog.visible(try lessons(completed: Set(Self.visibleSlugs)))
        #expect(LearnCatalog.upNext(in: allDone) == nil)
        #expect(LearnCatalog.upNext(in: []) == nil)
    }

    /// L.7: the next visible lesson whatever its done state; no wrap-around.
    @Test func nextLessonHasNoWrapAround() throws {
        let visible = LearnCatalog.visible(try lessons(completed: ["setting-savings-goals"]))
        #expect(LearnCatalog.next(after: "what-is-a-susu", in: visible)?.slug == "setting-savings-goals")
        #expect(LearnCatalog.next(after: "setting-savings-goals", in: visible)?.slug == "building-an-emergency-fund")
        #expect(LearnCatalog.next(after: "building-an-emergency-fund", in: visible) == nil)
        #expect(LearnCatalog.next(after: "no-such-lesson", in: visible) == nil)
        #expect(LearnCatalog.next(after: "understanding-usdc", in: visible) == nil)
    }

    @Test func words() throws {
        #expect(LearnCatalog.categoryName("circles") == "Group saving")
        #expect(LearnCatalog.categoryName("personal-finance") == "Personal finance")
        #expect(LearnCatalog.categoryName("crypto") == nil)
        #expect(LearnCatalog.levelName("beginner") == "Beginner")
        #expect(LearnCatalog.levelName("BEGINNER") == "Beginner")
        #expect(LearnCatalog.levelName("Intermediate") == "Intermediate")
        #expect(LearnCatalog.levelName("advanced") == "Advanced")
        #expect(LearnCatalog.levelName("expert") == nil)
        #expect(LearnCatalog.minutesText(0) == nil)
        #expect(LearnCatalog.minutesText(5) == "5 min")
        #expect(LearnCatalog.minutesSpoken(1) == "1 minute")
        #expect(LearnCatalog.minutesSpoken(5) == "5 minutes")
        #expect(LearnCatalog.minutesSpoken(-1) == nil)
        #expect(LearnCatalog.progressText(done: 0, total: 1) == "0 of 1 lesson done")
        #expect(LearnCatalog.meta(minutes: 0, level: "x") == nil)
        #expect(LearnCatalog.meta(minutes: 5, level: "beginner") == "5 min \u{00B7} Beginner")
        #expect(LearnCatalog.meta(minutes: 0, level: "beginner") == "Beginner")
        #expect(LearnCatalog.metaSpoken(minutes: 5, level: "beginner") == "5 minutes, Beginner")
        #expect(LearnCatalog.metaSpoken(minutes: 0, level: "x") == nil)

        let susu = try #require(try lessons().first)
        #expect(LearnCatalog.rowSubtitle(susu) == "Group saving \u{00B7} 5 min")
        #expect(LearnCatalog.rowSpoken(susu) == "Group saving, 5 minutes")
        let noMinutes = try #require(try lessons(minutes: ["what-is-a-susu": 0]).first)
        #expect(LearnCatalog.rowSubtitle(noMinutes) == "Group saving")
        #expect(LearnCatalog.rowSpoken(noMinutes) == "Group saving")
    }

    /// Every word the catalog returns has no emoji and no banned word (AC9).
    @Test func wordsHaveNoEmojiOrCryptoWords() throws {
        let visible = LearnCatalog.visible(try lessons())
        var words = visible.flatMap { [LearnCatalog.rowSubtitle($0), LearnCatalog.rowSpoken($0)] }
        words += visible.compactMap { LearnCatalog.meta(minutes: $0.minutes, level: $0.level) }
        words += visible.compactMap { LearnCatalog.metaSpoken(minutes: $0.minutes, level: $0.level) }
        words += [LearnCatalog.progressText(done: 1, total: 3), LearnCatalog.progressText(done: 0, total: 1)]
        let banned = ["usdc", "wallet", "blockchain", "privy", "transaction", "gas", "hash", "monad"]
        for word in words {
            #expect(!word.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.value == 0xFE0F }, "\(word)")
            #expect(!banned.contains { word.lowercased().contains($0) }, "\(word)")
            #expect(!word.contains("Base"))
        }
    }
}
