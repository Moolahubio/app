import XCTest

/// End-to-end UI tests for the Home feature (Home tab, Add test money, Cash out)
/// and the Activity tab, run against the local dev backend through
/// `apps/ios/scripts/ui-test.sh`. Owned by the Home engineer. Every helper is
/// `private` so it never collides with another feature's test file.
///
/// Numbers on screen are compared with what the server returns for the same
/// account (`GET /dashboard/summary`, `GET /activity`), fetched by the test
/// itself with its own session. Test money amounts stay small.
final class HomeFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Home renders real data

    @MainActor
    func testHomeShowsGreetingBalanceGoalsGroupsAndRecentActivity() async throws {
        let password = try UITestAccount.demoPassword()
        let backend = try await HomeBackend.signIn(email: UITestAccount.demoEmail, password: password)
        addTeardownBlock { await backend.signOut() }

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)

        // Greeting with the first name from /auth/me.
        let user = try await backend.me()
        let firstName = user.name.split(separator: " ").first.map(String.init) ?? ""
        XCTAssertFalse(firstName.isEmpty, "the demo account has a name")
        let greeting = app.staticTexts["home.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15), "greeting did not appear")
        XCTAssertEqual(greeting.label, "Good to see you, \(firstName)")
        XCTAssertFalse(homeElement(app, labelMatching: "Welcome back").exists, "Home shows one greeting")

        // Balance card equals GET /dashboard/summary.
        let summary = try await assertHomeMatchesServer(app, backend: backend)
        app.attachScreenshot(named: "Home (light)", to: self)

        // Disclosure footer opens About your balance.
        let footer = app.buttons["Held as USDC. Not a bank deposit. Not insured."]
        XCTAssertTrue(footer.exists, "disclosure footer missing")
        footer.tap()
        XCTAssertTrue(app.staticTexts["About your balance"].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "About your balance (light)", to: self)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["About your balance"].waitForNonExistence(timeout: 5))

        let scroll = app.scrollViews["home.scroll"]

        // Goals preview: the server's goals, in its order, at most 4.
        XCTAssertFalse(summary.activeGoals.isEmpty, "the demo account has seeded goals")
        XCTAssertTrue(homeElement(app, labelMatching: "Your goals").exists)
        for goal in summary.activeGoals.prefix(4) {
            let tile = app.descendants(matching: .any)["home.goal.\(goal.id)"]
            reveal(tile, in: scroll)
            XCTAssertTrue(tile.exists, "goal tile missing for \(goal.name)")
            XCTAssertTrue(tile.label.contains(goal.name), "goal tile label '\(tile.label)' does not name \(goal.name)")
        }
        for goal in summary.activeGoals.dropFirst(4) {
            XCTAssertFalse(app.descendants(matching: .any)["home.goal.\(goal.id)"].exists, "Home shows more than 4 goals")
        }
        app.attachScreenshot(named: "Home goals (light)", to: self)

        // Groups preview: at most 2.
        XCTAssertFalse(summary.activeCircles.isEmpty, "the demo account has seeded groups")
        for group in summary.activeCircles.prefix(2) {
            let card = app.descendants(matching: .any)["home.group.\(group.id)"]
            reveal(card, in: scroll)
            XCTAssertTrue(card.exists, "group card missing for \(group.name)")
            XCTAssertTrue(card.label.contains(group.name), "group card label '\(card.label)' does not name \(group.name)")
        }
        app.attachScreenshot(named: "Home groups (light)", to: self)

        // Recent activity: the server's newest moves, at most 5, in plain language.
        XCTAssertFalse(summary.recentActivity.isEmpty, "the demo account has seeded activity")
        for item in summary.recentActivity.prefix(5) {
            let row = app.descendants(matching: .any)["home.activity.\(item.id)"]
            reveal(row, in: scroll)
            XCTAssertTrue(row.exists, "activity row missing for \(item.description)")
            XCTAssertTrue(row.label.contains(item.description), "row label '\(row.label)' does not contain '\(item.description)'")
            if let cents = item.amountCents, cents != 0 {
                let spoken = (cents > 0 ? "plus " : "minus ") + spokenDollars(abs(cents))
                XCTAssertTrue(row.label.contains(spoken), "row label '\(row.label)' does not say '\(spoken)'")
            }
        }
        app.attachScreenshot(named: "Home recent activity (light)", to: self)

        try assertNoCryptoWords(app)
    }

    @MainActor
    func testHomeShowsTheEmptyGoalsCardForAnAccountWithNoGoals() async throws {
        let password = try UITestAccount.demoPassword()
        let email = "kofi@moolahub.test"
        let backend = try await HomeBackend.signIn(email: email, password: password)
        addTeardownBlock { await backend.signOut() }
        let summary = try await backend.summary()
        guard summary.activeGoals.isEmpty else {
            throw XCTSkip("kofi@ has goals now; the empty goals card can't be shown with this account")
        }

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, email: email, password: password)

        let user = try await backend.me()
        let firstName = user.name.split(separator: " ").first.map(String.init) ?? ""
        let greeting = app.staticTexts["home.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 15))
        XCTAssertEqual(greeting.label, "Good to see you, \(firstName)")
        _ = try await assertHomeMatchesServer(app, backend: backend)

        let emptyText = app.staticTexts["No goals yet. Create your first one."]
        reveal(emptyText, in: app.scrollViews["home.scroll"])
        XCTAssertTrue(emptyText.exists, "empty goals card missing")
        XCTAssertTrue(app.buttons["Create goal"].exists, "Create goal button missing")
        app.attachScreenshot(named: "Home with no goals (light)", to: self)
    }

    // MARK: - Add test money

    @MainActor
    func testAddTestMoneyWithAPresetAndATypedAmountRaisesTheBalanceByExactlyThatAmount() async throws {
        let password = try UITestAccount.demoPassword()
        let backend = try await HomeBackend.signIn(email: UITestAccount.demoEmail, password: password)
        addTeardownBlock { await backend.signOut() }

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        _ = try await assertHomeMatchesServer(app, backend: backend)
        let before = try await readFigures(app)

        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 5), "Add test money sheet did not open")
        XCTAssertTrue(homeElement(app, labelContaining: "Test money isn't real and can't be cashed out.").exists, "test money banner missing")
        XCTAssertTrue(app.staticTexts["Up to $1,000.00 at a time"].exists, "context line missing")
        let submit = app.buttons["home.addMoney.submit"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "Add test money must be disabled with no amount")
        XCTAssertEqual(amountValue(app), "empty")
        app.attachScreenshot(named: "Add test money (light)", to: self)

        // Preset, then edit it by typing: $50 → $5 → $5.25.
        app.buttons["50.00 US dollars"].tap()
        XCTAssertEqual(amountValue(app), "50.00 US dollars")
        XCTAssertTrue(submit.isEnabled)
        app.buttons["delete"].tap()
        XCTAssertEqual(amountValue(app), "5.00 US dollars")
        app.buttons["decimal point"].tap()
        app.buttons["2"].tap()
        app.buttons["5"].tap()
        XCTAssertEqual(amountValue(app), "5.25 US dollars")
        XCTAssertTrue(submit.isEnabled)
        app.attachScreenshot(named: "Add test money with an amount (light)", to: self)

        // Async tests keep going after a failed assertion, so check the exact
        // amount once more before the one tap that moves money.
        guard amountValue(app) == "5.25 US dollars", submit.isEnabled else {
            XCTFail("not sending: the amount on screen is not $5.25")
            return
        }
        let sentAt = Date()
        submit.tap()

        // Receipt: Done only once Activity has the matching deposit. (Home's
        // Recent activity can also hold a "Test money added" text, so the
        // receipt is recognised by its Status row.)
        let statusRow = receiptStatusRow(app)
        XCTAssertTrue(statusRow.waitForExistence(timeout: 20), "receipt did not appear")
        XCTAssertTrue(app.staticTexts["Test money added"].exists, "receipt title missing")
        let doneStatus = receiptStatusRow(app, containing: "Done")
        XCTAssertTrue(doneStatus.waitForExistence(timeout: 15), "receipt never reached Done")
        let toRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "To", "Balance")).firstMatch
        XCTAssertTrue(toRow.exists, "receipt To row missing")
        app.attachScreenshot(named: "Add test money receipt (light)", to: self)

        let deposit = try await backend.newestActivity(type: "deposit", amountCents: 525, since: sentAt)
        XCTAssertNotNil(deposit, "the server has no matching deposit")
        XCTAssertEqual(deposit.map { HomeBackendActivity.isDone($0.onchainStatus) }, true, "the server's deposit isn't done, yet the receipt said Done")

        app.buttons["Done"].tap()
        XCTAssertTrue(statusRow.waitForNonExistence(timeout: 10), "receipt did not close")

        // Home: up by exactly $5.25.
        let after = try await waitForFigures(app, timeout: 15) { $0.total == before.total + 525 }
        XCTAssertEqual(after.total - before.total, 525, "total balance did not go up by exactly $5.25")
        XCTAssertEqual(after.available - before.available, 525, "available did not go up by exactly $5.25")
        XCTAssertEqual(after.inGoals, before.inGoals, "In goals changed")

        // The new move shows in Recent activity in plain language.
        if let deposit {
            let row = app.descendants(matching: .any)["home.activity.\(deposit.id)"]
            reveal(row, in: app.scrollViews["home.scroll"])
            XCTAssertTrue(row.exists, "the new deposit is not in Recent activity")
            XCTAssertTrue(row.label.contains("Test money added"))
            XCTAssertTrue(row.label.contains("plus 5.25 US dollars"), "row label '\(row.label)'")
        }
        app.attachScreenshot(named: "Home after adding test money (light)", to: self)
    }

    @MainActor
    func testAddTestMoneyCannotContinueWithZeroOrMoreThanTheLimit() async throws {
        let password = try UITestAccount.demoPassword()
        let backend = try await HomeBackend.signIn(email: UITestAccount.demoEmail, password: password)
        addTeardownBlock { await backend.signOut() }
        let startedAt = Date()

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        _ = try await readFigures(app)

        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 5))
        let submit = app.buttons["home.addMoney.submit"]
        let limitMessage = app.staticTexts["You can add up to $1,000.00 of test money at a time."]

        // Above $1,000.00: message, and the button stays disabled.
        for key in ["1", "0", "0", "1"] { app.buttons[key].tap() }
        XCTAssertEqual(amountValue(app), "1,001.00 US dollars")
        XCTAssertTrue(limitMessage.exists, "limit message missing")
        XCTAssertFalse(submit.isEnabled, "Add test money must be disabled above $1,000.00")
        app.attachScreenshot(named: "Add test money above the limit (light)", to: self)
        // Tap the disabled button (proves it does nothing), but never an enabled one.
        guard !submit.isEnabled else {
            XCTFail("not tapping: Add test money is enabled")
            return
        }
        submit.tap()
        XCTAssertFalse(receiptStatusRow(app).waitForExistence(timeout: 3), "a disabled button sent money")

        // Presets above the limit don't exist here; $500 is the largest and allowed.
        XCTAssertTrue(app.buttons["500.00 US dollars"].isEnabled)

        // $0: no message, still disabled.
        app.buttons["delete"].press(forDuration: 1.0)
        XCTAssertEqual(amountValue(app), "empty", "long-press delete did not clear")
        app.buttons["0"].tap()
        XCTAssertEqual(amountValue(app), "0.00 US dollars")
        XCTAssertFalse(limitMessage.exists)
        XCTAssertFalse(submit.isEnabled, "Add test money must be disabled at $0")
        app.attachScreenshot(named: "Add test money at zero (light)", to: self)

        // Exactly $1,000.00 is allowed (not sent).
        for key in ["1", "0", "0", "0"] { app.buttons[key].tap() }
        XCTAssertEqual(amountValue(app), "1,000.00 US dollars")
        XCTAssertFalse(limitMessage.exists)
        XCTAssertTrue(submit.isEnabled, "$1,000.00 is the limit and must be allowed")

        // Close without adding.
        app.buttons["home.addMoney.close"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForNonExistence(timeout: 5), "sheet did not close")
        for cents: Int64 in [100_100, 100_000, 0] {
            let sent = try await backend.newestActivity(type: "deposit", amountCents: cents, since: startedAt)
            XCTAssertNil(sent, "a deposit of \(cents) cents was sent")
        }
    }

    // MARK: - Cash out

    @MainActor
    func testCashOutSheetOpensAndCloses() async throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        _ = try await readFigures(app)

        app.buttons["Cash out"].tap()
        let body = app.staticTexts["Cashing out isn't available yet. We'll let you know when it is."]
        XCTAssertTrue(body.waitForExistence(timeout: 5), "Cash out sheet did not open")
        XCTAssertTrue(app.staticTexts["Cash out"].exists)
        app.attachScreenshot(named: "Cash out (light)", to: self)
        app.buttons["Done"].tap()
        XCTAssertTrue(body.waitForNonExistence(timeout: 5), "Cash out sheet did not close")
        XCTAssertTrue(app.staticTexts["home.greeting"].exists, "not back on Home")
    }

    // MARK: - Pull to refresh

    @MainActor
    func testHomePullToRefreshShowsTheNewBalance() async throws {
        let password = try UITestAccount.demoPassword()
        let backend = try await HomeBackend.signIn(email: UITestAccount.demoEmail, password: password)
        addTeardownBlock { await backend.signOut() }

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        _ = try await assertHomeMatchesServer(app, backend: backend)
        let before = try await readFigures(app)

        // Money arrives outside the app ($1.00, one request, never retried)…
        try await backend.addTestMoney(cents: 100)
        try await Task.sleep(for: .seconds(1))
        let unchanged = try await readFigures(app)
        XCTAssertEqual(unchanged.total, before.total, "Home changed without a refresh")

        // …and shows after pulling down.
        pullToRefresh(app.scrollViews["home.scroll"])
        let after = try await waitForFigures(app, timeout: 15) { $0.total != before.total }
        XCTAssertEqual(after.total - before.total, 100, "pull to refresh did not show the new $1.00")
        _ = try await assertHomeMatchesServer(app, backend: backend)
    }

    // MARK: - Activity

    @MainActor
    func testHistoryOpensActivityWithDaySectionsPlainLanguageRowsAndPullToRefresh() async throws {
        let password = try UITestAccount.demoPassword()
        let backend = try await HomeBackend.signIn(email: UITestAccount.demoEmail, password: password)
        addTeardownBlock { await backend.signOut() }

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        _ = try await readFigures(app)

        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 5), "History did not open Activity")
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected, "Activity tab is not selected")

        let items = try await backend.activity(limit: 100)
        XCTAssertFalse(items.isEmpty, "the demo account has seeded activity")
        let firstRow = app.descendants(matching: .any)["activity.row.\(items[0].id)"]
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15), "Activity did not load")
        app.attachScreenshot(named: "Activity (light)", to: self)

        // Day sections: the first two days the server has, with §2.4 titles.
        let scroll = app.scrollViews["activity.scroll"]
        let days = expectedDaySections(items)
        for day in days.prefix(2) {
            let header = activityHeader(app, title: day.title)
            reveal(header, in: scroll)
            XCTAssertTrue(header.exists, "missing day header '\(day.title)'")
            for item in day.items.prefix(3) {
                let row = app.descendants(matching: .any)["activity.row.\(item.id)"]
                reveal(row, in: scroll)
                XCTAssertTrue(row.exists, "missing row \(item.description)")
                XCTAssertTrue(row.label.contains(item.description), "row label '\(row.label)'")
                XCTAssertTrue(row.label.contains(Self.kindWord(item.type)), "row label '\(row.label)' lacks '\(Self.kindWord(item.type))'")
            }
        }
        app.attachScreenshot(named: "Activity scrolled (light)", to: self)
        try assertNoCryptoWords(app)

        // Pull to refresh: a $1.07 deposit made outside the app shows under Today.
        let sentAt = Date()
        try await backend.addTestMoney(cents: 107)
        let deposit = try await backend.newestActivity(type: "deposit", amountCents: 107, since: sentAt)
        let depositID = try XCTUnwrap(deposit?.id, "the server has no $1.07 deposit")
        let newRow = app.descendants(matching: .any)["activity.row.\(depositID)"]
        XCTAssertFalse(newRow.exists, "Activity changed without a refresh")
        // Back to the top before pulling: revealing two days' rows can scroll
        // far down when today already has many moves, and a pull that starts
        // below the top only scrolls the list (a fixed four swipes failed on
        // a busy demo account).
        var swipes = 0
        while !(firstRow.exists && firstRow.isHittable) && swipes < 30 {
            scroll.swipeDown()
            swipes += 1
        }
        scroll.swipeDown()
        pullToRefresh(scroll)
        XCTAssertTrue(newRow.waitForExistence(timeout: 15), "pull to refresh did not show the new deposit")
        XCTAssertTrue(newRow.label.contains("Test money added"))
        XCTAssertTrue(newRow.label.contains("plus 1.07 US dollars"), "row label '\(newRow.label)'")
        XCTAssertTrue(activityHeader(app, title: "Today").exists, "no Today section")
        app.attachScreenshot(named: "Activity after pull to refresh (light)", to: self)
    }

    // MARK: - Offline: errors, never zeros, nothing sent

    /// Relaunches the signed-in app pointed at a local port where nothing
    /// listens (the Debug-only `dev.apiBaseURL` override, passed as a launch
    /// argument so it is never saved). Home keeps its last snapshot with
    /// "Updated …" and an error banner, Activity (never loaded in this install)
    /// shows its error state rather than an empty list or $0.00, and Add test
    /// money fails before anything is sent.
    @MainActor
    func testOfflineKeepsTheLastBalanceShowsErrorsAndAddsNothing() async throws {
        let password = try UITestAccount.demoPassword()
        let backend = try await HomeBackend.signIn(email: UITestAccount.demoEmail, password: password)
        addTeardownBlock { await backend.signOut() }
        let startedAt = Date()

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        let online = try await readFigures(app)
        app.terminate()

        let offline = XCUIApplication()
        offline.launchArguments = ["-dev.apiBaseURL", "http://127.0.0.1:9/api"]
        offline.launch()
        XCTAssertTrue(offline.tabBars.firstMatch.waitForExistence(timeout: 30), "the cached session did not open the tabs")

        // Home: the last snapshot, marked as such, with the error on top.
        let shown = try await readFigures(offline)
        XCTAssertEqual(shown, online, "offline Home must show the last known balance, not new numbers")
        let banner = offline.staticTexts["We couldn't reach MoolaHub. Check your connection and try again."]
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "no error banner on Home")
        XCTAssertTrue(homeElement(offline, labelContaining: "Updated ").exists, "no snapshot age on Home")
        offline.attachScreenshot(named: "Home offline with the last snapshot (light)", to: self)

        // Activity: never loaded, so the error state (no list, no amounts).
        offline.tabBars.buttons["Activity"].tap()
        let activityError = offline.staticTexts["We couldn't load your activity"]
        XCTAssertTrue(activityError.waitForExistence(timeout: 30), "no Activity error state")
        XCTAssertTrue(offline.staticTexts["We couldn't reach MoolaHub. Check your connection and try again."].exists)
        let activityScroll = offline.scrollViews["activity.scroll"]
        let retry = activityScroll.buttons["Try again"]
        XCTAssertTrue(retry.exists, "no Try again on Activity")
        try assertNoDollarAmounts(in: activityScroll)
        offline.attachScreenshot(named: "Activity error (light)", to: self)
        retry.tap()
        XCTAssertTrue(activityError.waitForExistence(timeout: 30), "Activity error state did not come back after retrying offline")
        try assertNoDollarAmounts(in: activityScroll)

        // Add test money: refused before sending; the amount stays.
        offline.tabBars.buttons["Home"].tap()
        offline.buttons["Add money"].tap()
        XCTAssertTrue(offline.staticTexts["Add test money"].waitForExistence(timeout: 10))
        for key in ["1", "decimal point", "1", "3"] { offline.buttons[key].tap() }
        XCTAssertEqual(amountValue(offline), "1.13 US dollars")
        offline.buttons["home.addMoney.submit"].tap()
        let sheetError = offline.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "We couldn't reach MoolaHub.")).element(boundBy: 0)
        XCTAssertTrue(sheetError.waitForExistence(timeout: 30), "no error in the Add test money sheet")
        XCTAssertFalse(receiptStatusRow(offline).exists, "a receipt appeared for a move that failed")
        XCTAssertEqual(amountValue(offline), "1.13 US dollars", "the amount was not kept after the failure")
        offline.attachScreenshot(named: "Add test money offline error (light)", to: self)
        offline.buttons["home.addMoney.close"].tap()
        XCTAssertTrue(offline.staticTexts["Add test money"].waitForNonExistence(timeout: 10))

        let sent = try await backend.newestActivity(type: "deposit", amountCents: 113, since: startedAt)
        XCTAssertNil(sent, "an offline Add test money reached the server")
        offline.terminate()
    }

    // MARK: - Dark mode and largest text

    /// Dark-mode screenshots. `XCUIDevice.shared.appearance` does not switch
    /// these simulators, so this needs the simulator in dark appearance first
    /// (`xcrun simctl ui '<sim>' appearance dark`, then run this test alone);
    /// in light appearance it skips. Nothing is sent.
    @MainActor
    func testHomeActivityAndAddTestMoneyInDarkMode() async throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        _ = try await readFigures(app)
        guard let luminance = homeCanvasLuminance(app), luminance < 0.3 else {
            throw XCTSkip("The simulator is in light appearance. Run `xcrun simctl ui '<sim>' appearance dark`, then this test alone.")
        }
        app.attachScreenshot(named: "Home (dark)", to: self)
        let scroll = app.scrollViews["home.scroll"]
        scroll.swipeUp()
        app.attachScreenshot(named: "Home scrolled (dark)", to: self)
        scroll.swipeUp()
        app.attachScreenshot(named: "Home recent activity (dark)", to: self)
        for _ in 0..<3 { scroll.swipeDown() }

        let footer = app.buttons["Held as USDC. Not a bank deposit. Not insured."]
        footer.tap()
        XCTAssertTrue(app.staticTexts["About your balance"].waitForExistence(timeout: 10))
        app.attachScreenshot(named: "About your balance (dark)", to: self)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["About your balance"].waitForNonExistence(timeout: 10))

        app.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
        XCTAssertTrue(homeElement(app, labelMatching: "Today").waitForExistence(timeout: 30)
            || app.scrollViews["activity.scroll"].otherElements.firstMatch.waitForExistence(timeout: 5))
        app.attachScreenshot(named: "Activity (dark)", to: self)

        app.tabBars.buttons["Home"].tap()
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.buttons["home.addMoney.submit"].waitForExistence(timeout: 10))
        app.buttons["50.00 US dollars"].tap()
        app.attachScreenshot(named: "Add test money (dark)", to: self)
        app.buttons["home.addMoney.close"].tap()
        XCTAssertTrue(app.buttons["home.addMoney.submit"].waitForNonExistence(timeout: 10))

        app.buttons["Cash out"].tap()
        XCTAssertTrue(app.staticTexts["Cashing out isn't available yet. We'll let you know when it is."].waitForExistence(timeout: 10))
        app.attachScreenshot(named: "Cash out (dark)", to: self)
        app.buttons["Done"].tap()
    }

    /// Largest accessibility text size (AX5). Signs in at the default size,
    /// then relaunches with the content size category set; the session
    /// survives the relaunch. Nothing is sent.
    @MainActor
    func testHomeActivityAndAddTestMoneyAtTheLargestTextSize() async throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        let figures = try await readFigures(app)
        app.terminate()

        let large = XCUIApplication()
        large.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        large.launch()
        XCTAssertTrue(large.tabBars.firstMatch.waitForExistence(timeout: 30), "session did not restore")
        let relaunched = try await readFigures(large)
        XCTAssertEqual(relaunched, figures, "the balance changed between launches")
        large.attachScreenshot(named: "Home (AX5)", to: self)
        let scroll = large.scrollViews["home.scroll"]
        for index in 1...8 {
            scroll.swipeUp()
            large.attachScreenshot(named: "Home (AX5) \(index)", to: self)
        }

        large.tabBars.buttons["Activity"].tap()
        XCTAssertTrue(large.navigationBars["Activity"].waitForExistence(timeout: 10))
        XCTAssertTrue(homeElement(large, labelMatching: "Today").waitForExistence(timeout: 30)
            || large.scrollViews["activity.scroll"].otherElements.firstMatch.waitForExistence(timeout: 5))
        large.attachScreenshot(named: "Activity (AX5)", to: self)
        for index in 1...2 {
            large.scrollViews["activity.scroll"].swipeUp()
            large.attachScreenshot(named: "Activity (AX5) \(index)", to: self)
        }

        large.tabBars.buttons["Home"].tap()
        for _ in 0..<10 { scroll.swipeDown() }
        large.buttons["Add money"].tap()
        let submit = large.buttons["home.addMoney.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 10))
        XCTAssertTrue(submit.isHittable, "the main button is not pinned on screen at AX5")
        large.attachScreenshot(named: "Add test money (AX5)", to: self)
        large.buttons["home.addMoney.close"].tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 10))

        large.buttons["Cash out"].tap()
        XCTAssertTrue(large.staticTexts["Cashing out isn't available yet. We'll let you know when it is."].waitForExistence(timeout: 10))
        large.attachScreenshot(named: "Cash out (AX5)", to: self)
        large.buttons["Done"].tap()
        large.terminate()
    }

    // MARK: - Activity receipt (DESIGN.md v2 B2.7)

    /// U7's suggested test (B2.7, B2.9 item 5): an Activity row opens the
    /// move's receipt (`activity.receipt`) titled with the move's description,
    /// with its kind in the Type row, its status in the Status row and its
    /// signed amount in words (`activity.receipt.amount`); "Done" closes it.
    /// Opened twice: from Home's Recent activity and from the Activity tab,
    /// each time on the newest move the app shows. Read-only. Screenshots are
    /// named with the appearance the simulator is in.
    @MainActor
    func testActivityRowsOpenTheMoveReceipt() async throws {
        let password = try UITestAccount.demoPassword()
        let backend = try await HomeBackend.signIn(email: UITestAccount.demoEmail, password: password)
        addTeardownBlock { await backend.signOut() }

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, password: password)
        _ = try await readFigures(app)
        let look = homeAppearance(app)

        // Home's Recent activity. Other people use this account too, so take
        // the newest server move that Home already shows.
        let summary = try await backend.summary()
        XCTAssertFalse(summary.recentActivity.isEmpty, "the demo account has seeded activity")
        let homeItem = try XCTUnwrap(
            summary.recentActivity.first { app.descendants(matching: .any)["home.activity.\($0.id)"].exists },
            "none of the server's recent moves is on Home"
        )
        let homeRow = app.descendants(matching: .any)["home.activity.\(homeItem.id)"]
        reveal(homeRow, in: app.scrollViews["home.scroll"])
        XCTAssertTrue(homeRow.isHittable, "the Home activity row is not on screen")
        XCTAssertEqual(homeRow.elementType, .button, "Home activity rows open the receipt")
        homeRow.tap()
        try assertActivityReceipt(app, shows: homeItem, shot: "Activity receipt from Home (\(look))")

        // The Activity tab.
        app.selectTab("Activity")
        let items = try await backend.activity(limit: 100)
        XCTAssertFalse(items.isEmpty, "the demo account has seeded activity")
        let firstRow = app.descendants(matching: .any)["activity.row.\(items[0].id)"]
        _ = firstRow.waitForExistence(timeout: 15)
        let item = try XCTUnwrap(
            items.prefix(10).first { app.descendants(matching: .any)["activity.row.\($0.id)"].exists },
            "none of the server's newest moves is on Activity"
        )
        let row = app.descendants(matching: .any)["activity.row.\(item.id)"]
        reveal(row, in: app.scrollViews["activity.scroll"])
        XCTAssertEqual(row.elementType, .button, "Activity rows open the receipt")
        row.tap()
        try assertActivityReceipt(app, shows: item, shot: "Activity receipt (\(look))")
        app.attachScreenshot(named: "Activity (\(look))", to: self)
    }

    // MARK: - Empty states (DESIGN.md v2 B2.1 C6 to C8, B2.6 D3)

    /// A brand-new account: Home shows the empty goals sentence with "Create
    /// goal", no "Your groups" and "No activity yet.", with no "See all" (D8);
    /// Activity shows "No activity yet" with no button. Creates one
    /// "QA Home Empty" account (h…@moolahub.test, a generated password that is
    /// never printed) and moves no money. Needs `MH_BACKEND_LOG` for the
    /// verification code; skips without it.
    @MainActor
    func testANewAccountShowsTheEmptyHomeSectionsAndAnEmptyActivity() async throws {
        let account = try await HomeBackend.registerFreshAccount()
        let backend = try await HomeBackend.signIn(email: account.email, password: account.password)
        addTeardownBlock { await backend.signOut() }
        guard try await backend.activity(limit: 5).isEmpty else {
            throw XCTSkip("a new account already has activity on this server")
        }

        let app = XCUIApplication.launchedClean()
        homeSignIn(app, email: account.email, password: account.password)
        let summary = try await assertHomeMatchesServer(app, backend: backend)
        XCTAssertTrue(summary.activeGoals.isEmpty && summary.activeCircles.isEmpty && summary.recentActivity.isEmpty)
        let look = homeAppearance(app)
        app.attachScreenshot(named: "Home new account (\(look))", to: self)

        let scroll = app.scrollViews["home.scroll"]
        let emptyGoals = app.staticTexts["No goals yet. Create your first one."]
        reveal(emptyGoals, in: scroll)
        XCTAssertTrue(emptyGoals.exists, "empty goals sentence missing")
        XCTAssertTrue(app.buttons["Create goal"].exists, "Create goal button missing")
        XCTAssertFalse(homeElement(app, labelMatching: "Your groups").exists, "Your groups shows with no groups (C7)")
        let emptyActivity = app.staticTexts["No activity yet."]
        reveal(emptyActivity, in: scroll)
        XCTAssertTrue(emptyActivity.exists, "Home's empty activity line missing")
        XCTAssertFalse(app.buttons["See all"].exists, "See all into an empty list (D8)")
        app.attachScreenshot(named: "Home new account scrolled (\(look))", to: self)

        app.selectTab("Activity")
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No activity yet"].waitForExistence(timeout: 15), "Activity empty state missing")
        XCTAssertTrue(app.staticTexts["Money you add, move and pay in shows up here."].exists)
        XCTAssertEqual(app.scrollViews["activity.scroll"].buttons.count, 0, "the empty Activity has no button (D3)")
        try assertNoDollarAmounts(in: app.scrollViews["activity.scroll"])
        app.attachScreenshot(named: "Activity empty (\(look))", to: self)
    }

    // MARK: - Loading and never loaded (DESIGN.md v2 B2.1 C2 and C3, B2.6 D2 and D4)

    /// Home and Activity while the server does not finish answering: first the
    /// skeletons (C2, D2: the "Total balance" label, the loading elements, no
    /// amount anywhere, tiles disabled), then, when the app gives up on the
    /// read (its 60 s resource timeout), one error block with one "Try again"
    /// and still no amount (C3, D4). Needs a local proxy in front of the dev
    /// backend that starts `GET /dashboard/summary` and `GET /activity` answers
    /// but never finishes them (it trickles a byte every few seconds) and
    /// passes everything else through; its base URL comes in as
    /// `MH_HOME_SLOW_API` (`TEST_RUNNER_MH_HOME_SLOW_API=http://127.0.0.1:<port>/api`).
    /// Skips without it. Read-only.
    ///
    /// It signs in through the proxy first (so nothing is ever cached: the
    /// held reads never finish), then relaunches signed in. The skeletons are
    /// checked right after that launch, inside the app's 60 s read window,
    /// however long sign-in and its prompts took on a busy Mac.
    @MainActor
    func testASlowServerShowsSkeletonsThenOneErrorAndNoAmounts() async throws {
        guard let slowAPI = ProcessInfo.processInfo.environment["MH_HOME_SLOW_API"], !slowAPI.isEmpty else {
            throw XCTSkip("set TEST_RUNNER_MH_HOME_SLOW_API to a proxy that holds the dashboard and activity reads")
        }
        let password = try UITestAccount.demoPassword()
        let first = XCUIApplication()
        first.launchArguments = ["-mh-reset-state", "-dev.apiBaseURL", slowAPI]
        first.launch()
        first.signIn(password: password)
        first.terminate()

        let app = XCUIApplication()
        app.launchArguments = ["-dev.apiBaseURL", slowAPI]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "the session did not restore")
        let scroll = app.scrollViews["home.scroll"]

        // C2: the label, the skeletons, nothing that looks like money.
        XCTAssertTrue(homeElement(app, labelMatching: "Loading your balance\u{2026}").waitForExistence(timeout: 15), "no balance skeleton")
        XCTAssertTrue(homeElement(app, labelMatching: "Loading your goals\u{2026}").exists, "no goals skeleton")
        XCTAssertTrue(homeElement(app, labelMatching: "Loading activity\u{2026}").exists, "no activity skeleton")
        XCTAssertTrue(app.staticTexts["Total balance"].exists, "the balance label shows while loading")
        XCTAssertFalse(app.buttons["Add money"].isEnabled, "tiles are disabled while loading")
        XCTAssertFalse(app.buttons["Move to goal"].isEnabled, "tiles are disabled while loading")
        try assertNoDollarAmounts(in: scroll)
        let look = homeAppearance(app)
        app.attachScreenshot(named: "Home loading (\(look))", to: self)

        // D2 at once (Activity's read may start with the app or with its
        // tab; either way it is still held now), then D4.
        app.selectTab("Activity")
        let activityScroll = app.scrollViews["activity.scroll"]
        let loading = activityScroll.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Loading activity\u{2026}")).firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 10), "no Activity skeleton")
        try assertNoDollarAmounts(in: activityScroll)
        app.attachScreenshot(named: "Activity loading (\(look))", to: self)
        XCTAssertTrue(app.staticTexts["We couldn't load your activity"].waitForExistence(timeout: 90), "no Activity error state")
        XCTAssertTrue(activityScroll.buttons["Try again"].exists)
        try assertNoDollarAmounts(in: activityScroll)
        app.attachScreenshot(named: "Activity never loaded (\(look))", to: self)

        // C3: Home's read started first, so it has given up too: one block,
        // one retry, no sections, still no amount.
        app.selectTab("Home")
        let failed = app.staticTexts["We couldn't load your balance"]
        XCTAssertTrue(failed.waitForExistence(timeout: 90), "no balance error after the read timed out")
        XCTAssertTrue(app.staticTexts["We couldn't load this. Check your connection and try again."].exists)
        XCTAssertEqual(scroll.buttons.matching(NSPredicate(format: "label == %@", "Try again")).count, 1, "Home has exactly one Try again")
        XCTAssertTrue(app.buttons["Add money"].isEnabled)
        XCTAssertFalse(app.buttons["Move to goal"].isEnabled, "Move to goal needs the available balance")
        XCTAssertFalse(homeElement(app, labelMatching: "Your goals").exists, "sections show without data")
        try assertNoDollarAmounts(in: scroll)
        app.attachScreenshot(named: "Home never loaded (\(look))", to: self)
        app.terminate()
    }

    // MARK: - Helpers (private)

    /// The receipt an Activity or Home row opened (B2.7): checks it against
    /// the server's item, screenshots it and closes it with "Done".
    @MainActor
    private func assertActivityReceipt(
        _ app: XCUIApplication,
        shows item: HomeBackendActivity,
        shot: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let receipt = app.descendants(matching: .any)["activity.receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 10), "the Activity receipt did not open", file: file, line: line)
        XCTAssertTrue(app.staticTexts[item.description].waitForExistence(timeout: 5), "the receipt is not titled '\(item.description)'", file: file, line: line)
        // A move still processing may settle while the receipt reads Activity once.
        let words = HomeBackendActivity.isDone(item.onchainStatus) ? ["Done"]
            : item.onchainStatus == "failed" ? ["Didn't go through"]
            : ["Processing", "Done", "Didn't go through"]
        let status = receiptStatusRow(app)
        XCTAssertTrue(status.waitForExistence(timeout: 5), "no Status row", file: file, line: line)
        XCTAssertTrue(words.contains { status.label.contains($0) }, "Status row reads '\(status.label)', expected \(words[0])", file: file, line: line)
        let type = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Type", Self.kindWord(item.type))).firstMatch
        XCTAssertTrue(type.exists, "no Type row naming '\(Self.kindWord(item.type))'", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Date")).firstMatch.exists, "no Date row", file: file, line: line)
        let amount = app.descendants(matching: .any)["activity.receipt.amount"]
        if let cents = item.amountCents, cents != 0 {
            XCTAssertTrue(amount.waitForExistence(timeout: 5), "no receipt amount", file: file, line: line)
            XCTAssertEqual(amount.label, (cents > 0 ? "plus " : "minus ") + spokenDollars(abs(cents)), "the receipt's amount is signed, in words", file: file, line: line)
        } else if item.amountCents == nil {
            XCTAssertFalse(amount.exists, "an amount on a move without one", file: file, line: line)
        }
        try assertNoCryptoWords(app, file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.attachScreenshot(named: shot, to: self)
        app.buttons["Done"].tap()
        XCTAssertTrue(receipt.waitForNonExistence(timeout: 10), "Done did not close the receipt", file: file, line: line)
    }

    /// "dark" or "light", from the canvas at the left edge, for screenshot names.
    @MainActor
    private func homeAppearance(_ app: XCUIApplication) -> String {
        (homeCanvasLuminance(app) ?? 1) < 0.3 ? "dark" : "light"
    }

    /// Signs in through the real Sign in screen, then closes the prompts that
    /// can cover Home right after a sign-in: iOS's own "Save Password?" and
    /// the one-time app lock offer (shown only when the simulator has Face ID
    /// enrolled). Neither is part of this feature; both are answered "not now".
    @MainActor
    private func homeSignIn(
        _ app: XCUIApplication,
        email: String = UITestAccount.demoEmail,
        password: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        app.signIn(email: email, password: password, file: file, line: line)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // "Not Now" (iOS's Save Password, which can arrive late and sit on top
        // of the offer) is tried before "Not now" (the app lock offer).
        let prompts = [app.buttons["Not Now"], springboard.buttons["Not Now"], app.buttons["Not now"]]
        let addMoney = app.buttons["Add money"]
        // Done once Home is usable and no prompt has shown for 4 s.
        let deadline = Date().addingTimeInterval(60)
        var clearSince: Date?
        while Date() < deadline {
            if prompts.contains(where: { $0.exists }) {
                clearSince = nil
                if let prompt = prompts.first(where: { $0.exists && $0.isHittable }) {
                    prompt.tap()
                } else {
                    Thread.sleep(forTimeInterval: 0.5)
                }
                continue
            }
            if addMoney.exists && addMoney.isHittable {
                let since = clearSince ?? Date()
                clearSince = since
                if Date().timeIntervalSince(since) >= 4 { break }
            } else {
                clearSince = nil
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(addMoney.exists, "Home did not appear after sign in", file: file, line: line)
        XCTAssertTrue(addMoney.isHittable, "something still covers Home after sign in", file: file, line: line)
    }

    /// Total / available / in goals as Home shows them, read from the balance
    /// card's VoiceOver value ("3,100.00 US dollars. Available …. In goals ….").
    private struct HomeFigures: Equatable {
        let total: Int64
        let available: Int64
        let inGoals: Int64
    }

    @MainActor
    private func readFigures(_ app: XCUIApplication, timeout: TimeInterval = 30) async throws -> HomeFigures {
        // While Home loads, the "Total balance" label is already on screen
        // with no amounts (DESIGN.md v2 B2.1 C2), so wait for the element
        // that carries them.
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", "Total balance", "US dollars")).firstMatch
        guard card.waitForExistence(timeout: timeout) else {
            XCTFail("the balance never loaded")
            throw HomeBackendError.missing("balance")
        }
        let amounts = Self.spokenCents(card.value as? String ?? "")
        guard amounts.count >= 3 else {
            XCTFail("balance card value '\(card.value as? String ?? "")' has no amounts")
            throw HomeBackendError.missing("amounts")
        }
        return HomeFigures(total: amounts[0], available: amounts[1], inGoals: amounts[2])
    }

    @MainActor
    private func waitForFigures(
        _ app: XCUIApplication,
        timeout: TimeInterval,
        until condition: (HomeFigures) -> Bool
    ) async throws -> HomeFigures {
        let deadline = Date().addingTimeInterval(timeout)
        var figures = try await readFigures(app)
        while !condition(figures) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(500))
            figures = try await readFigures(app)
        }
        return figures
    }

    /// Home's figures must equal the server's for the same account. If someone
    /// else moved money between the two reads, pull to refresh and compare again.
    @MainActor
    @discardableResult
    private func assertHomeMatchesServer(_ app: XCUIApplication, backend: HomeBackend) async throws -> HomeBackendSummary {
        var mismatch = ""
        for attempt in 1...3 {
            let shown = try await readFigures(app)
            let server = try await backend.summary()
            let expected = HomeFigures(total: server.totalCents, available: server.availableCents, inGoals: server.goalTotalCents)
            if shown == expected { return server }
            mismatch = "Home \(shown) vs server \(expected) (attempt \(attempt))"
            pullToRefresh(app.scrollViews["home.scroll"])
            try await Task.sleep(for: .seconds(2))
        }
        XCTFail("Home balance doesn't match GET /dashboard/summary: \(mismatch)")
        throw HomeBackendError.missing("matching balance")
    }

    /// All "1,240.50 US dollars" amounts in a VoiceOver string, as cents.
    private static func spokenCents(_ text: String) -> [Int64] {
        guard let regex = try? NSRegularExpression(pattern: "(minus )?([0-9][0-9,]*)\\.([0-9]{2}) US dollars") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let wholeRange = Range(match.range(at: 2), in: text),
                  let fractionRange = Range(match.range(at: 3), in: text),
                  let whole = Int64(text[wholeRange].replacingOccurrences(of: ",", with: "")),
                  let fraction = Int64(text[fractionRange])
            else { return nil }
            let cents = whole * 100 + fraction
            return match.range(at: 1).location == NSNotFound ? cents : -cents
        }
    }

    /// "5.25 US dollars", "1,001.00 US dollars" (en_US, as the app speaks money).
    private func spokenDollars(_ cents: Int64) -> String {
        let whole = cents / 100
        let fraction = cents % 100
        let grouped = whole.formatted(.number.grouping(.automatic).locale(Locale(identifier: "en_US")))
        return "\(grouped).\(fraction < 10 ? "0" : "")\(fraction) US dollars"
    }

    @MainActor
    private func amountValue(_ app: XCUIApplication) -> String? {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Amount")).firstMatch.value as? String
    }

    /// Relative luminance (0–1) of the canvas at the left edge, mid-screen,
    /// to tell whether the app is drawing in dark appearance.
    @MainActor
    private func homeCanvasLuminance(_ app: XCUIApplication) -> Double? {
        guard let image = app.screenshot().image.cgImage,
              let pixel = image.cropping(to: CGRect(x: 4, y: image.height / 2, width: 1, height: 1))
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (0.2126 * Double(bytes[0]) + 0.7152 * Double(bytes[1]) + 0.0722 * Double(bytes[2])) / 255
    }

    /// The receipt's "Status" row (DESIGN.md §4.16), optionally with a status.
    @MainActor
    private func receiptStatusRow(_ app: XCUIApplication, containing status: String? = nil) -> XCUIElement {
        let predicate = status.map { NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Status", $0) }
            ?? NSPredicate(format: "label BEGINSWITH %@", "Status")
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    @MainActor
    private func homeElement(_ app: XCUIApplication, labelMatching label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label ==[c] %@", label)).firstMatch
    }

    @MainActor
    private func homeElement(_ app: XCUIApplication, labelContaining text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor
    private func activityHeader(_ app: XCUIApplication, title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// Scrolls until `element` is on screen (or gives up after a few swipes).
    @MainActor
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            scroll.swipeUp(velocity: .slow)
            swipes += 1
        }
    }

    @MainActor
    private func pullToRefresh(_ scroll: XCUIElement) {
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.6)
    }

    /// No dollar amount anywhere on screen (used on error states, which must
    /// never show $0.00 or any stand-in number).
    @MainActor
    private func assertNoDollarAmounts(in element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        var texts: [String] = []
        func walk(_ node: any XCUIElementSnapshot) {
            texts.append(node.label)
            if let value = node.value as? String { texts.append(value) }
            for child in node.children { walk(child) }
        }
        walk(try element.snapshot())
        let offenders = texts.filter { $0.contains("$") || $0.contains("US dollars") }
        XCTAssertEqual(offenders, [], "amounts shown on an error state", file: file, line: line)
    }

    /// The day sections DESIGN.md §8.9 / §2.4 expect for these items.
    private func expectedDaySections(_ items: [HomeBackendActivity]) -> [(title: String, items: [HomeBackendActivity])] {
        let calendar = Calendar.current
        let now = Date()
        var result: [(title: String, items: [HomeBackendActivity])] = []
        var currentDay: Date?
        for item in items.sorted(by: { $0.date > $1.date }) {
            let day = calendar.startOfDay(for: item.date)
            if day != currentDay {
                currentDay = day
                result.append((Self.dayTitle(day, now: now, calendar: calendar), []))
            }
            result[result.count - 1].items.append(item)
        }
        return result
    }

    private static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.abbreviated)
        if calendar.component(.year, from: day) != calendar.component(.year, from: now) {
            style = style.year()
        }
        return day.formatted(style)
    }

    /// The word VoiceOver reads first for each activity type (DESIGN.md §4.17).
    private static func kindWord(_ type: String) -> String {
        switch type {
        case "deposit": "Money added"
        case "payout": "Your payout"
        case "yield": "Earnings"
        case "contribution": "Paid in"
        case "goal_allocate": "Moved to goal"
        case "goal_release": "Moved to balance"
        case "withdrawal": "Cash out"
        case "fee": "Fee"
        case "referral_earning", "referral_withdrawal": "Invite reward"
        default: "Money moved"
        }
    }
}

// MARK: - The test's own view of the server (private to this file)

private enum HomeBackendError: Error {
    case status(Int)
    case missing(String)
}

private struct HomeBackendNamed: Decodable, Sendable {
    let id: String
    let name: String
}

private struct HomeBackendActivity: Decodable, Sendable {
    let id: String
    let type: String
    let description: String
    let amountCents: Int64?
    let onchainStatus: String?
    let createdAt: String

    var date: Date {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(createdAt))
            ?? (try? Date.ISO8601FormatStyle().parse(createdAt))
            ?? .distantPast
    }

    static func isDone(_ status: String?) -> Bool {
        status == "none" || status == "confirmed"
    }
}

private struct HomeBackendSummary: Decodable, Sendable {
    let totalCents: Int64
    let availableCents: Int64
    let goalTotalCents: Int64
    let recentActivity: [HomeBackendActivity]
    let activeGoals: [HomeBackendNamed]
    let activeCircles: [HomeBackendNamed]
}

private struct HomeBackendUser: Decodable, Sendable {
    let name: String
}

/// A separate signed-in session on the dev backend, used only to read what the
/// server says (and to add small amounts of test money "outside the app").
/// Never logs the token or the password; money requests are sent once.
private struct HomeBackend: Sendable {
    static let baseURL = "http://localhost:8787/api"
    let token: String

    static func signIn(email: String, password: String) async throws -> HomeBackend {
        struct Login: Encodable { let email: String; let password: String; let rememberMe: Bool }
        struct LoginResult: Decodable { let sessionToken: String? }
        let body = try JSONEncoder().encode(Login(email: email, password: password, rememberMe: true))
        let data = try await send("POST", "/auth/login", token: nil, body: body)
        guard let token = try JSONDecoder().decode(LoginResult.self, from: data).sessionToken else {
            throw HomeBackendError.missing("session token")
        }
        return HomeBackend(token: token)
    }

    func signOut() async {
        _ = try? await Self.send("POST", "/auth/logout", token: token, body: Data("{}".utf8))
    }

    struct FreshAccount: Sendable {
        let email: String
        let password: String
    }

    /// Registers and verifies a new "QA Home Empty" account
    /// (h…@moolahub.test: Home's own first letter in the backend log) with a
    /// generated password, reading the emailed code from the backend log
    /// (`UITestBackendLog`). Never prints the password or the code.
    static func registerFreshAccount() async throws -> FreshAccount {
        struct Register: Encodable {
            let name: String
            let username: String
            let email: String
            let password: String
            let dateOfBirth: String
        }
        struct Verify: Encodable {
            let email: String
            let code: String
        }
        struct Verified: Decodable {
            let sessionToken: String?
        }
        let handle = "h\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        let account = FreshAccount(
            email: "\(handle)@moolahub.test",
            password: "QaHome-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        )
        let mark = try UITestBackendLog.mark()
        let register = Register(name: "QA Home Empty", username: handle, email: account.email, password: account.password, dateOfBirth: "1990-01-15")
        _ = try await send("POST", "/auth/register", token: nil, body: JSONEncoder().encode(register))
        let code = try UITestBackendLog.code(.verification, emailInitial: "h", after: mark)
        let data = try await send("POST", "/auth/verify-email", token: nil, body: JSONEncoder().encode(Verify(email: account.email, code: code)))
        if let token = try JSONDecoder().decode(Verified.self, from: data).sessionToken {
            await HomeBackend(token: token).signOut()
        }
        return account
    }

    func me() async throws -> HomeBackendUser {
        try JSONDecoder().decode(HomeBackendUser.self, from: await Self.send("GET", "/auth/me", token: token, body: nil))
    }

    func summary() async throws -> HomeBackendSummary {
        try JSONDecoder().decode(HomeBackendSummary.self, from: await Self.send("GET", "/dashboard/summary", token: token, body: nil))
    }

    func activity(limit: Int) async throws -> [HomeBackendActivity] {
        try JSONDecoder().decode([HomeBackendActivity].self, from: await Self.send("GET", "/activity?limit=\(limit)", token: token, body: nil))
    }

    /// `POST /wallet/deposit`, once.
    func addTestMoney(cents: Int64) async throws {
        struct Amount: Encodable { let amountCents: Int64 }
        _ = try await Self.send("POST", "/wallet/deposit", token: token, body: JSONEncoder().encode(Amount(amountCents: cents)))
    }

    /// The newest activity item of `type` and signed amount created at or after
    /// `since` (with 5 s of clock allowance).
    func newestActivity(type: String, amountCents: Int64, since: Date) async throws -> HomeBackendActivity? {
        try await activity(limit: 20)
            .filter { $0.type == type && $0.amountCents == amountCents && $0.date >= since.addingTimeInterval(-5) }
            .max { $0.date < $1.date }
    }

    private static func send(_ method: String, _ path: String, token: String?, body: Data?) async throws -> Data {
        guard let url = URL(string: baseURL + path) else { throw HomeBackendError.missing("url") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        if let token { request.setValue(token, forHTTPHeaderField: "x-session-token") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw HomeBackendError.status(status) }
        return data
    }
}
