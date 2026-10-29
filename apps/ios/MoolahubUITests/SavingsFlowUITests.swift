import UIKit
import XCTest

/// End-to-end UI tests for the Savings feature, run against the local dev backend.
/// Owned by the Savings engineer. Keep helpers `private` so they never collide
/// with another feature's test file.
///
/// Money only moves into and out of goals this test creates ("QA Savings …");
/// the seeded goals are only read. Each test cross-checks the UI against the
/// API (the same backend) so a number on screen is never trusted on its own.
///
/// Face ID: on a device without a passcode, Move to goal's confirm needs no
/// device gate ("Confirm"). The iOS 26.5 simulator answers
/// canEvaluatePolicy(.deviceOwnerAuthentication) = true even right after
/// `simctl erase`, so the confirm says "Confirm with Face ID" and opens the
/// system prompt (the passcode screen when Face ID isn't enrolled, which a test
/// can't answer). The lifecycle test therefore needs Face ID enrolled and a
/// host helper that posts one simulated face per request:
///
///     xcrun simctl spawn '<sim>' notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
///     xcrun simctl spawn '<sim>' notifyutil -p com.apple.BiometricKit.enrollmentChanged
///     # loop: when <dir>/request appears, post
///     #   xcrun simctl spawn '<sim>' notifyutil -p com.apple.BiometricKit_Sim.pearl.<contents of request>
///     # and delete it
///     TEST_RUNNER_MH_SAVINGS_FACEID_DIR=<dir> MH_BACKEND_LOG=… apps/ios/scripts/ui-test.sh '<sim>' <dd> \
///       -only-testing:MoolahubUITests/SavingsFlowUITests
///     # then unenroll: notifyutil -s com.apple.BiometricKit.enrollmentChanged 0 and -p again
///
/// Don't post faces on a timer: a match that arrives with no prompt up can
/// leave the simulator on its Lock Screen in front of the app.
final class SavingsFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Savings list and goal detail (seeded data, read only)

    @MainActor
    func testSavingsListShowsSeededGoalsWithProgress() throws {
        let password = try UITestAccount.demoPassword()
        let api = try SavingsTestAPI.signIn(password: password)
        addTeardownBlock {
            await MainActor.run { XCUIDevice.shared.appearance = .light }
        }

        let app = XCUIApplication.launchedClean()
        savingsSignIn(app, password: password)
        savingsOpenTab(app)

        let summary = app.descendants(matching: .any)["savings.summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "Savings summary did not appear")
        XCTAssertTrue(app.navigationBars["Savings"].exists)

        // Every seeded goal's card shows the API's saved, target and percent.
        let goals = try api.goals()
        for name in ["Emergency fund", "New laptop"] {
            let goal = try XCTUnwrap(goals.first { $0.name == name }, "seeded goal \(name) missing from the API")
            let card = app.buttons["savings.goalCard.\(goal.id)"]
            XCTAssertTrue(card.waitForExistence(timeout: 5), "card for \(name) missing")
            XCTAssertEqual(card.label, name)
            let expected = "\(spoken(goal.savedCents)) saved of \(spoken(goal.targetCents)). \(percent(goal.savedCents, goal.targetCents)) percent."
            XCTAssertTrue((card.value as? String ?? "").hasPrefix(expected), "\(name) card says \(card.value ?? "nil"), expected \(expected)")
        }
        XCTAssertTrue(labeled(app, "Each goal is a pot inside your balance, not a separate account.").exists)
        let summaryValue = summary.value as? String ?? ""
        XCTAssertTrue(summaryValue.contains("Across"), "summary: \(summaryValue)")
        app.attachScreenshot(named: "Savings list (light)", to: self)

        // Goal detail for a seeded goal with history: header, plan, chart, history.
        let seeded = try XCTUnwrap(goals.first { $0.name == "Emergency fund" })
        app.buttons["savings.goalCard.\(seeded.id)"].tap()
        let header = app.descendants(matching: .any)["savings.detail.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 15), "goal detail header missing")
        XCTAssertTrue(app.navigationBars["Emergency fund"].exists)
        let headerValue = header.value as? String ?? ""
        XCTAssertTrue(headerValue.hasPrefix("\(spoken(seeded.savedCents)) saved of \(spoken(seeded.targetCents))."), "header: \(headerValue)")
        XCTAssertTrue(app.descendants(matching: .any)["savings.chart"].waitForExistence(timeout: 5), "chart missing")
        XCTAssertTrue(labeled(app, "Saved each month").exists)
        XCTAssertTrue(labeled(app, "Your plan").exists)
        app.attachScreenshot(named: "Goal detail (light)", to: self)
        app.swipeUp()
        XCTAssertTrue(labeled(app, "History").waitForExistence(timeout: 5))
        app.attachScreenshot(named: "Goal detail history (light)", to: self)

        // Dark mode: detail, then the list. Checked on the pixels: a freshly
        // erased simulator ignores appearance changes until its next boot, and
        // a "(dark)" screenshot that is really light must fail, not pass.
        XCUIDevice.shared.appearance = .dark
        XCTAssertTrue(waitForScreen(app, dark: true), "the simulator did not switch to dark appearance")
        app.swipeDown()
        app.attachScreenshot(named: "Goal detail (dark)", to: self)
        app.swipeUp()
        app.attachScreenshot(named: "Goal detail history (dark)", to: self)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        app.attachScreenshot(named: "Savings list (dark)", to: self)
        XCUIDevice.shared.appearance = .light
        XCTAssertTrue(waitForScreen(app, dark: false), "the simulator did not switch back to light appearance")

        // Largest accessibility text size: relaunch with the session kept.
        app.terminate()
        let large = XCUIApplication()
        large.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        large.launch()
        XCTAssertTrue(large.tabBars.firstMatch.waitForExistence(timeout: 20), "session was not restored")
        savingsOpenTab(large)
        XCTAssertTrue(large.descendants(matching: .any)["savings.summary"].waitForExistence(timeout: 15))
        large.attachScreenshot(named: "Savings list (AX5 text)", to: self)
        large.swipeUp()
        large.attachScreenshot(named: "Savings list scrolled (AX5 text)", to: self)
        let largeCard = large.buttons["savings.goalCard.\(seeded.id)"]
        if !largeCard.isHittable { large.swipeDown() }
        largeCard.tap()
        XCTAssertTrue(large.descendants(matching: .any)["savings.detail.header"].waitForExistence(timeout: 15))
        large.attachScreenshot(named: "Goal detail (AX5 text)", to: self)
        large.terminate()
    }

    // MARK: Create, move in, move out, delete (a QA goal only)

    @MainActor
    func testGoalLifecycleCreateMoveInMoveOutDelete() throws {
        let password = try UITestAccount.demoPassword()
        let api = try SavingsTestAPI.signIn(password: password)
        let name = "QA Savings \(Int(Date().timeIntervalSince1970) % 1_000_000)"
        // A failed run must not leave a QA goal holding demo money: delete it
        // (step-up) if it still exists. A passing run already deleted it.
        addTeardownBlock { [api] in
            api.deleteGoals(named: name, password: password)
        }

        let app = XCUIApplication.launchedClean()
        savingsSignIn(app, password: password)
        savingsOpenTab(app)
        XCTAssertTrue(app.descendants(matching: .any)["savings.summary"].waitForExistence(timeout: 15))

        // Create goal: name, icon, target (with the minimum check), frequency, plan preview.
        app.buttons["savings.createGoal"].tap()
        XCTAssertTrue(labeled(app, "Create a goal").waitForExistence(timeout: 5))
        let submit = app.buttons["savings.create.submit"]
        XCTAssertFalse(submit.isEnabled, "Create goal must be disabled before name and target")
        XCTAssertTrue(labeled(app, "Add a goal name and a target amount to continue.").exists)
        let nameField = app.textFields["Goal name"]
        nameField.tap()
        nameField.typeText(name)
        let travel = app.buttons["savings.create.icon.travel"]
        travel.tap()
        XCTAssertTrue(travel.isSelected, "Travel icon should be selected")
        XCTAssertEqual(travel.label, "Travel")

        app.buttons["savings.create.target"].tap()
        XCTAssertTrue(labeled(app, "Target amount").waitForExistence(timeout: 5))
        tapKeys(app, [".", "5"], expect: "0.50 US dollars")
        XCTAssertTrue(labeled(app, "Enter at least $1.00.").waitForExistence(timeout: 2), "below-minimum target must say so")
        XCTAssertFalse(app.buttons["savings.amount.continue"].isEnabled)
        app.attachScreenshot(named: "Create goal target below minimum", to: self)
        tapKeys(app, ["delete", "delete", "delete", "5", "0", "0"], expect: "500.00 US dollars")
        XCTAssertFalse(labeled(app, "Enter at least $1.00.").exists)
        app.attachScreenshot(named: "Create goal target amount", to: self)
        app.buttons["savings.amount.continue"].tap()

        let targetField = app.buttons["savings.create.target"]
        XCTAssertTrue(targetField.waitForExistence(timeout: 5))
        XCTAssertEqual(targetField.value as? String, "500.00 US dollars")
        labeled(app, "Monthly", type: .button).tap()
        // $500 over 6 months, progressive plan (contribution-plan.ts):
        // 2380, 4762, 7143, 9524, 11905, 14286 cents.
        let planText = app.staticTexts["savings.create.planText"]
        XCTAssertTrue(planText.waitForExistence(timeout: 5))
        XCTAssertEqual(planText.label, "Start at $23.80 this month and build up to $142.86 over 6 months.")
        app.attachScreenshot(named: "Create goal form", to: self)

        // Target date: the 1st of the month after the default (today + 6
        // months), so 7 monthly steps: 1785 … 12501 cents.
        let calendar = Calendar.current
        let deadlineMonth = try XCTUnwrap(calendar.date(byAdding: .month, value: 7, to: calendar.startOfDay(for: Date())))
        let deadlineParts = calendar.dateComponents([.year, .month], from: deadlineMonth)
        let expectedDeadline = String(format: "%04d-%02d-01", deadlineParts.year ?? 0, deadlineParts.month ?? 0)
        let nextMonth = app.buttons["Next Month"]
        XCTAssertTrue(nextMonth.waitForExistence(timeout: 5), "the date picker has no Next Month button")
        nextMonth.tap()
        let firstOfMonth = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " 1")).firstMatch
        XCTAssertTrue(firstOfMonth.waitForExistence(timeout: 5), "no day 1 in the date picker")
        firstOfMonth.tap()
        XCTAssertTrue(
            waitFor(planText, label: "Start at $17.85 this month and build up to $125.01 over 7 months."),
            "plan preview did not follow the new date: \(planText.label)"
        )
        app.swipeUp()
        app.attachScreenshot(named: "Create goal form scrolled", to: self)
        XCTAssertTrue(submit.isEnabled)
        submit.tap()

        // Lands on the new goal's detail with the toast (shown for 3 seconds
        // once the goal has loaded, so look for it first).
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Goal created.")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 30), "Goal created toast missing")
        app.attachScreenshot(named: "New goal detail with toast", to: self)
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 15), "did not land on the new goal's detail")
        let goal = try XCTUnwrap(try api.goals().first { $0.name == name }, "created goal not in GET /goals")
        XCTAssertEqual(goal.savedCents, 0)
        XCTAssertEqual(goal.targetCents, 50_000)
        XCTAssertEqual(goal.frequency, "monthly")
        XCTAssertEqual(goal.emoji.unicodeScalars.filter { $0.value != 0xFE0F }.map(\.value), [0x2708])
        XCTAssertEqual(goal.color, "jade")
        XCTAssertTrue(goal.deadline.hasPrefix(expectedDeadline), "deadline \(goal.deadline), expected \(expectedDeadline)")
        XCTAssertTrue(labeled(app, "Nothing to move yet.").exists)
        XCTAssertFalse(app.buttons["savings.detail.moveToBalance"].isEnabled)
        XCTAssertTrue(labeled(app, "Your monthly saving shows up here after your first move.").exists)
        app.attachScreenshot(named: "New goal detail", to: self)

        // Move to goal: above available can't continue; $5.00 goes through.
        let availableBeforeAt = Date()
        let availableBefore = try api.availableCents()
        app.buttons["savings.detail.moveToGoal"].tap()
        let availableLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Available $")).firstMatch
        XCTAssertTrue(availableLine.waitForExistence(timeout: 10), "available balance did not load")
        XCTAssertEqual(availableLine.label, "Available \(dollars(availableBefore))", "sheet shows the wallet's available balance")
        tapKeys(app, Array(repeating: "9", count: 7), expect: "9,999,999.00 US dollars")
        XCTAssertTrue(labeled(app, "You don't have enough available for that. Add money or choose a smaller amount.").waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["savings.amount.continue"].isEnabled, "Review must be disabled above available")
        app.attachScreenshot(named: "Move to goal above available", to: self)
        // "All" sets the available balance exactly (DESIGN.md §7.2). With the
        // "Next step" chip there are five chips, so "All" sits at the end of
        // the scrolling chip row: check it's there and carries the max.
        let allPreset = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "All, ")).firstMatch
        XCTAssertTrue(allPreset.exists, "no All preset")
        XCTAssertEqual(allPreset.label, "All, \(spoken(availableBefore))")
        tapKeys(app, Array(repeating: "delete", count: 7) + ["5"], expect: "5.00 US dollars")
        XCTAssertTrue(app.buttons["savings.amount.continue"].isEnabled)
        app.attachScreenshot(named: "Move to goal amount", to: self)
        app.buttons["savings.amount.continue"].tap()

        let reviewAmount = app.descendants(matching: .any)["savings.review.amount"]
        XCTAssertTrue(reviewAmount.waitForExistence(timeout: 5), "Review step did not open")
        XCTAssertEqual(reviewAmount.label, "5.00 US dollars")
        XCTAssertTrue(row(app, "From", "Balance").exists)
        XCTAssertTrue(row(app, "To", name).exists)
        XCTAssertTrue(row(app, "Fee", "No fee").exists)
        // "Confirm" on a device with no passcode (no device gate, DESIGN.md
        // §4.13). The iOS 26.5 simulator reports a passcode even when erased,
        // so here it's "Confirm with Face ID" and the run needs Face ID
        // enrolled plus the host helper (see the class comment).
        let confirm = app.buttons["savings.review.confirm"]
        let confirmLabel = confirm.label
        XCTAssertTrue(["Confirm", "Confirm with Face ID"].contains(confirmLabel), "confirm button says \(confirmLabel)")
        let faceIDDir = ProcessInfo.processInfo.environment["MH_SAVINGS_FACEID_DIR"] ?? ""
        if confirmLabel != "Confirm" && faceIDDir.isEmpty {
            XCTFail("this simulator asks for Face ID: enroll it, run the host helper and set TEST_RUNNER_MH_SAVINGS_FACEID_DIR (class comment)")
            return
        }
        app.attachScreenshot(named: "Move to goal review", to: self)
        let sentAt = Date()
        confirm.tap()
        if confirmLabel != "Confirm" {
            allowFaceIDIfAsked(app)
            savingsAnswerFaceID("match", dir: faceIDDir)
        }

        XCTAssertTrue(labeled(app, "Moved to \(name)").waitForExistence(timeout: 30), "move to goal receipt missing")
        XCTAssertTrue(row(app, "Status", "Done").waitForExistence(timeout: 10), "receipt never matched Activity as Done")
        XCTAssertTrue(app.buttons["View goal"].exists == false, "no View goal when started from the goal")
        app.attachScreenshot(named: "Move to goal receipt", to: self)
        labeled(app, "Done", type: .button).tap()

        let header = app.descendants(matching: .any)["savings.detail.header"]
        XCTAssertTrue(waitFor(header, valueHasPrefix: "5.00 US dollars saved of 500.00 US dollars."), "detail did not show $5.00 saved: \(header.value ?? "nil")")
        XCTAssertEqual(try api.goal(id: goal.id).savedCents, 500, "API saved amount after moving $5.00")
        try assertBalanceMoved(api: api, from: availableBefore, readAt: availableBeforeAt, by: -500, ownType: "goal_allocate")
        let allocate = try XCTUnwrap(try api.latestActivity(type: "goal_allocate", goalName: name, since: sentAt), "no goal_allocate in Activity")
        XCTAssertEqual(allocate.amountCents, -500)
        app.attachScreenshot(named: "Goal detail after move to goal", to: self)

        // Move to balance: above saved can't continue; wrong password stays
        // inline and signed in; $1.00 with the server's fee and net.
        let availableBeforeReleaseAt = Date()
        let availableBeforeRelease = try api.availableCents()
        app.buttons["savings.detail.moveToBalance"].tap()
        XCTAssertTrue(labeled(app, "In this goal $5.00").waitForExistence(timeout: 5))
        tapKeys(app, ["9"], expect: "9.00 US dollars")
        XCTAssertTrue(labeled(app, "That's more than this goal has.").waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["savings.amount.continue"].isEnabled)
        app.attachScreenshot(named: "Move to balance above saved", to: self)
        // "All" sets what's in the goal exactly.
        let allSaved = labeled(app, "All, 5.00 US dollars", type: .button)
        XCTAssertTrue(allSaved.waitForExistence(timeout: 2), "no All preset for the goal's saved amount")
        allSaved.tap()
        XCTAssertTrue(waitFor(labeled(app, "Amount"), valueHasPrefix: "5.00 US dollars", timeout: 5), "All did not set $5.00")
        XCTAssertFalse(labeled(app, "That's more than this goal has.").exists)
        XCTAssertTrue(app.buttons["savings.amount.continue"].isEnabled)
        tapKeys(app, ["delete", "delete", "delete", "delete", "1"], expect: "1.00 US dollars")
        app.attachScreenshot(named: "Move to balance amount", to: self)
        app.buttons["savings.amount.continue"].tap()

        let releaseReviewAmount = app.descendants(matching: .any)["savings.review.amount"]
        XCTAssertTrue(releaseReviewAmount.waitForExistence(timeout: 5), "Review step did not open")
        XCTAssertEqual(releaseReviewAmount.label, "1.00 US dollars")
        XCTAssertTrue(labeled(app, "Continue", type: .button).exists)
        XCTAssertTrue(row(app, "From", name).exists)
        XCTAssertTrue(row(app, "To", "Balance").exists)
        XCTAssertTrue(row(app, "Fee", "No fee").exists, "dev goals have feeBps 0")
        XCTAssertTrue(row(app, "You receive", "1.00 US dollars").exists)
        app.attachScreenshot(named: "Move to balance review", to: self)
        app.buttons["savings.review.confirm"].tap()

        XCTAssertTrue(labeled(app, "Confirm it's you").waitForExistence(timeout: 5))
        XCTAssertTrue(labeled(app, "Enter your password to continue.").waitForExistence(timeout: 5))
        let stepUpSubmit = app.buttons["savings.stepUp.submit"]
        XCTAssertFalse(stepUpSubmit.isEnabled, "Move to balance needs a password first")
        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText("QA-not-the-password")
        stepUpSubmit.tap()
        XCTAssertTrue(labeled(app, "Your password is incorrect.").waitForExistence(timeout: 10), "wrong password error missing")
        XCTAssertTrue(labeled(app, "Confirm it's you").exists, "a wrong step-up password must not leave the sheet")
        XCTAssertFalse(app.buttons["Create account"].exists, "a wrong step-up password must not sign out")
        app.attachScreenshot(named: "Move to balance wrong password", to: self)
        XCTAssertEqual(try api.goal(id: goal.id).savedCents, 500, "nothing moved on a wrong password")

        passwordField.tap()
        passwordField.typeText(password)
        let releaseSentAt = Date()
        stepUpSubmit.tap()
        XCTAssertTrue(labeled(app, "Moved to your balance").waitForExistence(timeout: 15), "move to balance receipt missing")
        let release = try XCTUnwrap(try api.latestActivity(type: "goal_release", goalName: name, since: releaseSentAt), "no goal_release in Activity")
        XCTAssertEqual(release.amountCents, 100, "net moved to the balance")
        XCTAssertTrue(row(app, "Amount", "1.00 US dollars").exists)
        XCTAssertTrue(row(app, "Fee", "No fee").exists)
        XCTAssertTrue(row(app, "You received", "1.00 US dollars").exists)
        XCTAssertTrue(row(app, "Status", "Done").waitForExistence(timeout: 10), "release receipt never matched Activity as Done")
        app.attachScreenshot(named: "Move to balance receipt", to: self)
        labeled(app, "Done", type: .button).tap()
        XCTAssertTrue(waitFor(header, valueHasPrefix: "4.00 US dollars saved of 500.00 US dollars."), "detail did not show $4.00 saved: \(header.value ?? "nil")")
        XCTAssertEqual(try api.goal(id: goal.id).savedCents, 400)
        try assertBalanceMoved(api: api, from: availableBeforeRelease, readAt: availableBeforeReleaseAt, by: 100, ownType: "goal_release")
        app.swipeUp()
        app.attachScreenshot(named: "Goal detail after moves (history)", to: self)
        app.swipeDown()

        // Delete the QA goal: step-up inline, receipt (money moved back).
        let availableBeforeDeleteAt = Date()
        let availableBeforeDelete = try api.availableCents()
        app.buttons["savings.detail.more"].tap()
        labeled(app, "Delete goal", type: .button).tap()
        let body = app.staticTexts["savings.delete.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.label, "This moves the full $4.00 back to your balance and closes the goal.")
        let deleteSubmit = app.buttons["savings.delete.submit"]
        XCTAssertTrue(labeled(app, "Enter your password to continue.").waitForExistence(timeout: 5))
        XCTAssertFalse(deleteSubmit.isEnabled)
        app.attachScreenshot(named: "Delete goal", to: self)
        let deletePassword = app.secureTextFields["Password"]
        deletePassword.tap()
        deletePassword.typeText("QA-not-the-password")
        XCTAssertTrue(deleteSubmit.isEnabled)
        deleteSubmit.tap()
        XCTAssertTrue(labeled(app, "Your password is incorrect.").waitForExistence(timeout: 10), "wrong password error missing on delete")
        XCTAssertTrue(body.exists, "a wrong step-up password must not leave the delete sheet")
        XCTAssertFalse(app.buttons["Create account"].exists, "a wrong step-up password must not sign out")
        XCTAssertNotNil(try api.goals().first { $0.id == goal.id }, "goal deleted on a wrong password")
        app.attachScreenshot(named: "Delete goal wrong password", to: self)
        deletePassword.tap()
        deletePassword.typeText(password)
        let deleteSentAt = Date()
        deleteSubmit.tap()
        XCTAssertTrue(labeled(app, "Goal deleted").waitForExistence(timeout: 15), "delete receipt missing")
        XCTAssertTrue(row(app, "Amount", "4.00 US dollars").exists)
        XCTAssertTrue(row(app, "You received", "4.00 US dollars").exists)
        XCTAssertTrue(row(app, "Status", "Done").waitForExistence(timeout: 10), "delete receipt never matched Activity as Done")
        app.attachScreenshot(named: "Delete goal receipt", to: self)
        labeled(app, "Done", type: .button).tap()

        XCTAssertTrue(app.descendants(matching: .any)["savings.summary"].waitForExistence(timeout: 15), "did not return to the Savings list")
        XCTAssertTrue(waitForDisappearance(app.buttons["savings.goalCard.\(goal.id)"]), "deleted goal still listed")
        XCTAssertNil(try api.goals().first { $0.name == name }, "deleted goal still in GET /goals")
        let returned = try XCTUnwrap(try api.latestActivity(type: "goal_release", goalName: name, since: deleteSentAt), "no goal_release for the delete")
        XCTAssertEqual(returned.amountCents, 400)
        try assertBalanceMoved(api: api, from: availableBeforeDelete, readAt: availableBeforeDeleteAt, by: 400, ownType: "goal_release")
        app.attachScreenshot(named: "Savings list after delete", to: self)
    }

    // MARK: Delete an empty goal (no receipt, "Goal deleted." toast)

    @MainActor
    func testDeleteEmptyGoalShowsToastOnSavings() throws {
        let password = try UITestAccount.demoPassword()
        let api = try SavingsTestAPI.signIn(password: password)
        let name = "QA Savings empty \(Int(Date().timeIntervalSince1970) % 1_000_000)"
        // Created through the API (the create form is covered above); no
        // money ever moves into it.
        let id = try api.createEmptyGoal(named: name)
        addTeardownBlock { [api] in
            api.deleteGoals(named: name, password: password)
        }

        let app = XCUIApplication.launchedClean()
        savingsSignIn(app, password: password)
        savingsOpenTab(app)
        let card = app.buttons["savings.goalCard.\(id)"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the new empty goal is not listed")
        if !card.isHittable { app.swipeUp() }
        card.tap()
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 15), "goal detail did not open")

        app.buttons["savings.detail.more"].tap()
        labeled(app, "Delete goal", type: .button).tap()
        let body = app.staticTexts["savings.delete.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 5))
        XCTAssertEqual(body.label, "This permanently closes the goal.")
        XCTAssertTrue(labeled(app, "Enter your password to continue.").waitForExistence(timeout: 5))
        let submit = app.buttons["savings.delete.submit"]
        XCTAssertFalse(submit.isEnabled, "Delete goal needs a password first")
        app.attachScreenshot(named: "Delete empty goal", to: self)
        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(password)
        submit.tap()

        // No receipt when nothing moved: back on Savings with the toast.
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Goal deleted.")).firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 20), "Goal deleted toast missing")
        XCTAssertTrue(app.navigationBars["Savings"].exists, "did not return to Savings")
        XCTAssertFalse(labeled(app, "Goal deleted").exists, "no receipt when nothing moved")
        app.attachScreenshot(named: "Savings list with Goal deleted toast", to: self)
        XCTAssertTrue(waitForDisappearance(card), "deleted goal still listed")
        XCTAssertNil(try api.goals().first { $0.id == id }, "deleted goal still in GET /goals")
    }

    // MARK: Move to goal from Home ("Choose a goal")

    @MainActor
    func testMoveToGoalFromHomeStartsAtChooseAGoal() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        savingsSignIn(app, password: password)
        let homeAction = labeled(app, "Move to goal", type: .button)
        guard homeAction.waitForExistence(timeout: 10) else {
            throw XCTSkip("Home has no \"Move to goal\" quick action yet (FeatureHome)")
        }
        homeAction.tap()
        XCTAssertTrue(labeled(app, "Choose a goal").waitForExistence(timeout: 10))
        let emergency = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "savings.choose.goal.", "Emergency fund"))
            .firstMatch
        XCTAssertTrue(emergency.waitForExistence(timeout: 10), "seeded goal missing from Choose a goal")
        app.attachScreenshot(named: "Move to goal choose", to: self)
        emergency.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Available $")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(labeled(app, "Emergency fund").exists)
        app.attachScreenshot(named: "Move to goal amount from Home", to: self)
        // Leave without moving money: back, then close.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(labeled(app, "Choose a goal").waitForExistence(timeout: 5))
        app.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(waitForDisappearance(labeled(app, "Choose a goal")))
    }

    // MARK: Empty states (a friend account with no goals, read only)

    @MainActor
    func testEmptyStatesWhenTheAccountHasNoGoals() throws {
        let password = try UITestAccount.demoPassword()
        // Any seeded friend with no goals right now. Nothing is created or
        // moved on this account: the test only reads and closes sheets.
        var chosen: String?
        for friend in ["abena", "yaw", "esi", "kofi"] {
            let email = "\(friend)@moolahub.test"
            guard let api = try? SavingsTestAPI.signIn(email: email, password: password) else { continue }
            if (try? api.goals())?.isEmpty == true {
                chosen = email
                break
            }
        }
        guard let email = chosen else { throw XCTSkip("every friend account has goals right now") }

        let app = XCUIApplication.launchedClean()
        savingsSignIn(app, email: email, password: password)
        savingsOpenTab(app)
        XCTAssertTrue(labeled(app, "No goals yet").waitForExistence(timeout: 15), "Savings empty state missing")
        XCTAssertTrue(labeled(app, "Set a target and a date. We'll track your progress.").exists)
        XCTAssertFalse(app.descendants(matching: .any)["savings.summary"].exists, "summary must be hidden with no goals")
        XCTAssertFalse(labeled(app, "Each goal is a pot inside your balance, not a separate account.").exists)
        app.attachScreenshot(named: "Savings list empty", to: self)

        // The empty state's "Create goal" opens Create a goal; close it unchanged.
        emptyStateCreateGoal(app).tap()
        XCTAssertTrue(labeled(app, "Create a goal").waitForExistence(timeout: 5), "Create goal sheet did not open")
        app.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(waitForDisappearance(labeled(app, "Create a goal")), "Create goal sheet did not close")

        // Home "Move to goal" with no goals: the empty Choose a goal step,
        // whose "Create goal" swaps this sheet for Create a goal.
        app.tabBars.buttons["Home"].tap()
        let homeAction = labeled(app, "Move to goal", type: .button)
        guard homeAction.waitForExistence(timeout: 10) else {
            throw XCTSkip("Home has no \"Move to goal\" quick action yet (FeatureHome)")
        }
        homeAction.tap()
        XCTAssertTrue(labeled(app, "Choose a goal").waitForExistence(timeout: 10))
        XCTAssertTrue(labeled(app, "No goals yet").waitForExistence(timeout: 10), "Choose a goal empty state missing")
        XCTAssertTrue(labeled(app, "Create a goal first, then move money into it.").exists)
        app.attachScreenshot(named: "Move to goal choose (no goals)", to: self)
        emptyStateCreateGoal(app).tap()
        XCTAssertTrue(labeled(app, "Create a goal").waitForExistence(timeout: 10), "Create goal did not replace Move to goal")
        XCTAssertFalse(labeled(app, "Choose a goal").exists)
        app.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(waitForDisappearance(labeled(app, "Create a goal")))
        XCTAssertTrue(try SavingsTestAPI.signIn(email: email, password: password).goals().isEmpty, "the test must not create goals")
    }

    // MARK: Not found, error and loading states (DESIGN.md v2 B3.3, B3.5, B3.6, B3.13 to B3.15, B3.18, B3.19)

    /// Reaches the states the live backend never shows on demand. Not found
    /// is real: a QA goal is deleted through the API while its tile is on
    /// screen. The error and loading states use the Debug-only launch
    /// arguments of FeatureSavings (`SavingsDebugReads`): Savings reads fail
    /// before they leave, or wait 20 seconds. No money moves.
    @MainActor
    func testNotFoundErrorAndLoadingStates() throws {
        let password = try UITestAccount.demoPassword()
        let api = try SavingsTestAPI.signIn(password: password)
        let goneName = "QA Savings gone \(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let goneID = try api.createEmptyGoal(named: goneName)
        addTeardownBlock { [api] in
            api.deleteGoals(named: goneName, password: password)
        }
        let goals = try api.goals()
        let emergency = try XCTUnwrap(goals.first { $0.name == "Emergency fund" }, "seeded Emergency fund missing")
        let laptop = try XCTUnwrap(goals.first { $0.name == "New laptop" }, "seeded New laptop missing")

        // 1. Cache the list and Emergency fund, then delete the QA goal on
        // the server while its tile is still listed: opening it says it's gone.
        let app = XCUIApplication.launchedClean()
        savingsSignInRetryingPassword(app, password: password)
        savingsOpenTab(app)
        XCTAssertTrue(app.descendants(matching: .any)["savings.summary"].waitForExistence(timeout: 15))
        app.buttons["savings.goalCard.\(emergency.id)"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["savings.detail.header"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let goneCard = app.buttons["savings.goalCard.\(goneID)"]
        XCTAssertTrue(goneCard.waitForExistence(timeout: 15), "the QA goal is not listed")
        api.deleteGoals(named: goneName, password: password)
        XCTAssertNil(try api.goals().first { $0.id == goneID }, "the QA goal was not deleted on the server")
        if !goneCard.isHittable { app.swipeUp() }
        goneCard.tap()
        XCTAssertTrue(labeled(app, "We couldn't find that goal.").waitForExistence(timeout: 20), "not-found state missing")
        XCTAssertFalse(app.buttons["savings.detail.more"].exists, "no More menu without a goal")
        app.attachScreenshot(named: "Goal detail not found", to: self)
        labeled(app, "Back to savings", type: .button).tap()
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForDisappearance(goneCard, timeout: 20), "the gone goal is still listed after Back to savings")
        app.terminate()

        // 2. Reads fail, with a cache: the list and Emergency fund keep their
        // snapshot under the banner and the freshness line; New laptop was
        // never loaded; the money sheets can't load their maximum or goals.
        let offline = XCUIApplication()
        offline.launchArguments = ["-mh-savings-offline-reads"]
        offline.launch()
        XCTAssertTrue(offline.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored")
        savingsOpenTab(offline)
        let updated = offline.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Updated ")).firstMatch
        XCTAssertTrue(updated.waitForExistence(timeout: 15), "freshness line missing over cached goals")
        XCTAssertTrue(offline.descendants(matching: .any)["savings.summary"].exists, "cached goals must stay on screen")
        XCTAssertTrue(labeled(offline, "Try again", type: .button).exists, "refresh-failed banner missing")
        offline.attachScreenshot(named: "Savings list refresh failed", to: self)

        offline.buttons["savings.goalCard.\(emergency.id)"].tap()
        XCTAssertTrue(offline.descendants(matching: .any)["savings.detail.header"].waitForExistence(timeout: 15))
        XCTAssertTrue(updated.waitForExistence(timeout: 10), "freshness line missing on the cached goal")
        offline.attachScreenshot(named: "Goal detail refresh failed", to: self)
        offline.buttons["savings.detail.moveToGoal"].tap()
        XCTAssertTrue(labeled(offline, "We couldn't load your balance").waitForExistence(timeout: 15), "balance error missing")
        XCTAssertFalse(offline.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Available $")).firstMatch.exists, "no maximum without a balance")
        offline.attachScreenshot(named: "Move to goal balance error", to: self)
        offline.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(waitForDisappearance(labeled(offline, "We couldn't load your balance")))
        offline.navigationBars.buttons.element(boundBy: 0).tap()

        offline.buttons["savings.goalCard.\(laptop.id)"].tap()
        XCTAssertTrue(labeled(offline, "We couldn't load this goal").waitForExistence(timeout: 15), "never-loaded goal error missing")
        XCTAssertFalse(offline.descendants(matching: .any)["savings.detail.header"].exists)
        offline.attachScreenshot(named: "Goal detail error", to: self)
        offline.navigationBars.buttons.element(boundBy: 0).tap()

        offline.tabBars.buttons["Home"].tap()
        let homeAction = labeled(offline, "Move to goal", type: .button)
        if homeAction.waitForExistence(timeout: 15) {
            homeAction.tap()
            XCTAssertTrue(labeled(offline, "Choose a goal").waitForExistence(timeout: 10))
            XCTAssertTrue(labeled(offline, "We couldn't load your goals").waitForExistence(timeout: 15), "Choose a goal error missing")
            offline.attachScreenshot(named: "Move to goal choose error", to: self)
            offline.buttons["savings.sheet.close"].tap()
            XCTAssertTrue(waitForDisappearance(labeled(offline, "Choose a goal")))
        }
        offline.terminate()

        // 3. Reads fail with nothing cached (a fresh sign-in): never loaded.
        let fresh = XCUIApplication()
        fresh.launchArguments = ["-mh-reset-state", "-mh-savings-offline-reads"]
        fresh.launch()
        savingsSignInRetryingPassword(fresh, password: password)
        savingsOpenTab(fresh)
        XCTAssertTrue(labeled(fresh, "We couldn't load your goals").waitForExistence(timeout: 15), "Savings error state missing")
        XCTAssertFalse(fresh.descendants(matching: .any)["savings.summary"].exists)
        XCTAssertFalse(fresh.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "$")).firstMatch.exists, "no amount on an error state")
        fresh.attachScreenshot(named: "Savings list error", to: self)
        fresh.terminate()

        // 4. Every read waits 20 seconds, nothing cached: the skeletons.
        let slow = XCUIApplication()
        slow.launchArguments = ["-mh-savings-slow-reads"]
        slow.launch()
        XCTAssertTrue(slow.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored")
        savingsOpenTab(slow)
        XCTAssertTrue(labeled(slow, "Loading your goals\u{2026}").waitForExistence(timeout: 10), "Savings skeleton missing")
        slow.attachScreenshot(named: "Savings list loading", to: self)
        XCTAssertTrue(slow.descendants(matching: .any)["savings.summary"].waitForExistence(timeout: 60))
        slow.buttons["savings.goalCard.\(laptop.id)"].tap()
        XCTAssertTrue(labeled(slow, "Loading goal\u{2026}").waitForExistence(timeout: 10), "Goal detail skeleton missing")
        slow.attachScreenshot(named: "Goal detail loading", to: self)
        XCTAssertTrue(slow.descendants(matching: .any)["savings.detail.header"].waitForExistence(timeout: 60))
        slow.buttons["savings.detail.moveToGoal"].tap()
        XCTAssertTrue(slow.staticTexts["Loading your balance\u{2026}"].waitForExistence(timeout: 10), "balance loading line missing")
        XCTAssertFalse(slow.buttons["savings.amount.continue"].isEnabled)
        slow.attachScreenshot(named: "Move to goal amount loading balance", to: self)
        slow.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(waitForDisappearance(slow.staticTexts["Loading your balance\u{2026}"]))
        slow.tabBars.buttons["Home"].tap()
        let slowHomeAction = labeled(slow, "Move to goal", type: .button)
        if slowHomeAction.waitForExistence(timeout: 15) {
            slowHomeAction.tap()
            XCTAssertTrue(labeled(slow, "Loading your goals\u{2026}").waitForExistence(timeout: 10), "Choose a goal skeleton missing")
            slow.attachScreenshot(named: "Move to goal choose loading", to: self)
            slow.buttons["savings.sheet.close"].tap()
            XCTAssertTrue(waitForDisappearance(labeled(slow, "Choose a goal")))
        }
        slow.terminate()
    }

    // MARK: Create form top, "Discard this?" and toast placement (DESIGN.md v2 B3.7, B3.8, B3.10, B3.12)

    /// What the lifecycle test scrolls past or can't hold still on a busy
    /// Mac: the top of the Create goal form (name and icon picker), the
    /// "Discard this?" dialog on Close, and both Savings toasts, kept on
    /// screen by the Debug-only `-mh-hold-toasts` (FeatureSavings
    /// `SavingsDebugToasts`) so each is shot and its place checked: centred,
    /// 8 pt below the status bar. Creates one empty QA goal through the form
    /// and deletes it through the app; no money moves.
    @MainActor
    func testCreateFormDiscardDialogAndToastPlacement() throws {
        let password = try UITestAccount.demoPassword()
        let api = try SavingsTestAPI.signIn(password: password)
        let name = "QA Savings toast \(Int(Date().timeIntervalSince1970) % 1_000_000)"
        addTeardownBlock { [api] in
            api.deleteGoals(named: name, password: password)
        }

        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state", "-mh-hold-toasts"]
        app.launch()
        savingsSignInRetryingPassword(app, password: password)
        savingsOpenTab(app)
        XCTAssertTrue(app.descendants(matching: .any)["savings.summary"].waitForExistence(timeout: 30))

        // The form's first screen, empty and then filled; Close asks first,
        // and "Discard" closes it without creating anything.
        app.buttons["savings.createGoal"].tap()
        XCTAssertTrue(labeled(app, "Create a goal").waitForExistence(timeout: 10), "Create goal sheet did not open")
        XCTAssertTrue(app.buttons["savings.create.icon.goal"].isSelected, "the default icon is Goal")
        XCTAssertFalse(app.buttons["savings.create.submit"].isEnabled)
        app.attachScreenshot(named: "Create goal form top", to: self)
        let nameField = app.textFields["Goal name"]
        nameField.tap()
        nameField.typeText(name)
        let home = app.buttons["savings.create.icon.home"]
        home.tap()
        XCTAssertTrue(home.isSelected, "Home icon should be selected")
        XCTAssertFalse(app.buttons["savings.create.icon.goal"].isSelected, "one icon at a time")
        app.attachScreenshot(named: "Create goal form top filled", to: self)
        app.buttons["savings.sheet.close"].tap()
        let discard = hittableButton(app, "Discard")
        XCTAssertTrue(discard.exists, "Close did not ask \"Discard this?\" after a name was entered")
        app.attachScreenshot(named: "Discard this dialog", to: self)
        discard.tap()
        XCTAssertTrue(waitForDisappearance(labeled(app, "Create a goal"), timeout: 15), "Discard did not close the sheet")
        XCTAssertNil(try api.goals().first { $0.name == name }, "Discard must not create a goal")

        // Create it for real (empty): "Goal created." over its detail.
        app.buttons["savings.createGoal"].tap()
        XCTAssertTrue(labeled(app, "Create a goal").waitForExistence(timeout: 10))
        let nameAgain = app.textFields["Goal name"]
        nameAgain.tap()
        nameAgain.typeText(name)
        app.buttons["savings.create.icon.home"].tap()
        app.buttons["savings.create.target"].tap()
        tapKeys(app, ["1", "0", "0"], expect: "100.00 US dollars")
        app.buttons["savings.amount.continue"].tap()
        XCTAssertTrue(waitFor(app.buttons["savings.create.target"], valueHasPrefix: "100.00 US dollars", timeout: 15))
        app.buttons["savings.create.submit"].tap()
        let created = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Goal created.")).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 60), "Goal created toast missing")
        XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 15), "did not land on the new goal's detail")
        assertToastUnderTheStatusBar(app, created)
        app.attachScreenshot(named: "Goal created toast", to: self)
        let goal = try XCTUnwrap(try api.goals().first { $0.name == name }, "created goal not in GET /goals")
        XCTAssertEqual(goal.savedCents, 0)
        XCTAssertEqual(goal.targetCents, 10_000)

        // Delete it (nothing in it, so no receipt): "Goal deleted." over Savings.
        app.buttons["savings.detail.more"].tap()
        labeled(app, "Delete goal", type: .button).tap()
        let body = app.staticTexts["savings.delete.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertEqual(body.label, "This permanently closes the goal.")
        let deletePassword = app.secureTextFields["Password"]
        let submit = app.buttons["savings.delete.submit"]
        let refused = labeled(app, "Your password is incorrect.")
        let deleted = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Goal deleted.")).firstMatch
        for attempt in 1...2 {
            deletePassword.tap()
            deletePassword.typeText(password)
            submit.tap()
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline && !deleted.exists && !refused.exists {
                settle(seconds: 0.5)
            }
            if deleted.exists || !refused.exists { break }
            XCTContext.runActivity(named: "Delete refused the typed password (attempt \(attempt)): typing it again") { _ in }
        }
        XCTAssertTrue(deleted.waitForExistence(timeout: 30), "Goal deleted toast missing")
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 10), "did not return to Savings")
        XCTAssertFalse(labeled(app, "Goal deleted").exists, "no receipt when nothing moved")
        assertToastUnderTheStatusBar(app, deleted)
        app.attachScreenshot(named: "Savings list with Goal deleted toast (held)", to: self)
        XCTAssertNil(try api.goals().first { $0.name == name }, "deleted goal still in GET /goals")
    }

    // MARK: Helpers

    /// The EmptyState's "Create goal" button (not the toolbar's `plus`, which
    /// has the same label).
    @MainActor
    private func emptyStateCreateGoal(_ app: XCUIApplication) -> XCUIElement {
        app.buttons
            .matching(NSPredicate(format: "label == %@ AND identifier != %@", "Create goal", "savings.createGoal"))
            .firstMatch
    }

    /// Signs in through the real Sign in screen (like `app.signIn`, with
    /// timeouts for a Mac several engineers build on at once, and a second
    /// tap when the first one lands while Welcome is still settling), then
    /// answers iOS's "Save Password?" ("Not Now") and the one-time app lock
    /// offer ("Not now", only when Face ID is enrolled) until neither shows.
    @MainActor
    private func savingsSignIn(_ app: XCUIApplication, email: String = UITestAccount.demoEmail, password: String, file: StaticString = #filePath, line: UInt = #line) {
        let welcomeSignIn = app.buttons["Sign in"]
        XCTAssertTrue(welcomeSignIn.waitForExistence(timeout: 30), "Welcome did not appear", file: file, line: line)
        let emailField = app.textFields["Email"]
        var taps = 0
        while !emailField.exists && taps < 3 {
            if welcomeSignIn.exists && welcomeSignIn.isHittable {
                welcomeSignIn.tap()
                taps += 1
            }
            _ = emailField.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(emailField.exists, "Sign in screen did not appear", file: file, line: line)
        emailField.tap()
        emailField.typeText(email)
        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(password)
        let submit = app.buttons["auth.signIn.submit"]
        if submit.exists {
            submit.tap()
        } else {
            app.buttons.matching(identifier: "Sign in").allElementsBoundByIndex.last?.tap()
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Tab bar did not appear after sign in", file: file, line: line)

        // Either can arrive seconds after the tabs on a busy Mac, and "Save
        // Password?" can cover the offer: keep answering until neither is on
        // screen and nothing new has shown for 6 seconds.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let savePassword = [app.buttons["Not Now"], springboard.buttons["Not Now"]]
        let lockOffer = app.buttons["Not now"]
        let deadline = Date().addingTimeInterval(40)
        var quietSince = Date()
        while Date() < deadline {
            if let button = savePassword.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
                quietSince = Date()
            } else if lockOffer.exists && lockOffer.isHittable {
                lockOffer.tap()
                quietSince = Date()
            } else if lockOffer.exists || savePassword.contains(where: \.exists) {
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) > 6 {
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertFalse(lockOffer.exists, "app lock offer still showing", file: file, line: line)
        XCTAssertFalse(savePassword.contains(where: \.exists), "Save Password still showing", file: file, line: line)
    }

    /// Sign in for the tests added for v2 (the five v1 tests keep
    /// `savingsSignIn`): the same steps, but when the server refuses the
    /// password ("Invalid email or password.", `auth.signIn.error`) it types
    /// the password once more. Two full runs on a busy Mac lost a character
    /// typing into the secure field; the server still decides every attempt.
    @MainActor
    private func savingsSignInRetryingPassword(_ app: XCUIApplication, password: String, file: StaticString = #filePath, line: UInt = #line) {
        let welcomeSignIn = app.buttons["Sign in"]
        XCTAssertTrue(welcomeSignIn.waitForExistence(timeout: 30), "Welcome did not appear", file: file, line: line)
        let emailField = app.textFields["Email"]
        var taps = 0
        while !emailField.exists && taps < 3 {
            if welcomeSignIn.exists && welcomeSignIn.isHittable {
                welcomeSignIn.tap()
                taps += 1
            }
            _ = emailField.waitForExistence(timeout: 10)
        }
        XCTAssertTrue(emailField.exists, "Sign in screen did not appear", file: file, line: line)
        emailField.tap()
        emailField.typeText(UITestAccount.demoEmail)
        let passwordField = app.secureTextFields["Password"]
        let refused = app.descendants(matching: .any)["auth.signIn.error"]
        let tabBar = app.tabBars.firstMatch
        for attempt in 1...2 {
            passwordField.tap()
            if attempt > 1 {
                passwordField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
            }
            passwordField.typeText(password)
            let submit = app.buttons["auth.signIn.submit"]
            if submit.exists {
                submit.tap()
            } else {
                app.buttons.matching(identifier: "Sign in").allElementsBoundByIndex.last?.tap()
            }
            let deadline = Date().addingTimeInterval(40)
            while Date() < deadline && !tabBar.exists && !refused.exists {
                settle(seconds: 0.5)
            }
            if tabBar.exists || !refused.exists { break }
            XCTContext.runActivity(named: "Sign in refused (attempt \(attempt)): typing the password again") { _ in }
        }
        XCTAssertTrue(tabBar.waitForExistence(timeout: 30), "Tab bar did not appear after sign in", file: file, line: line)
        app.dismissSignInPrompts(file: file, line: line)
    }

    /// The first hittable button labelled `label` (a system dialog's button
    /// can sit in a sheet, an alert or an iOS 26 popover), waiting up to 10 s.
    @MainActor
    private func hittableButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(format: "label == %@", label))
        let deadline = Date().addingTimeInterval(10)
        repeat {
            if let button = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                return button
            }
            settle(seconds: 0.3)
        } while Date() < deadline
        return query.firstMatch
    }

    /// A Savings toast sits centred, 8 pt below the status bar (B3.7, B3.12):
    /// y 70 on this 402 × 874 pt simulator, whose top safe area is 62.
    @MainActor
    private func assertToastUnderTheStatusBar(_ app: XCUIApplication, _ toast: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let frame = toast.frame
        let window = app.windows.firstMatch.frame
        XCTAssertEqual(window.width, 402, accuracy: 0.5, "the placement check assumes iPhone 17 Pro (402 pt wide)", file: file, line: line)
        XCTAssertEqual(frame.minY, 70, accuracy: 1.5, "toast top at y \(frame.minY), expected 70", file: file, line: line)
        XCTAssertEqual(frame.midX, window.midX, accuracy: 1, "toast is not centred: \(frame)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.height, 44, "toast shorter than 44 pt: \(frame)", file: file, line: line)
    }

    /// Answers the Face ID prompt through the host helper (see the class
    /// comment): waits for the prompt to come up, asks for one simulated
    /// `kind` face ("match" / "nomatch") and waits until the host posted it.
    /// One face per prompt: a stray extra match can leave the simulator on its
    /// Lock Screen in front of the app.
    @MainActor
    private func savingsAnswerFaceID(_ kind: String, dir: String, file: StaticString = #filePath, line: UInt = #line) {
        settle(seconds: 2.5)
        let request = URL(fileURLWithPath: dir).appendingPathComponent("request")
        do {
            try Data(kind.utf8).write(to: request)
        } catch {
            XCTFail("could not write the Face ID request to \(dir): \(error)", file: file, line: line)
            return
        }
        let deadline = Date().addingTimeInterval(20)
        while FileManager.default.fileExists(atPath: request.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "the host helper did not answer the Face ID request", file: file, line: line)
    }

    /// The one-time "Allow MoolaHub to use Face ID?" alert (only on a
    /// simulator with Face ID enrolled, the first time the app asks). Taps
    /// "OK" / "Allow" if it shows within a few seconds; otherwise does nothing.
    @MainActor
    private func allowFaceIDIfAsked(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(4)
        repeat {
            for host in [springboard, app] {
                let alert = host.alerts.firstMatch
                guard alert.exists else { continue }
                for title in ["OK", "Allow"] where alert.buttons[title].exists {
                    alert.buttons[title].tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
    }

    @MainActor
    private func savingsOpenTab(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let tab = app.tabBars.buttons["Savings"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Savings tab missing", file: file, line: line)
        tab.tap()
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 10), "Savings tab did not open", file: file, line: line)
    }

    /// First element whose accessibility label is exactly `label`.
    @MainActor
    private func labeled(_ app: XCUIApplication, _ label: String, type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A review or receipt row ("Fee, No fee"): starts with its label and
    /// contains its value.
    @MainActor
    private func row(_ app: XCUIApplication, _ title: String, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", title, value))
            .firstMatch
    }

    /// Taps keypad keys ("1"…"9", "0", "decimal point" as ".", "delete"), one
    /// at a time: the validation line under the amount appears and disappears
    /// as the amount changes and moves the keypad, so each tap waits for the
    /// layout to settle. Then checks what the amount display says.
    @MainActor
    private func tapKeys(_ app: XCUIApplication, _ keys: [String], expect: String, file: StaticString = #filePath, line: UInt = #line) {
        for key in keys {
            let name = key == "." ? "decimal point" : key
            let button = labeled(app, name, type: .button)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "keypad key \(name) missing", file: file, line: line)
            button.tap()
            settle(seconds: 0.5)
        }
        let display = labeled(app, "Amount")
        XCTAssertTrue(waitFor(display, valueHasPrefix: expect, timeout: 5), "amount shows \(display.value ?? "nil"), expected \(expect)", file: file, line: line)
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, valueHasPrefix prefix: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, let value = element.value as? String, value.hasPrefix(prefix) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return false
    }

    /// Lets the simulator finish an animation or an answer from the host.
    @MainActor
    private func settle(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Waits until the screen's top-left corner (the canvas behind the status
    /// bar, never a card) is dark (canvas `#0C1512`-ish) or light (mist
    /// `#F3F6F4`-ish), then lets the change settle for a second.
    @MainActor
    private func waitForScreen(_ app: XCUIApplication, dark: Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let brightness = cornerBrightness(app), dark ? brightness < 80 : brightness > 180 {
                settle(seconds: 1)
                return true
            }
            settle(seconds: 0.5)
        } while Date() < deadline
        return false
    }

    /// Mean of R, G and B (0…255) of the screenshot pixel 8 px in from the
    /// top-left corner.
    @MainActor
    private func cornerBrightness(_ app: XCUIApplication) -> Int? {
        guard let image = app.screenshot().image.cgImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = pixel.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            // CoreGraphics counts y from the bottom: shift the image so its
            // pixel (8, 8) from the top-left lands on the 1 × 1 context.
            context.draw(image, in: CGRect(x: -8, y: -(image.height - 9), width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        return (Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / 3
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.label == label { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while element.exists && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return !element.exists
    }

    /// Available balance moved by exactly `delta` because of this move.
    /// Other engineers use the demo account at the same time, so when the
    /// balance moved by something else, every other Activity item since the
    /// "before" read must account for the difference exactly (and our own
    /// item must be there with exactly `delta`). Anything else fails.
    @MainActor
    private func assertBalanceMoved(api: SavingsTestAPI, from before: Int, readAt: Date, by delta: Int, ownType: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try api.availableCents()
        if after - before == delta { return }
        var items = try api.activity(since: readAt.addingTimeInterval(-1))
        guard let own = items.firstIndex(where: { $0.type == ownType && $0.amountCents == delta }) else {
            XCTFail("available moved by \(after - before) cents, expected \(delta), and no \(ownType) of \(delta) in Activity", file: file, line: line)
            return
        }
        items.remove(at: own)
        let others = items.filter { $0.type != "fee" }
        let othersTotal = others.reduce(0) { $0 + $1.amountCents }
        XCTAssertEqual(
            after - before, delta + othersTotal,
            "available moved by \(after - before) cents; expected \(delta) plus other activity \(others.map { "\($0.type) \($0.amountCents)" })",
            file: file, line: line
        )
        XCTContext.runActivity(named: "Balance also moved by other activity on the shared demo account: \(others.map { "\($0.type) \($0.amountCents)" })") { _ in }
    }

    private func spoken(_ cents: Int) -> String {
        let style = Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US"))
            .precision(.fractionLength(2))
            .presentation(.fullName)
        return (Decimal(cents) / 100).formatted(style)
    }

    private func dollars(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(
            Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US")).precision(.fractionLength(2))
        )
    }

    private func percent(_ saved: Int, _ target: Int) -> Int {
        guard target > 0 else { return saved > 0 ? 100 : 0 }
        return min(100, max(0, saved * 100 / target))
    }
}

// MARK: - A tiny client for the dev backend (test-only cross-checks)

private struct SavingsTestGoal {
    let id: String
    let name: String
    let emoji: String
    let color: String
    let frequency: String
    let deadline: String
    let savedCents: Int
    let targetCents: Int
}

private struct SavingsTestActivity {
    let type: String
    let description: String
    let amountCents: Int
    let createdAt: Date
}

/// Signs in as the demo user with `X-Client: ios` and reads goals, wallet and
/// activity. The token stays in memory and is never printed.
private final class SavingsTestAPI: Sendable {
    private static let base = URL(string: "http://localhost:8787/api")!
    private let token: String

    private init(token: String) {
        self.token = token
    }

    static func signIn(email: String = UITestAccount.demoEmail, password: String) throws -> SavingsTestAPI {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (status, json) = try request("POST", "/auth/login", body: body, token: nil)
        guard status == 200, let token = (json as? [String: Any])?["sessionToken"] as? String else {
            throw XCTSkip("could not sign in to the dev backend for API checks (HTTP \(status))")
        }
        return SavingsTestAPI(token: token)
    }

    func goals() throws -> [SavingsTestGoal] {
        let (status, json) = try Self.request("GET", "/goals", body: nil, token: token)
        guard status == 200, let list = json as? [[String: Any]] else { throw APIFailure(path: "/goals", status: status) }
        return list.compactMap(Self.goal(from:))
    }

    func goal(id: String) throws -> SavingsTestGoal {
        let (status, json) = try Self.request("GET", "/goals/\(id)", body: nil, token: token)
        guard status == 200, let object = json as? [String: Any], let goal = Self.goal(from: object) else {
            throw APIFailure(path: "/goals/{id}", status: status)
        }
        return goal
    }

    func availableCents() throws -> Int {
        let (status, json) = try Self.request("GET", "/wallet", body: nil, token: token)
        guard status == 200, let cents = (json as? [String: Any])?["availableCents"] as? Int else {
            throw APIFailure(path: "/wallet", status: status)
        }
        return cents
    }

    func activity(since: Date) throws -> [SavingsTestActivity] {
        let (status, json) = try Self.request("GET", "/activity?limit=50", body: nil, token: token)
        guard status == 200, let list = json as? [[String: Any]] else { throw APIFailure(path: "/activity", status: status) }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return list.compactMap { item in
            guard let type = item["type"] as? String, let amount = item["amountCents"] as? Int,
                  let created = (item["createdAt"] as? String).flatMap(parser.date(from:)), created >= since
            else { return nil }
            return SavingsTestActivity(type: type, description: item["description"] as? String ?? "", amountCents: amount, createdAt: created)
        }
    }

    /// The newest `type` item for this goal ("Moved to …" / "Moved from …").
    func latestActivity(type: String, goalName: String, since: Date) throws -> SavingsTestActivity? {
        try activity(since: since.addingTimeInterval(-5))
            .filter { $0.type == type && $0.description.hasSuffix(goalName) }
            .max { $0.createdAt < $1.createdAt }
    }

    /// `POST /goals` for a QA goal with no money in it ($100 by three months
    /// from now, weekly). Returns its id.
    func createEmptyGoal(named name: String) throws -> String {
        precondition(name.hasPrefix("QA "), "test goals are named QA …")
        let deadline = Calendar.current.date(byAdding: .month, value: 3, to: Date()) ?? Date()
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: deadline)
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "emoji": "\u{1F3AF}",
            "color": "jade",
            "targetCents": 10_000,
            "deadline": String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0),
            "frequency": "weekly",
        ])
        let (status, json) = try Self.request("POST", "/goals", body: body, token: token)
        guard status == 201, let id = (json as? [String: Any])?["id"] as? String else {
            throw APIFailure(path: "/goals (POST)", status: status)
        }
        return id
    }

    /// Cleanup after a failed run: deletes (step-up) every goal with this exact
    /// QA name, which moves its money back to the balance.
    func deleteGoals(named name: String, password: String) {
        guard name.hasPrefix("QA "), let list = try? goals() else { return }
        for goal in list where goal.name == name {
            let body = try? JSONSerialization.data(withJSONObject: ["currentPassword": password])
            _ = try? Self.request("POST", "/goals/\(goal.id)/delete", body: body, token: token)
        }
    }

    private struct APIFailure: Error, CustomStringConvertible {
        let path: String
        let status: Int
        var description: String { "\(path) returned HTTP \(status)" }
    }

    private static func goal(from object: [String: Any]) -> SavingsTestGoal? {
        guard let id = object["id"] as? String, let name = object["name"] as? String,
              let saved = object["savedCents"] as? Int, let target = object["targetCents"] as? Int
        else { return nil }
        return SavingsTestGoal(
            id: id, name: name,
            emoji: object["emoji"] as? String ?? "",
            color: object["color"] as? String ?? "",
            frequency: object["frequency"] as? String ?? "",
            deadline: object["deadline"] as? String ?? "",
            savedCents: saved, targetCents: target
        )
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (Int, Data?, (any Error)?) = (0, nil, nil)

        func set(_ value: (Int, Data?, (any Error)?)) {
            lock.lock()
            stored = value
            lock.unlock()
        }

        func get() -> (Int, Data?, (any Error)?) {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private static func request(_ method: String, _ path: String, body: Data?, token: String?) throws -> (Int, Any?) {
        var request = URLRequest(url: URL(string: base.absoluteString + path)!)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        if let token { request.setValue(token, forHTTPHeaderField: "x-session-token") }
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body ?? Data("{}".utf8)
        }
        let box = ResponseBox()
        let done = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        URLSession(configuration: configuration).dataTask(with: request) { data, response, error in
            box.set(((response as? HTTPURLResponse)?.statusCode ?? 0, data, error))
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 20)
        let (status, data, error) = box.get()
        if let error { throw error }
        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return (status, json)
    }
}
