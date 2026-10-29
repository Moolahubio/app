import XCTest

/// End-to-end UI tests for Learn (SPEC §3.6, learn.md L.10), run against the
/// local dev backend through `apps/ios/scripts/ui-test.sh`. Owned by lane L.
/// Every test enters through Account's `account.row.learn` (lane A), so they
/// run and merge after lane A (SPEC §8.5 step 7, D-42). Every helper is
/// `private` so it never collides with another feature's test file.
///
/// What the screens should show comes from the server (`GET /learn/lessons`
/// with the test's own session), so the tests pass whatever the account's
/// progress is. The one test that writes (Mark as done has no undo) uses a
/// throwaway account from `AuthTestAPI.registerVerifiedAccount()`, so the
/// demo account is only read.
final class LearnFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - L.10 test 1: the list (AC1, AC2, AC3, AC9)

    /// Account → Learn: the rows are exactly the server's visible lessons in
    /// server order (no crypto or remittance lesson), the progress line counts
    /// the rows and their "done" values, and the featured tile is the first
    /// lesson not yet done, labelled "Start here" or "Next lesson". No crypto
    /// word, emoji, "!" or em dash anywhere on the screen.
    @MainActor
    func testLearnFromAccountShowsVisibleLessonsAndProgress() async throws {
        let password = try UITestAccount.demoPassword()
        let expected = try LearnBackend.visible(from: await UITestAPI.lessons())
        XCTAssertFalse(expected.isEmpty, "the server has no visible lesson; this test needs the seed's lessons")

        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        openLearnFromAccount(app)

        // AC1: the rows, in order, and nothing hidden.
        let rows = learnRows(app)
        XCTAssertEqual(rows.map(\.slug), expected.map(\.slug), "the rows are not the server's visible lessons in order")
        for slug in LearnBackend.hiddenSeedSlugs {
            XCTAssertFalse(app.descendants(matching: .any)["learn.lesson.\(slug)"].exists, "\(slug) is shown")
        }
        for (row, lesson) in zip(rows, expected) {
            XCTAssertEqual(row.element.label, lesson.title)
            XCTAssertEqual(rowSaysDone(row.element), lesson.completed, "\(lesson.slug)'s done value disagrees with the server")
        }

        // AC2: the progress line counts the rows.
        let done = rows.filter { rowSaysDone($0.element) }.count
        XCTAssertEqual(learnProgress(app), LearnBackend.progressText(done: done, total: rows.count))
        XCTAssertEqual(done, expected.filter(\.completed).count)

        // AC3: the featured tile.
        let featured = app.buttons["learn.featured"]
        if let upNext = expected.first(where: { !$0.completed }) {
            XCTAssertTrue(featured.exists, "no featured tile while a lesson is not done")
            XCTAssertEqual(featured.label, upNext.title)
            let value = featured.value as? String ?? ""
            XCTAssertTrue(value.hasPrefix(done == 0 ? "Start here." : "Next lesson."), "featured value: \(value)")
        } else {
            XCTAssertFalse(featured.exists, "a featured tile while every lesson is done")
        }

        // AC9.
        try assertNoCryptoWords(app)
        assertPlainCopy(app)
        app.attachScreenshot(named: "Learn list", to: self)
    }

    // MARK: - L.10 test 2: Mark as done (AC5)

    /// On a throwaway account (Mark as done has no undo): the featured lesson's
    /// "Mark as done" turns into "Done" on the same screen, the list's count
    /// goes up by one and its row says done, the server agrees, and after a
    /// relaunch the row still says done.
    @MainActor
    func testMarkAsDoneStaysOnTheLessonAndPersists() async throws {
        let account = try await AuthTestAPI.registerVerifiedAccount()
        let before = try await LearnBackend.visibleLessons(email: account.email, password: account.password)
        guard let lesson = before.first(where: { !$0.completed }) else {
            throw XCTSkip("Every visible lesson is done; reseed with seed:ios-dev --reset")
        }

        let app = XCUIApplication.launchedClean()
        app.signIn(email: account.email, password: account.password)
        openLearnFromAccount(app)
        let doneBefore = learnRows(app).filter { rowSaysDone($0.element) }.count

        let featured = app.buttons["learn.featured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 10), "no featured tile")
        XCTAssertEqual(featured.label, lesson.title, "the featured tile is not the first lesson not yet done")
        featured.tap()
        let title = app.staticTexts["lesson.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "the lesson did not open")
        XCTAssertEqual(title.label, lesson.title)

        let markDone = app.buttons["lesson.markDone"]
        XCTAssertTrue(markDone.waitForExistence(timeout: 30), "no Mark as done")
        XCTAssertEqual(markDone.label, "Mark as done")
        scrollUntilVisible(app, markDone)
        markDone.tap()

        let doneStatus = app.descendants(matching: .any)["lesson.done"]
        XCTAssertTrue(doneStatus.waitForExistence(timeout: 30), "Done did not appear")
        XCTAssertEqual(doneStatus.label, "Done")
        XCTAssertFalse(app.buttons["lesson.markDone"].exists, "Mark as done is still shown")
        XCTAssertTrue(app.staticTexts["lesson.title"].exists, "Mark as done left the lesson")
        XCTAssertFalse(app.descendants(matching: .any)["lesson.markDone.error"].exists)
        app.attachScreenshot(named: "Lesson marked as done", to: self)

        // Back on the list: one more done, and this row says so.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Learn"].waitForExistence(timeout: 10))
        let expectedProgress = LearnBackend.progressText(done: doneBefore + 1, total: before.count)
        let progress = app.descendants(matching: .any)["learn.progress"]
        XCTAssertTrue(waitFor(progress, label: expectedProgress), "progress: \(progress.label)")
        XCTAssertTrue(rowSaysDone(app.buttons["learn.lesson.\(lesson.slug)"]), "the row does not say done")

        let after = try await LearnBackend.visibleLessons(email: account.email, password: account.password)
        XCTAssertEqual(after.first { $0.slug == lesson.slug }?.completed, true, "the server did not record the lesson as done")

        // After a relaunch (the server's record, not this screen's memory).
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "the session did not restore")
        openLearnFromAccount(app)
        let row = app.buttons["learn.lesson.\(lesson.slug)"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(progress, label: expectedProgress), "progress after relaunch: \(progress.label)")
        XCTAssertTrue(rowSaysDone(row), "the row does not say done after a relaunch")
    }

    // MARK: - L.10 test 3: Next lesson (AC13), and the reader's words (AC9)

    /// The first visible lesson's next row names the second and opens it; Back
    /// returns to the first. The last visible lesson has no next row. No crypto
    /// word, emoji, "!" or em dash in any visible lesson's text.
    @MainActor
    func testNextLessonOpensTheFollowingLesson() async throws {
        let password = try UITestAccount.demoPassword()
        let expected = try LearnBackend.visible(from: await UITestAPI.lessons())
        guard expected.count >= 2, let first = expected.first, let last = expected.last else {
            throw XCTSkip("needs at least two visible lessons")
        }
        let second = expected[1]

        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        openLearnFromAccount(app)

        openLessonRow(app, first)
        try assertReaderCopy(app, first)
        let next = app.buttons["lesson.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 30), "no next row on the first lesson")
        XCTAssertTrue(next.label.contains(second.title), "next row: \(next.label)")
        scrollUntilVisible(app, next)
        next.tap()
        XCTAssertTrue(waitFor(app.staticTexts["lesson.title"], label: second.title), "the next row did not open \(second.title)")
        try assertReaderCopy(app, second)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(waitFor(app.staticTexts["lesson.title"], label: first.title), "Back did not return to \(first.title)")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Learn"].waitForExistence(timeout: 10))

        // Any lesson between the second and the last: its words.
        for lesson in expected.dropFirst(2).dropLast() {
            openLessonRow(app, lesson)
            try assertReaderCopy(app, lesson)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["Learn"].waitForExistence(timeout: 10))
        }

        // The last lesson: no next row once the lesson has loaded.
        openLessonRow(app, last)
        try assertReaderCopy(app, last)
        let action = app.buttons["lesson.markDone"].exists ? app.buttons["lesson.markDone"] : app.descendants(matching: .any)["lesson.done"]
        scrollUntilVisible(app, action)
        settle(1)
        XCTAssertFalse(app.buttons["lesson.next"].exists, "the last lesson offers a next lesson")
        app.attachScreenshot(named: "Last lesson, no next row", to: self)
    }

    // MARK: - L.10 test 5: offline (AC6, AC7)

    /// Learn visited online, then relaunched against a port where nothing
    /// listens: the list shows its snapshot with the "not connected" banner
    /// and its age; a lesson never opened shows its error state with no Mark
    /// as done; the lesson opened online shows its snapshot, and Mark as done
    /// fails with a banner and never shows "Done". Nothing is sent.
    @MainActor
    func testLearnOfflineShowsSnapshotOrError() async throws {
        let password = try UITestAccount.demoPassword()
        let expected = try LearnBackend.visible(from: await UITestAPI.lessons())
        guard expected.count >= 2 else { throw XCTSkip("needs at least two visible lessons") }
        // The lesson opened online; another one is never opened.
        let cached = expected.first { !$0.completed } ?? expected[0]
        guard let neverOpened = expected.first(where: { $0.slug != cached.slug }) else { return }

        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        openLearnFromAccount(app)
        openLessonRow(app, cached)
        XCTAssertTrue(
            app.buttons["lesson.markDone"].waitForExistence(timeout: 30) || app.descendants(matching: .any)["lesson.done"].exists,
            "the lesson did not load online"
        )
        app.terminate()

        let offline = XCUIApplication()
        offline.launchArguments = ["-dev.apiBaseURL", "http://127.0.0.1:9/api"]
        offline.launch()
        XCTAssertTrue(offline.tabBars.firstMatch.waitForExistence(timeout: 30), "the cached session did not open the tabs")
        openLearnFromAccount(offline)

        // The list: the snapshot, the banner and its age.
        let banner = offline.descendants(matching: .any)["learn.banner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "no banner on the cached list")
        XCTAssertTrue(banner.label.contains(Self.notConnected), "banner: \(banner.label)")
        XCTAssertTrue(offline.staticTexts["learn.updated"].label.hasPrefix("Updated "), "no snapshot age on the list")
        XCTAssertEqual(learnRows(offline).map(\.slug), expected.map(\.slug), "the cached list is not the last one")
        offline.attachScreenshot(named: "Learn offline with the snapshot", to: self)

        // A lesson never opened: the list's snapshot prefills its header
        // while it loads; once the read fails, the error state replaces it,
        // with no action.
        tapLessonRow(offline, neverOpened)
        let error = offline.descendants(matching: .any)["lesson.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 30), "no error state for a lesson never opened")
        XCTAssertTrue(offline.staticTexts["We couldn't load this lesson"].exists)
        XCTAssertTrue(offline.staticTexts[Self.notConnected].exists)
        XCTAssertTrue(offline.buttons["Try again"].exists)
        XCTAssertFalse(offline.buttons["lesson.markDone"].exists, "Mark as done on a lesson that never loaded")
        XCTAssertFalse(offline.staticTexts["lesson.title"].exists, "lesson text on the error state")
        offline.attachScreenshot(named: "Lesson never opened, offline", to: self)
        offline.navigationBars.buttons.element(boundBy: 0).tap()

        // The cached lesson: its snapshot; Mark as done fails and stays.
        openLessonRow(offline, cached)
        XCTAssertTrue(waitFor(offline.staticTexts["lesson.title"], label: cached.title))
        XCTAssertTrue(offline.descendants(matching: .any)["lesson.banner"].waitForExistence(timeout: 30), "no banner on the cached lesson")
        let markDone = offline.buttons["lesson.markDone"]
        guard markDone.exists else {
            throw XCTSkip("\(cached.slug) is done on the demo account, so Mark as done can't be tried offline")
        }
        scrollUntilVisible(offline, markDone)
        markDone.tap()
        let failure = offline.descendants(matching: .any)["lesson.markDone.error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 30), "no banner after a failed Mark as done")
        XCTAssertTrue(failure.label.contains(Self.notConnected), "Mark as done banner: \(failure.label)")
        XCTAssertTrue(markDone.waitForExistence(timeout: 5) && markDone.isEnabled, "Mark as done is not back after the failure")
        // The banner went in above the button; the screen scrolls the button
        // (the retry) back into view, clear of the tab bar.
        let tabBarTop = offline.tabBars.firstMatch.frame.minY
        let deadline = Date().addingTimeInterval(3)
        while markDone.frame.maxY > tabBarTop && Date() < deadline { settle(0.2) }
        XCTAssertLessThanOrEqual(markDone.frame.maxY, tabBarTop, "Mark as done is under the tab bar after the failure")
        XCTAssertFalse(offline.descendants(matching: .any)["lesson.done"].exists, "Done after a failed save")
        offline.attachScreenshot(named: "Mark as done offline", to: self)
        offline.terminate()
    }

    // MARK: - L.10 test 6: the largest text size (AC10)

    /// AX5: the list and a lesson scroll, and the lesson's action and its next
    /// row become hittable after scrolling. Read-only.
    @MainActor
    func testLearnAtTheLargestTextSize() async throws {
        let password = try UITestAccount.demoPassword()
        let expected = try LearnBackend.visible(from: await UITestAPI.lessons())
        guard let first = expected.first else { throw XCTSkip("no visible lesson") }

        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        app.terminate()

        let large = XCUIApplication()
        large.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        large.launch()
        XCTAssertTrue(large.tabBars.firstMatch.waitForExistence(timeout: 30), "the session did not restore")
        openLearnFromAccount(large)
        large.attachScreenshot(named: "Learn (AX5)", to: self)
        if let last = expected.last {
            let lastRow = large.buttons["learn.lesson.\(last.slug)"]
            XCTAssertTrue(lastRow.waitForExistence(timeout: 10))
            scrollUntilVisible(large, lastRow, maxSwipes: 20)
            XCTAssertTrue(lastRow.isHittable, "the last row is not reachable at AX5")
            large.attachScreenshot(named: "Learn rows (AX5)", to: self)
        }

        openLessonRow(large, first, maxSwipes: 20)
        let markDone = large.buttons["lesson.markDone"]
        XCTAssertTrue(
            markDone.waitForExistence(timeout: 30) || large.descendants(matching: .any)["lesson.done"].exists,
            "the lesson did not load"
        )
        let action = markDone.exists ? markDone : large.descendants(matching: .any)["lesson.done"]
        scrollUntilVisible(large, action, maxSwipes: 40)
        XCTAssertTrue(action.isHittable, "Mark as done or Done is not reachable at AX5")
        large.attachScreenshot(named: "Lesson action (AX5)", to: self)
        if expected.count >= 2 {
            let next = large.buttons["lesson.next"]
            XCTAssertTrue(next.waitForExistence(timeout: 10), "no next row")
            scrollUntilVisible(large, next, maxSwipes: 10)
            XCTAssertTrue(next.isHittable, "the next row is not reachable at AX5")
            large.attachScreenshot(named: "Lesson next row (AX5)", to: self)
        }
        large.terminate()
    }

    // MARK: - L.10 test 7: dark mode (AC11)

    /// Dark-mode screenshots of the list and a lesson; the ground is
    /// `#000000` at the left edge and the top corners, and the featured tile
    /// is `#141414`. `XCUIDevice.shared.appearance` does not switch these
    /// simulators, so this needs the simulator in dark appearance first
    /// (`xcrun simctl ui '<sim>' appearance dark`, then this test alone); in
    /// light appearance it skips. Read-only.
    @MainActor
    func testLearnInDarkMode() async throws {
        let password = try UITestAccount.demoPassword()
        let expected = try LearnBackend.visible(from: await UITestAPI.lessons())
        guard let first = expected.first else { throw XCTSkip("no visible lesson") }

        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        openLearnFromAccount(app)
        settle(1)
        let shot = app.screenshot()
        guard let edge = pixel(shot, app, x: 2, y: app.frame.midY), edge.luminance < 0.3 else {
            throw XCTSkip("The simulator is in light appearance. Run `xcrun simctl ui '<sim>' appearance dark`, then this test alone.")
        }
        assertCanvasIsBlack(shot, app, screen: "Learn")
        let featured = app.buttons["learn.featured"]
        if featured.exists, let tile = pixel(shot, app, x: featured.frame.minX + 6, y: featured.frame.midY) {
            XCTAssertTrue(tile.isNear(0x14, 0x14, 0x14), "the featured tile is not #141414 in dark: \(tile)")
        }
        app.attachScreenshot(named: "Learn (dark)", to: self)

        openLessonRow(app, first)
        XCTAssertTrue(
            app.buttons["lesson.markDone"].waitForExistence(timeout: 30) || app.descendants(matching: .any)["lesson.done"].exists,
            "the lesson did not load"
        )
        settle(1)
        assertCanvasIsBlack(app.screenshot(), app, screen: "the lesson")
        app.attachScreenshot(named: "Lesson (dark)", to: self)
        app.swipeUp()
        app.swipeUp()
        assertCanvasIsBlack(app.screenshot(), app, screen: "the scrolled lesson")
        app.attachScreenshot(named: "Lesson scrolled (dark)", to: self)
    }

    // MARK: - SPEC §3.3: the lesson title in the bar

    /// At rest the bar has no title. While the bar covers only part of the
    /// content title, it stays empty; at the first small step that leaves
    /// the content title fully under the bar, the bar shows the lesson
    /// title; when it comes back, the bar title clears. Read-only.
    @MainActor
    func testLessonTitleAppearsInTheBarAfterScrolling() async throws {
        let password = try UITestAccount.demoPassword()
        let expected = try LearnBackend.visible(from: await UITestAPI.lessons())
        guard let first = expected.first else { throw XCTSkip("no visible lesson") }

        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        openLearnFromAccount(app)
        openLessonRow(app, first)
        XCTAssertTrue(
            app.buttons["lesson.markDone"].waitForExistence(timeout: 30) || app.descendants(matching: .any)["lesson.done"].exists,
            "the lesson did not load"
        )
        let bar = app.navigationBars.firstMatch
        let barTitle = bar.staticTexts[first.title]
        XCTAssertFalse(barTitle.exists, "the bar has a title at rest")

        // 20 pt drags, so a step lands while the title is partly under the
        // bar (it is about 41 pt tall). Within 1 pt of the crossing nothing
        // is asserted: the two frames come from different reads.
        let title = app.staticTexts["lesson.title"]
        let scroll = app.scrollViews["lesson.scroll"]
        var drags = 0
        var sawPartlyUnder = false
        while title.frame.maxY > bar.frame.maxY && drags < 40 {
            let frame = title.frame
            let barBottom = bar.frame.maxY
            if frame.minY < barBottom && frame.maxY > barBottom + 1 {
                sawPartlyUnder = true
                XCTAssertFalse(barTitle.exists, "the bar shows the title while the content title is only partly under it (maxY \(frame.maxY), bar \(barBottom))")
            }
            drag(scroll, by: 20)
            drags += 1
        }
        XCTAssertTrue(sawPartlyUnder, "no step left the content title partly under the bar")
        XCTAssertLessThanOrEqual(title.frame.maxY, bar.frame.maxY, "the content title never went under the bar")
        XCTAssertTrue(barTitle.waitForExistence(timeout: 5), "the bar title did not appear once the content title was fully under the bar")
        app.attachScreenshot(named: "Lesson title in the bar", to: self)

        for _ in 0..<4 { scroll.swipeDown() }
        XCTAssertGreaterThan(title.frame.minY, bar.frame.maxY, "the content title did not come back")
        XCTAssertTrue(barTitle.waitForNonExistence(timeout: 5), "the bar title did not clear")
    }

    // MARK: - Helpers

    private static let notConnected = "We couldn't reach MoolaHub. Check your connection and try again."

    /// Account tab → `account.row.learn` → the Learn list with its rows.
    @MainActor
    private func openLearnFromAccount(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        app.selectTab("Account", file: file, line: line)
        let row = app.buttons["account.row.learn"]
        XCTAssertTrue(row.waitForExistence(timeout: 15), "no account.row.learn on Account", file: file, line: line)
        scrollUntilVisible(app, row, maxSwipes: 10)
        row.tap()
        XCTAssertTrue(app.navigationBars["Learn"].waitForExistence(timeout: 10), "Learn did not open", file: file, line: line)
        let loaded = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "learn.lesson.")).firstMatch
        XCTAssertTrue(loaded.waitForExistence(timeout: 30), "the Learn list did not load", file: file, line: line)
    }

    /// Taps the list row of `lesson` and waits for its reader.
    @MainActor
    private func openLessonRow(_ app: XCUIApplication, _ lesson: LearnBackend.Lesson, maxSwipes: Int = 6, file: StaticString = #filePath, line: UInt = #line) {
        tapLessonRow(app, lesson, maxSwipes: maxSwipes, file: file, line: line)
        XCTAssertTrue(waitFor(app.staticTexts["lesson.title"], label: lesson.title), "\(lesson.slug) did not open", file: file, line: line)
    }

    /// Taps the list row of `lesson` (the reader may show its error state).
    @MainActor
    private func tapLessonRow(_ app: XCUIApplication, _ lesson: LearnBackend.Lesson, maxSwipes: Int = 6, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["learn.lesson.\(lesson.slug)"]
        XCTAssertTrue(row.waitForExistence(timeout: 30), "no row for \(lesson.slug)", file: file, line: line)
        scrollUntilVisible(app, row, maxSwipes: maxSwipes)
        row.tap()
    }

    /// The list's rows, top to bottom, with their slugs.
    @MainActor
    private func learnRows(_ app: XCUIApplication) -> [(slug: String, element: XCUIElement)] {
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "learn.lesson."))
        return query.allElementsBoundByIndex
            .map { (slug: String($0.identifier.dropFirst("learn.lesson.".count)), element: $0) }
            .sorted { $0.element.frame.minY < $1.element.frame.minY }
    }

    @MainActor
    private func rowSaysDone(_ row: XCUIElement) -> Bool {
        (row.value as? String)?.contains("done") == true
    }

    @MainActor
    private func learnProgress(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["learn.progress"].label
    }

    /// Lets the screen settle for `seconds` (animations, a late frame).
    @MainActor
    private func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits up to `timeout` seconds for `element` to exist with `label`. A
    /// predicate wait, so an element that goes away between two reads (a
    /// prefilled title replaced by the error state) never fails the test.
    @MainActor
    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label == %@", label)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Scrolls the screen until `element` sits between the navigation bar and
    /// the tab bar (swiping up for an element below, down for one above).
    @MainActor
    private func scrollUntilVisible(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 6) {
        guard element.waitForExistence(timeout: 10) else { return }
        for _ in 0..<maxSwipes {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 0
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.frame.maxY
            if element.frame.minY >= top && element.frame.maxY <= bottom && element.isHittable { return }
            if element.frame.minY < top {
                app.swipeDown()
            } else {
                drag(app.windows.firstMatch, by: min(300, max(80, element.frame.maxY - bottom + 40)))
            }
        }
    }

    /// Drags the content up by about `points` (a slow drag, no fling).
    @MainActor
    private func drag(_ element: XCUIElement, by points: CGFloat) {
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
        let end = start.withOffset(CGVector(dx: 0, dy: -points))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// AC9 on the reader: once `lesson` has loaded (its Mark as done or Done
    /// exists), no crypto word, emoji, "!" or em dash in its words. The action
    /// comes after the text in one non-lazy stack, so one accessibility
    /// snapshot holds every section and takeaway without scrolling.
    @MainActor
    private func assertReaderCopy(_ app: XCUIApplication, _ lesson: LearnBackend.Lesson, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(
            app.buttons["lesson.markDone"].waitForExistence(timeout: 30) || app.descendants(matching: .any)["lesson.done"].exists,
            "\(lesson.slug) did not load",
            file: file, line: line
        )
        try assertNoCryptoWords(app, file: file, line: line)
        assertPlainCopy(app, file: file, line: line)
    }

    /// AC9: no emoji, "!" or em dash in any label or value on screen.
    @MainActor
    private func assertPlainCopy(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        var texts: [String] = []
        func walk(_ node: any XCUIElementSnapshot) {
            texts.append(node.label)
            if let value = node.value as? String { texts.append(value) }
            for child in node.children { walk(child) }
        }
        guard let snapshot = try? app.snapshot() else {
            XCTFail("no accessibility snapshot", file: file, line: line)
            return
        }
        walk(snapshot)
        let offenders = texts.filter { text in
            text.contains("!") || text.contains("\u{2014}") || Self.containsEmoji(text)
        }
        XCTAssertEqual(offenders, [], "emoji, \"!\" or em dashes on screen", file: file, line: line)
    }

    /// DESIGN A7.4's emoji predicate (the one `CopyCheckTests` and
    /// `EmojiIdentity` use).
    private static func containsEmoji(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            if scalar.properties.isEmojiPresentation || scalar.value == 0x20E3 { return true }
            if scalar.properties.isEmoji, !scalar.isASCII, index + 1 < scalars.count, scalars[index + 1].value == 0xFE0F {
                return true
            }
        }
        return false
    }

    // MARK: Pixels (AC11)

    private struct Pixel: CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        var luminance: Double {
            (0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)) / 255
        }

        func isNear(_ r: Int, _ g: Int, _ b: Int, tolerance: Int = 3) -> Bool {
            abs(red - r) <= tolerance && abs(green - g) <= tolerance && abs(blue - b) <= tolerance
        }

        var description: String { String(format: "#%02X%02X%02X", red, green, blue) }
    }

    /// The colour at a point (in points) of a screenshot of `app`.
    @MainActor
    private func pixel(_ shot: XCUIScreenshot, _ app: XCUIApplication, x: CGFloat, y: CGFloat) -> Pixel? {
        guard let image = shot.image.cgImage, app.frame.width > 0 else { return nil }
        let scale = CGFloat(image.width) / app.frame.width
        guard let crop = image.cropping(to: CGRect(x: Int(x * scale), y: Int(y * scale), width: 1, height: 1)) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        return drawn ? Pixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2])) : nil
    }

    /// The left edge (mid-screen) and both top corners are `canvas` black.
    @MainActor
    private func assertCanvasIsBlack(_ shot: XCUIScreenshot, _ app: XCUIApplication, screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let points = [
            CGPoint(x: 2, y: app.frame.midY),
            CGPoint(x: 2, y: 2),
            CGPoint(x: app.frame.maxX - 2, y: 2),
        ]
        for point in points {
            guard let found = pixel(shot, app, x: point.x, y: point.y) else {
                XCTFail("no pixel at \(point) on \(screen)", file: file, line: line)
                continue
            }
            XCTAssertTrue(found.isNear(0, 0, 0), "\(screen) ground at \(point) is \(found), not #000000", file: file, line: line)
        }
    }
}

// MARK: - Server reads (setup only, never through the app)

/// The lessons the app should show, read with the test's own session and
/// filtered by the same allow-list as Domain's `LearnCatalog` (a UI test
/// can't import it).
private enum LearnBackend {
    struct Lesson: Decodable, Equatable {
        let slug: String
        let title: String
        let category: String
        let completed: Bool
    }

    static let shownCategories: Set<String> = ["circles", "personal-finance"]
    /// The seed's crypto and remittance lessons, never shown on iOS.
    static let hiddenSeedSlugs = ["understanding-usdc", "understanding-blockchain", "sending-money-internationally"]

    static func visible(from data: Data) throws -> [Lesson] {
        try JSONDecoder().decode([Lesson].self, from: data).filter { shownCategories.contains($0.category) }
    }

    /// W10.9-ln4.
    static func progressText(done: Int, total: Int) -> String {
        total == 1 ? "\(done) of 1 lesson done" : "\(done) of \(total) lessons done"
    }

    private struct SessionResponse: Decodable {
        let sessionToken: String?
    }

    /// `GET /learn/lessons` for an account without two-factor (a throwaway
    /// from `AuthTestAPI.registerVerifiedAccount()`): sign in, read, sign out.
    static func visibleLessons(email: String, password: String) async throws -> [Lesson] {
        let (loginStatus, loginData) = try await AuthTestAPI.send("POST", "/auth/login", json: [
            "email": email, "password": password, "rememberMe": true,
        ])
        guard loginStatus == 200, let token = try JSONDecoder().decode(SessionResponse.self, from: loginData).sessionToken else {
            throw AuthTestError("login returned \(loginStatus) without a session")
        }
        var request = URLRequest(url: AuthTestAPI.baseURL.appendingPathComponent("learn/lessons"))
        request.httpMethod = "GET"
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue(token, forHTTPHeaderField: "x-session-token")
        let result: Result<(Data, URLResponse), any Error>
        do {
            result = .success(try await URLSession.shared.data(for: request))
        } catch {
            result = .failure(error)
        }
        _ = try? await AuthTestAPI.send("POST", "/auth/logout", json: [:], token: token)
        let (data, response) = try result.get()
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw AuthTestError("GET /learn/lessons returned \(status)") }
        return try visible(from: data)
    }
}
