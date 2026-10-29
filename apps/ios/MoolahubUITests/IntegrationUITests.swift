import UIKit
import XCTest

/// Cross-feature UI tests owned by the integration engineer, run against the
/// local dev backend through `apps/ios/scripts/ui-test.sh` (it enrolls Face ID
/// for the run and answers each prompt, see `UITestFaceID`). Helpers are
/// `private` and prefixed `journey` so they never collide with a feature's file.
///
/// - `testJourneyOnDemoAccount`: one long journey on the demo account through
///   every tab, every app-level sheet and every screen on the way, with a
///   screenshot of each, cross-checked against the API.
/// - Tab navigation (pushes from Home, re-tap pops to root), session expiry
///   (a 401 returns to Sign in), app lock after a minute in the background,
///   and the main tabs in dark mode and at the largest accessibility text size.
/// - `testReviewScreensInCurrentSettings`: read-only review screenshots of
///   every screen on seeded data, in the simulator's current appearance,
///   contrast and (optionally) text size.
///
/// Money only moves into a goal this test creates ("QA journey"), which the
/// teardown deletes again (its money goes back to the balance). The seeded
/// goals and groups are only read; Family susu is never paid into.
final class IntegrationUITests: XCTestCase {
    private static let goalName = "QA journey"

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - The journey

    @MainActor
    func testJourneyOnDemoAccount() throws {
        let password = try UITestAccount.demoPassword()
        let api = try JourneyAPI.signIn(email: UITestAccount.demoEmail, password: password)
        // A goal left by an earlier failed run would make two "QA journey"s.
        api.deleteGoals(named: Self.goalName, password: password)
        addTeardownBlock { [api] in
            api.deleteGoals(named: Self.goalName, password: password)
            api.signOut()
        }

        // Welcome and Sign in.
        let app = XCUIApplication.launchedClean()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 30), "Welcome did not appear")
        journeyShot(app, "J01 Welcome")
        app.buttons["Sign in"].tap()
        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15), "Sign in did not open")
        journeyShot(app, "J02 Sign in")
        emailField.tap()
        emailField.typeText(UITestAccount.demoEmail)
        let passwordField = app.secureTextFields["Password"]
        passwordField.tap()
        passwordField.typeText(password)
        app.buttons["auth.signIn.submit"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "tabs did not appear after sign in")
        for tab in ["Home", "Savings", "Groups", "Activity", "Account"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "missing tab \(tab)")
        }

        // The one-time app lock offer (DESIGN.md §8.7) on a device with a passcode.
        if journeyWaitForLockOffer(app) {
            journeyShot(app, "J03 App lock offer")
        }
        app.dismissSignInPrompts()

        // Home: the balance card matches the API.
        let figuresBefore = try journeyFigures(app)
        XCTAssertEqual(figuresBefore.available, try api.availableCents(), "Home's available balance is the API's")
        XCTAssertTrue(app.staticTexts["home.greeting"].exists || app.descendants(matching: .any)["home.greeting"].exists)
        journeyShot(app, "J04 Home")
        app.swipeUp()
        journeyShot(app, "J05 Home scrolled")
        app.swipeDown()

        // Add test money $5.00 (app-level sheet from Home).
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10), "Add test money did not open")
        journeyShot(app, "J06 Add test money")
        journeyTapKeys(app, ["5"], expect: "5.00 US dollars")
        journeyShot(app, "J07 Add test money 5 dollars")
        let depositSentAt = Date()
        app.buttons["home.addMoney.submit"].tap()
        XCTAssertTrue(app.staticTexts["Test money added"].waitForExistence(timeout: 30), "no receipt after adding test money")
        XCTAssertTrue(journeyRow(app, "Status", "Done").waitForExistence(timeout: 15), "receipt never matched Activity as Done")
        journeyShot(app, "J08 Test money added")
        let deposit = try XCTUnwrap(try api.newestActivity(type: "deposit", amountCents: 500, since: depositSentAt), "no +$5.00 deposit in GET /activity")
        journeyTap(app.buttons.matching(identifier: "Done"))
        XCTAssertTrue(journeyWaitForFigures(app) { $0.available == figuresBefore.available + 500 }, "Home did not show the $5.00")
        journeyShot(app, "J09 Home after adding money")

        // The balance disclosure, Cash out, and Move to goal's first step.
        let disclosure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Held as USDC")).firstMatch
        XCTAssertTrue(disclosure.exists, "balance disclosure footer missing")
        disclosure.tap()
        XCTAssertTrue(app.staticTexts["About your balance"].waitForExistence(timeout: 10), "About your balance did not open")
        journeyShot(app, "J10 About your balance")
        journeyTap(app.buttons.matching(identifier: "Done"))
        XCTAssertTrue(app.staticTexts["About your balance"].waitForNonExistence(timeout: 10))

        app.buttons["Cash out"].tap()
        XCTAssertTrue(app.staticTexts["Cashing out isn't available yet. We'll let you know when it is."].waitForExistence(timeout: 10))
        journeyShot(app, "J11 Cash out")
        journeyTap(app.buttons.matching(identifier: "Done"))
        XCTAssertTrue(app.staticTexts["Cashing out isn't available yet. We'll let you know when it is."].waitForNonExistence(timeout: 10))

        app.buttons["Move to goal"].tap()
        XCTAssertTrue(journeyLabeled(app, "Choose a goal").waitForExistence(timeout: 10), "Move to goal did not start at Choose a goal")
        journeyShot(app, "J12 Move to goal choose a goal")
        app.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(journeyLabeled(app, "Choose a goal").waitForNonExistence(timeout: 10))

        // Savings: create "QA journey".
        journeyOpenTab(app, "Savings")
        XCTAssertTrue(app.descendants(matching: .any)["savings.summary"].waitForExistence(timeout: 20), "Savings did not load")
        journeyShot(app, "J13 Savings")
        app.buttons["savings.createGoal"].tap()
        XCTAssertTrue(journeyLabeled(app, "Create a goal").waitForExistence(timeout: 10), "Create goal did not open")
        journeyShot(app, "J14 Create goal")
        let nameField = app.textFields["Goal name"]
        nameField.tap()
        nameField.typeText(Self.goalName)
        app.buttons["savings.create.icon.travel"].tap()
        app.buttons["savings.create.target"].tap()
        XCTAssertTrue(journeyLabeled(app, "Target amount").waitForExistence(timeout: 10))
        journeyTapKeys(app, ["1", "0", "0"], expect: "100.00 US dollars")
        app.buttons["savings.amount.continue"].tap()
        let targetField = app.buttons["savings.create.target"]
        XCTAssertTrue(targetField.waitForExistence(timeout: 10))
        XCTAssertEqual(targetField.value as? String, "100.00 US dollars")
        journeyShot(app, "J15 Create goal filled in")
        let submit = app.buttons["savings.create.submit"]
        var swipes = 0
        while !submit.isHittable && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(submit.isEnabled, "Create goal is disabled with a name and a target")
        submit.tap()
        XCTAssertTrue(app.navigationBars[Self.goalName].waitForExistence(timeout: 30), "did not land on the new goal")
        let goal = try XCTUnwrap(try api.goals().first { $0.name == Self.goalName }, "QA journey is not in GET /goals")
        XCTAssertEqual(goal.savedCents, 0)
        XCTAssertEqual(goal.targetCents, 10_000)
        journeyShot(app, "J16 Goal detail new")

        // Move $2.00 into it: review, Face ID, receipt matched in Activity.
        app.buttons["savings.detail.moveToGoal"].tap()
        let availableLine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Available $")).firstMatch
        XCTAssertTrue(availableLine.waitForExistence(timeout: 15), "the available balance did not load")
        journeyShot(app, "J17 Move to goal amount")
        journeyTapKeys(app, ["2"], expect: "2.00 US dollars")
        app.buttons["savings.amount.continue"].tap()
        let reviewAmount = app.descendants(matching: .any)["savings.review.amount"]
        XCTAssertTrue(reviewAmount.waitForExistence(timeout: 10), "Review did not open")
        XCTAssertEqual(reviewAmount.label, "2.00 US dollars")
        XCTAssertTrue(journeyRow(app, "From", "Balance").exists)
        XCTAssertTrue(journeyRow(app, "To", Self.goalName).exists)
        XCTAssertTrue(journeyRow(app, "Fee", "No fee").exists)
        journeyShot(app, "J18 Move to goal review")
        let confirm = app.buttons["savings.review.confirm"]
        let confirmLabel = confirm.label
        let moveSentAt = Date()
        confirm.tap()
        if confirmLabel != "Confirm" {
            UITestFaceID.answer("match", app: app)
        }
        XCTAssertTrue(journeyLabeled(app, "Moved to \(Self.goalName)").waitForExistence(timeout: 30), "no Move to goal receipt")
        XCTAssertTrue(journeyRow(app, "Status", "Done").waitForExistence(timeout: 15), "receipt never matched Activity as Done")
        journeyShot(app, "J19 Moved to goal receipt")
        let allocate = try XCTUnwrap(try api.newestActivity(type: "goal_allocate", amountCents: -200, since: moveSentAt), "no -$2.00 goal_allocate in GET /activity")
        XCTAssertEqual(try api.goals().first { $0.id == goal.id }?.savedCents, 200, "the API's goal holds $2.00")
        journeyTap(app.buttons.matching(identifier: "Done"))
        let header = app.descendants(matching: .any)["savings.detail.header"]
        XCTAssertTrue(journeyWait(for: header, valueHasPrefix: "2.00 US dollars saved of 100.00 US dollars."), "detail did not show $2.00 saved: \(header.value ?? "nil")")
        journeyShot(app, "J20 Goal detail after the move")

        // Home picks up both moves when its tab comes back.
        journeyOpenTab(app, "Home")
        XCTAssertTrue(
            journeyWaitForFigures(app) { $0.available == figuresBefore.available + 300 && $0.inGoals == figuresBefore.inGoals + 200 },
            "Home did not show +$5.00 −$2.00 available and +$2.00 in goals"
        )
        journeyShot(app, "J21 Home after the move")

        // Groups: the list, Family susu, its payout order and pay-in review.
        journeyOpenTab(app, "Groups")
        XCTAssertTrue(app.descendants(matching: .any)["groups.list"].waitForExistence(timeout: 20), "Groups did not load")
        journeyShot(app, "J22 Groups")
        let familySusu = app.buttons.matching(identifier: "groups.card")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Family susu.")).firstMatch
        XCTAssertTrue(familySusu.waitForExistence(timeout: 15), "Family susu card missing")
        journeyScrollTo(app, familySusu)
        familySusu.tap()
        XCTAssertTrue(app.navigationBars["Family susu"].waitForExistence(timeout: 15), "Family susu did not open")
        XCTAssertTrue(app.descendants(matching: .any)["groups.detail.round"].waitForExistence(timeout: 15))
        journeyShot(app, "J23 Family susu")
        let payIn = app.buttons["groups.detail.payIn"]
        if payIn.exists {
            payIn.tap()
            let payInConfirm = app.buttons["groups.payIn.confirm"]
            XCTAssertTrue(payInConfirm.waitForExistence(timeout: 10), "Pay in review did not open")
            XCTAssertTrue(app.staticTexts["Pay-ins can't be undone."].exists)
            journeyShot(app, "J24 Family susu pay in review")
            // Close without paying: Family susu stays due for everyone else.
            journeyTap(app.buttons.matching(identifier: "Close"))
            XCTAssertTrue(payInConfirm.waitForNonExistence(timeout: 10), "Pay in review did not close")
        }
        journeyBringNearTop(app, app.staticTexts["Payout order"])
        XCTAssertTrue(app.descendants(matching: .any)["groups.detail.payoutOrder"].exists, "no payout order")
        journeyShot(app, "J25 Family susu payout order")
        journeyBringNearTop(app, app.staticTexts["Members (4)"])
        XCTAssertTrue(app.descendants(matching: .any)["groups.detail.members"].exists, "no members")
        journeyShot(app, "J26 Family susu members")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Groups"].waitForExistence(timeout: 10))

        app.buttons["groups.createButton"].tap()
        XCTAssertTrue(app.buttons["groups.create.submit"].waitForExistence(timeout: 10), "Create group did not open")
        journeyShot(app, "J27 Create group")
        journeyTap(app.buttons.matching(identifier: "Close"))
        XCTAssertTrue(app.buttons["groups.create.submit"].waitForNonExistence(timeout: 10), "Create group did not close")

        let howItWorks = app.buttons["groups.howItWorks"]
        journeyScrollTo(app, howItWorks, maxSwipes: 20)
        howItWorks.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groups.howItWorksSheet"].waitForExistence(timeout: 10))
        journeyShot(app, "J28 How groups work")
        journeyTap(app.buttons.matching(identifier: "Done"))

        // Activity shows both moves.
        journeyOpenTab(app, "Activity")
        let depositRow = app.descendants(matching: .any)["activity.row.\(deposit.id)"]
        XCTAssertTrue(depositRow.waitForExistence(timeout: 20), "the $5.00 deposit is not in Activity")
        XCTAssertTrue(depositRow.label.contains("plus 5.00 US dollars"), depositRow.label)
        let allocateRow = app.descendants(matching: .any)["activity.row.\(allocate.id)"]
        XCTAssertTrue(allocateRow.exists, "the $2.00 move is not in Activity")
        XCTAssertTrue(allocateRow.label.contains("Moved to \(Self.goalName)"), allocateRow.label)
        XCTAssertTrue(allocateRow.label.contains("minus 2.00 US dollars"), allocateRow.label)
        journeyShot(app, "J29 Activity")

        // Account and everything under it.
        journeyOpenTab(app, "Account")
        XCTAssertTrue(app.descendants(matching: .any)["account.header"].waitForExistence(timeout: 15))
        journeyShot(app, "J30 Account")
        journeyPush(app, row: "account.row.profile", title: "Profile", waitFor: "account.profile.email", shot: "J31 Profile")
        app.buttons["account.row.security"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["account.security.password"].waitForExistence(timeout: 15))
        journeyShot(app, "J32 Security")
        journeyPush(app, row: "account.security.password", title: "Change password", waitFor: "account.changePassword.save", shot: "J33 Change password")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
        journeyPush(app, row: "account.row.notifications", title: "Notifications", waitFor: "account.notifications.option.everything", shot: "J34 Notifications")
        journeyPush(app, row: "account.row.technicalDetails", title: "Technical details", waitFor: "account.technical.toggle", shot: "J35 Technical details")
        journeyPush(app, row: "account.row.about", title: "About and legal", waitFor: "account.about.version", shot: "J36 About and legal")

        let developer = app.buttons["account.row.developerSettings"]
        journeyScrollTo(app, developer)
        developer.tap()
        XCTAssertTrue(app.navigationBars["Developer settings"].waitForExistence(timeout: 10), "Developer settings did not open")
        journeyShot(app, "J37 Developer settings")
        journeyTap(app.buttons.matching(identifier: "Close"))
        XCTAssertTrue(app.navigationBars["Developer settings"].waitForNonExistence(timeout: 10))

        // Sign out returns to Welcome.
        let signOut = app.buttons["account.signOut"]
        journeyScrollTo(app, signOut)
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForExistence(timeout: 10), "sign-out dialog missing")
        journeyShot(app, "J38 Sign out dialog")
        let confirmSignOut = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Sign out", "account.signOut")).firstMatch
        XCTAssertTrue(confirmSignOut.waitForExistence(timeout: 5))
        confirmSignOut.tap()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 20), "Welcome did not appear after sign out")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "tabs still showing after sign out")
        journeyShot(app, "J39 Welcome after sign out")
    }

    // MARK: - Tabs and cross-feature pushes

    /// Goal and group detail open on Home's own stack, each tab keeps its stack
    /// when you switch away, and re-tapping the selected tab pops to its root
    /// (DESIGN.md §6). "See all" and "History" switch tabs.
    @MainActor
    func testTabsKeepTheirStacksAndReTapPopsToRoot() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        let greeting = app.descendants(matching: .any)["home.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 20))

        // Goal detail from Home, then re-tap Home.
        let homeGoal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.goal.")).firstMatch
        XCTAssertTrue(homeGoal.waitForExistence(timeout: 20), "no goal on Home")
        let goalName = homeGoal.label
        journeyScrollTo(app, homeGoal)
        homeGoal.tap()
        XCTAssertTrue(app.navigationBars[goalName].waitForExistence(timeout: 15), "goal detail did not open from Home")
        XCTAssertTrue(app.descendants(matching: .any)["savings.detail.header"].waitForExistence(timeout: 15))
        journeyShot(app, "T01 Goal detail from Home")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars[goalName].waitForNonExistence(timeout: 10), "re-tapping Home did not pop to its root")
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))

        // Group detail from Home; switching tabs keeps it; re-tap pops.
        let homeGroup = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.group.")).firstMatch
        XCTAssertTrue(homeGroup.waitForExistence(timeout: 15), "no group on Home")
        let groupName = try XCTUnwrap(homeGroup.label.components(separatedBy: ". ").first)
        journeyScrollTo(app, homeGroup)
        homeGroup.tap()
        XCTAssertTrue(app.navigationBars[groupName].waitForExistence(timeout: 15), "group detail did not open from Home")
        XCTAssertTrue(app.descendants(matching: .any)["groups.detail.round"].waitForExistence(timeout: 15))
        journeyShot(app, "T02 Group detail from Home")
        journeyOpenTab(app, "Savings")
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 10))
        journeyOpenTab(app, "Home")
        XCTAssertTrue(app.navigationBars[groupName].waitForExistence(timeout: 10), "Home lost its stack when switching tabs")
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(app.navigationBars[groupName].waitForNonExistence(timeout: 10), "re-tapping Home did not pop to its root")
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))

        // Savings: push a goal, re-tap Savings.
        journeyOpenTab(app, "Savings")
        let savingsCard = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "savings.goalCard.")).firstMatch
        XCTAssertTrue(savingsCard.waitForExistence(timeout: 15))
        let savingsGoalName = savingsCard.label
        savingsCard.tap()
        XCTAssertTrue(app.navigationBars[savingsGoalName].waitForExistence(timeout: 15))
        app.tabBars.buttons["Savings"].tap()
        XCTAssertTrue(app.navigationBars[savingsGoalName].waitForNonExistence(timeout: 10), "re-tapping Savings did not pop to its root")
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 10))

        // "History" on the balance card and "See all" switch tabs.
        journeyOpenTab(app, "Home")
        XCTAssertTrue(greeting.waitForExistence(timeout: 10))
        app.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["Activity"].waitForExistence(timeout: 10), "History did not open Activity")
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected)
        journeyOpenTab(app, "Home")
        let seeAllGoals = app.buttons["See all"].firstMatch
        XCTAssertTrue(seeAllGoals.waitForExistence(timeout: 10))
        seeAllGoals.tap()
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 10), "Your goals See all did not open Savings")
    }

    // MARK: - Session expiry

    /// A 401 on any screen ends the session and returns to Sign in with
    /// "You've been signed out. Please sign in again." (DESIGN.md §9.4). The
    /// session is revoked the way the server does it for real: a password
    /// change elsewhere signs out every other session. Uses a fresh
    /// "QA Journey Expiry" account (j…@moolahub.test), never the demo one.
    @MainActor
    func testSessionExpiryReturnsToSignIn() throws {
        let account = try JourneyAPI.registerFreshAccount()
        let app = XCUIApplication.launchedClean()
        app.signIn(email: account.email, password: account.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))

        // Revoke the app's session from another session.
        let other = try JourneyAPI.signIn(email: account.email, password: account.password)
        let newPassword = account.password + "-2"
        try other.changePassword(current: account.password, new: newPassword)
        other.signOut()

        // The next request anywhere answers 401 (the tab bar goes away at once,
        // so this can't wait for the tab to be selected; it taps again only
        // while the tab bar is still there and Activity isn't selected).
        let notice = app.staticTexts["You've been signed out. Please sign in again."]
        let activityTab = app.tabBars.buttons["Activity"]
        for _ in 0..<3 where !notice.exists {
            if activityTab.exists && !activityTab.isSelected {
                activityTab.tap()
            }
            _ = notice.waitForExistence(timeout: 8)
        }
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "a 401 did not return to Sign in with the signed-out notice")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "tabs still showing after the session expired")
        XCTAssertTrue(app.textFields["Email"].exists, "not on Sign in")
        journeyShot(app, "E01 Signed out after the session expired")

        // The token is gone: a relaunch starts signed out.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 20) || app.textFields["Email"].exists, "a relaunch did not start signed out")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    // MARK: - App lock

    /// App lock relocks after more than 60 seconds in the background, not
    /// after a short trip (DESIGN.md §8.7). Turned on from the sign-in offer.
    @MainActor
    func testAppLockRelocksAfterAMinuteInBackground() throws {
        guard UITestFaceID.directory != nil else {
            throw XCTSkip("needs Face ID: run through apps/ios/scripts/ui-test.sh")
        }
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 30), "Welcome did not appear")
        app.buttons["Sign in"].tap()
        let emailField = app.textFields["Email"]
        XCTAssertTrue(emailField.waitForExistence(timeout: 15))
        emailField.tap()
        emailField.typeText(UITestAccount.demoEmail)
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(password)
        app.buttons["auth.signIn.submit"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))

        // Turn it on from the offer: one Face ID match.
        XCTAssertTrue(journeyWaitForLockOffer(app), "no app lock offer after the first sign-in")
        let turnOn = app.buttons["Turn on Face ID"]
        XCTAssertTrue(turnOn.exists, "the offer has no Turn on Face ID")
        turnOn.tap()
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(turnOn.waitForNonExistence(timeout: 20), "the offer did not close after Face ID")
        app.dismissSignInPrompts()
        let locked = app.staticTexts["MoolaHub is locked"]

        // A short trip to the background doesn't lock.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        app.activate()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(locked.waitForExistence(timeout: 3), "locked after only 5 seconds in the background")

        // More than a minute does.
        XCUIDevice.shared.press(.home)
        RunLoop.current.run(until: Date().addingTimeInterval(65))
        app.activate()
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "not locked after 65 seconds in the background")
        XCTAssertTrue(app.buttons["Unlock with Face ID"].exists)
        journeyShot(app, "L01 Locked after a minute in the background")
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(locked.waitForNonExistence(timeout: 20), "Face ID did not unlock")
        journeyShotAfterUnlock(app)

        // Leave the device setting off again.
        journeyOpenTab(app, "Account")
        app.buttons["account.row.security"].tap()
        let toggle = app.switches["account.security.appLock"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? String, "1", "app lock is not on in Security")
        let inner = toggle.switches.firstMatch
        if inner.exists, inner.frame.width < toggle.frame.width {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertTrue(journeyWait(for: toggle, value: "0"), "app lock did not turn off")
    }

    // MARK: - Dark mode and the largest text size

    @MainActor
    func testMainTabsInDarkMode() throws {
        let password = try UITestAccount.demoPassword()
        XCUIDevice.shared.appearance = .dark
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        _ = try journeyFigures(app)
        journeyShotTabs(app, suffix: "dark", expectDark: true)
    }

    @MainActor
    func testMainTabsAtTheLargestTextSize() throws {
        let password = try UITestAccount.demoPassword()
        // Sign in at the default size, then relaunch at AX5 with the session kept.
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "relaunch at AX5 did not restore the session")
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        journeyShotTabs(app, suffix: "AX5", expectDark: false)
    }

    // MARK: - Review screenshots on seeded data

    /// Review screenshots of every screen on an account's SEEDED data, in the
    /// simulator's current appearance and contrast (U9 item 8: realistic data,
    /// no "QA …" names where the account's own data allows). Read-only: it
    /// opens sheets and closes them, moves no money, creates and deletes
    /// nothing, and changes no setting on the server.
    ///
    /// - `MH_REVIEW_ACCOUNT` (`TEST_RUNNER_MH_REVIEW_ACCOUNT`): the seeded
    ///   account to sign in as (default the demo account; the friends share
    ///   its password). Screens the account has no data for are skipped.
    /// - `MH_REVIEW_CONTENT_SIZE`: e.g. `UICTContentSizeCategoryAccessibilityXXXL`.
    ///   Welcome and Sign in are shot from a clean launch at that size; the
    ///   app signs in at the default size, then relaunches at that size with
    ///   the session kept (typing into fields at AX5 is not what is reviewed).
    /// - `MH_REVIEW_SCOPE=main`: only Welcome, Sign in, Home, Savings, Goal
    ///   detail, Groups, Group detail, Activity and Account.
    @MainActor
    func testReviewScreensInCurrentSettings() throws {
        let password = try UITestAccount.demoPassword()
        let environment = ProcessInfo.processInfo.environment
        let email = environment["MH_REVIEW_ACCOUNT"].flatMap { $0.isEmpty ? nil : $0 } ?? UITestAccount.demoEmail
        let contentSize = environment["MH_REVIEW_CONTENT_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
        let everything = environment["MH_REVIEW_SCOPE"] != "main"
        let sizeArguments = contentSize.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? []

        // Welcome and Sign in, at the size under review.
        var app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state"] + sizeArguments
        app.launch()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 30), "Welcome did not appear")
        journeyShot(app, "R01 Welcome")
        journeyTap(app.buttons.matching(identifier: "Sign in"))
        XCTAssertTrue(app.textFields["Email"].waitForExistence(timeout: 15), "Sign in did not open")
        journeyShot(app, "R02 Sign in")
        // With the keyboard up: Email and the Password under it both clear
        // the pinned bar (B1.0.2, B1.0.3), on a 375 × 667 iPhone too.
        app.textFields["Email"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        journeyShot(app, "R02b Sign in Email focused")

        // Sign in at the default size, then come back at the size under review.
        if contentSize != nil {
            app.terminate()
            app = XCUIApplication.launchedClean()
        }
        app.signIn(email: email, password: password)
        if contentSize != nil {
            app.terminate()
            app.launchArguments = sizeArguments
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "relaunch did not restore the session")
        }

        // Home.
        let greeting = app.descendants(matching: .any)["home.greeting"]
        XCTAssertTrue(greeting.waitForExistence(timeout: 20), "Home did not load")
        XCTAssertTrue(journeyLabeled(app, "Total balance").waitForExistence(timeout: 30), "the balance did not load")
        reviewWaitForFigures(app)
        journeyShot(app, "R03 Home")

        if everything {
            let disclosure = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Held as USDC")).firstMatch
            journeyScrollTo(app, disclosure)
            disclosure.tap()
            XCTAssertTrue(app.staticTexts["About your balance"].waitForExistence(timeout: 10), "About your balance did not open")
            journeyShot(app, "R07 About your balance")
            journeyTap(app.buttons.matching(identifier: "Done"))
            XCTAssertTrue(app.staticTexts["About your balance"].waitForNonExistence(timeout: 10))

            app.buttons["Add money"].tap()
            XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10), "Add test money did not open")
            journeyShot(app, "R08 Add test money")
            app.buttons["home.addMoney.close"].tap()
            XCTAssertTrue(app.staticTexts["Add test money"].waitForNonExistence(timeout: 10))

            app.buttons["Cash out"].tap()
            let cashOutBody = app.staticTexts["Cashing out isn't available yet. We'll let you know when it is."]
            XCTAssertTrue(cashOutBody.waitForExistence(timeout: 10), "Cash out did not open")
            journeyShot(app, "R09 Cash out")
            journeyTap(app.buttons.matching(identifier: "Done"))
            XCTAssertTrue(cashOutBody.waitForNonExistence(timeout: 10))

            let moveToGoal = app.buttons["Move to goal"]
            if moveToGoal.isEnabled {
                moveToGoal.tap()
                XCTAssertTrue(journeyLabeled(app, "Choose a goal").waitForExistence(timeout: 10), "Move to goal did not open")
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                journeyShot(app, "R10 Move to goal choose a goal")
                app.buttons["savings.sheet.close"].tap()
                XCTAssertTrue(journeyLabeled(app, "Choose a goal").waitForNonExistence(timeout: 10))
            }
        }
        reviewScrollStep(app)
        journeyShot(app, "R04 Home goals and groups")
        reviewScrollStep(app)
        journeyShot(app, "R05 Home recent activity")
        reviewScrollToBottom(app)
        journeyShot(app, "R06 Home end")

        // Savings and a seeded goal.
        journeyOpenTab(app, "Savings")
        let savingsReady = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@", "savings.summary", "No goals yet"
        )).firstMatch
        XCTAssertTrue(savingsReady.waitForExistence(timeout: 20), "Savings did not load")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        journeyShot(app, "R11 Savings")
        let seededGoal = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (label BEGINSWITH %@)", "savings.goalCard.", "QA ")).firstMatch
        if seededGoal.waitForExistence(timeout: 5) {
            let goalName = seededGoal.label
            seededGoal.tap()
            XCTAssertTrue(app.navigationBars[goalName].waitForExistence(timeout: 15), "goal detail did not open")
            XCTAssertTrue(app.descendants(matching: .any)["savings.detail.header"].waitForExistence(timeout: 15))
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            journeyShot(app, "R12 Goal detail")
            if everything {
                // The More menu: "Delete goal" with its trash glyph, both in
                // the system's destructive red. Opening a menu changes nothing;
                // a tap outside closes it.
                app.buttons["savings.detail.more"].tap()
                XCTAssertTrue(app.buttons["Delete goal"].waitForExistence(timeout: 10), "the More menu did not open")
                RunLoop.current.run(until: Date().addingTimeInterval(0.8))
                journeyShot(app, "R12b Goal detail More menu")
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
                XCTAssertTrue(app.buttons["Delete goal"].waitForNonExistence(timeout: 10), "the More menu did not close")
                app.buttons["savings.detail.moveToGoal"].tap()
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Available $")).firstMatch.waitForExistence(timeout: 15), "the available balance did not load")
                journeyShot(app, "R15 Move to goal amount")
                app.buttons["savings.sheet.close"].tap()
                XCTAssertTrue(app.buttons["savings.amount.continue"].waitForNonExistence(timeout: 10))
                let moveToBalance = app.buttons["savings.detail.moveToBalance"]
                if moveToBalance.isEnabled {
                    moveToBalance.tap()
                    XCTAssertTrue(app.buttons["savings.amount.continue"].waitForExistence(timeout: 10), "Move to balance did not open")
                    journeyShot(app, "R16 Move to balance amount")
                    app.buttons["savings.sheet.close"].tap()
                    XCTAssertTrue(app.buttons["savings.amount.continue"].waitForNonExistence(timeout: 10))
                }
            }
            reviewScrollStep(app)
            journeyShot(app, "R13 Goal detail plan")
            reviewScrollToBottom(app)
            journeyShot(app, "R14 Goal detail history")
            app.tabBars.buttons["Savings"].tap()
            XCTAssertTrue(app.navigationBars[goalName].waitForNonExistence(timeout: 10))
        }
        if everything {
            app.buttons["savings.createGoal"].tap()
            XCTAssertTrue(journeyLabeled(app, "Create a goal").waitForExistence(timeout: 10), "Create goal did not open")
            journeyShot(app, "R17 Create goal")
            app.buttons["savings.sheet.close"].tap()
            XCTAssertTrue(journeyLabeled(app, "Create a goal").waitForNonExistence(timeout: 10))
        }

        // Groups and the seeded groups.
        journeyOpenTab(app, "Groups")
        XCTAssertTrue(app.descendants(matching: .any)["groups.list"].waitForExistence(timeout: 20), "Groups did not load")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        journeyShot(app, "R18 Groups")
        for (index, name) in ["Family susu", "Holiday pot"].enumerated() {
            guard index == 0 || everything else { break }
            let card = app.buttons.matching(identifier: "groups.card").matching(NSPredicate(format: "label BEGINSWITH %@", "\(name).")).firstMatch
            guard card.waitForExistence(timeout: 5) else { continue }
            journeyScrollTo(app, card, maxSwipes: 40)
            if index == 0 {
                journeyBringNearTop(app, card, maxSwipes: 10)
                reviewKeepBelowNavigationBar(app, card)
                journeyShot(app, "R19 Groups seeded cards")
            }
            card.tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 15), "\(name) did not open")
            XCTAssertTrue(app.descendants(matching: .any)["groups.detail.round"].waitForExistence(timeout: 15))
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            journeyShot(app, "R2\(index * 4) \(name)")
            reviewScrollStep(app)
            journeyShot(app, "R2\(index * 4 + 1) \(name) rounds")
            reviewScrollStep(app)
            journeyShot(app, "R2\(index * 4 + 2) \(name) members")
            reviewScrollToBottom(app)
            journeyShot(app, "R2\(index * 4 + 3) \(name) pay-ins")
            app.tabBars.buttons["Groups"].tap()
            XCTAssertTrue(app.navigationBars[name].waitForNonExistence(timeout: 10))
        }
        if everything {
            let howItWorks = app.buttons["groups.howItWorks"]
            journeyScrollTo(app, howItWorks, maxSwipes: 60)
            howItWorks.tap()
            XCTAssertTrue(app.descendants(matching: .any)["groups.howItWorksSheet"].waitForExistence(timeout: 10))
            journeyShot(app, "R28 How groups work")
            journeyTap(app.buttons.matching(identifier: "Done"))
            app.buttons["groups.createButton"].tap()
            XCTAssertTrue(app.buttons["groups.create.submit"].waitForExistence(timeout: 10), "Create group did not open")
            journeyShot(app, "R29 Create group")
            journeyTap(app.buttons.matching(identifier: "Close"))
            XCTAssertTrue(app.buttons["groups.create.submit"].waitForNonExistence(timeout: 10))
        }

        // Activity and one seeded move's receipt.
        journeyOpenTab(app, "Activity")
        XCTAssertTrue(app.descendants(matching: .any)["activity.scroll"].waitForExistence(timeout: 20), "Activity did not load")
        let firstRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "activity.row.")).firstMatch
        _ = firstRow.waitForExistence(timeout: 20)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        journeyShot(app, "R30 Activity")
        if everything {
            let seededRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND NOT (label CONTAINS %@)", "activity.row.", "QA ")).firstMatch
            if seededRow.exists {
                journeyScrollTo(app, seededRow, maxSwipes: 40)
                seededRow.tap()
                XCTAssertTrue(app.descendants(matching: .any)["activity.receipt"].waitForExistence(timeout: 10), "the receipt did not open")
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                journeyShot(app, "R31 Activity receipt")
                journeyTap(app.buttons.matching(identifier: "Done"))
                XCTAssertTrue(app.descendants(matching: .any)["activity.receipt"].waitForNonExistence(timeout: 10))
            }
        }

        // Account and every screen under it.
        journeyOpenTab(app, "Account")
        XCTAssertTrue(app.descendants(matching: .any)["account.header"].waitForExistence(timeout: 15))
        journeyShot(app, "R32 Account")
        guard everything else { return }
        journeyPush(app, row: "account.row.profile", title: "Profile", waitFor: "account.profile.email", shot: "R34 Profile")
        app.buttons["account.row.security"].tap()
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["account.security.password"].waitForExistence(timeout: 15))
        journeyShot(app, "R35 Security")
        journeyPush(app, row: "account.security.password", title: "Change password", waitFor: "account.changePassword.save", shot: "R36 Change password")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
        journeyPush(app, row: "account.row.notifications", title: "Notifications", waitFor: "account.notifications.option.everything", shot: "R37 Notifications")
        journeyPush(app, row: "account.row.technicalDetails", title: "Technical details", waitFor: "account.technical.toggle", shot: "R38 Technical details")
        let about = app.buttons["account.row.about"]
        journeyScrollTo(app, about)
        about.tap()
        XCTAssertTrue(app.navigationBars["About and legal"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["account.about.version"].waitForExistence(timeout: 15))
        journeyShot(app, "R39 About and legal")
        let aboutBalance = app.buttons["account.about.disclosure.aboutBalance"]
        journeyScrollTo(app, aboutBalance)
        aboutBalance.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.disclosure.text"].waitForExistence(timeout: 10))
        journeyShot(app, "R40 Disclosure detail")
        app.tabBars.buttons["Account"].tap()
        XCTAssertTrue(app.navigationBars["Account"].waitForExistence(timeout: 10))
        reviewScrollToBottom(app)
        journeyShot(app, "R33 Account end")
        let signOut = app.buttons["account.signOut"]
        journeyScrollTo(app, signOut)
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForExistence(timeout: 10), "sign-out dialog missing")
        journeyShot(app, "R41 Sign out dialog")
    }

    /// Waits until the balance card shows its figures (not the skeleton).
    @MainActor
    private func reviewWaitForFigures(_ app: XCUIApplication) {
        XCTAssertTrue(journeyWaitForFigures(app, timeout: 30) { _ in true }, "the balance figures did not load")
    }

    /// One drag of about 40 % of the screen.
    @MainActor
    private func reviewScrollStep(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.72))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.32))
        start.press(forDuration: 0.05, thenDragTo: end)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    }

    /// Drags the content down in small steps until `element` starts below
    /// the navigation bar, so the shot shows all of it.
    @MainActor
    private func reviewKeepBelowNavigationBar(_ app: XCUIApplication, _ element: XCUIElement) {
        let barBottom = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : 120
        var drags = 0
        while element.exists && element.frame.minY < barBottom + 12 && drags < 8 {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.45))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.53))
            start.press(forDuration: 0.05, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            drags += 1
        }
    }

    @MainActor
    private func reviewScrollToBottom(_ app: XCUIApplication) {
        for _ in 0..<12 {
            let before = XCUIScreen.main.screenshot().pngRepresentation
            app.swipeUp()
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            if XCUIScreen.main.screenshot().pngRepresentation == before { break }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func journeyShot(_ app: XCUIApplication, _ name: String) {
        // Let transitions and toasts settle so the picture shows the screen.
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        app.attachScreenshot(named: name, to: self)
    }

    @MainActor
    private func journeyShotAfterUnlock(_ app: XCUIApplication) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10), "tabs not back after unlocking")
        journeyShot(app, "L02 Unlocked")
    }

    /// Screenshots of the five tab roots (Home also scrolled), each checked
    /// for being dark or light from its pixels.
    @MainActor
    private func journeyShotTabs(_ app: XCUIApplication, suffix: String, expectDark: Bool) {
        let tabs: [(name: String, ready: String)] = [
            ("Home", "home.greeting"),
            ("Savings", "savings.summary"),
            ("Groups", "groups.list"),
            ("Activity", "activity.scroll"),
            ("Account", "account.header"),
        ]
        for (index, tab) in tabs.enumerated() {
            journeyOpenTab(app, tab.name)
            XCTAssertTrue(app.descendants(matching: .any)[tab.ready].waitForExistence(timeout: 20), "\(tab.name) did not load (\(suffix))")
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            // The top of every tab is canvas (status bar, title or greeting):
            // judge light or dark there, not under Home's near-black card.
            let brightness = journeyMeanBrightness(XCUIScreen.main.screenshot(), topFraction: 0.1)
            if expectDark {
                XCTAssertLessThan(brightness, 0.3, "\(tab.name) is not dark (top brightness \(brightness))")
            } else {
                XCTAssertGreaterThan(brightness, 0.6, "\(tab.name) is not light (top brightness \(brightness))")
            }
            journeyShot(app, String(format: "%@%02d %@ %@", suffix == "dark" ? "D" : "X", index + 1, tab.name, suffix))
            app.swipeUp()
            journeyShot(app, String(format: "%@%02d %@ %@ scrolled", suffix == "dark" ? "D" : "X", index + 1, tab.name, suffix))
            app.swipeDown()
            app.swipeDown()
        }
    }

    @MainActor
    private func journeyMeanBrightness(_ screenshot: XCUIScreenshot, topFraction: Double) -> Double {
        guard let full = screenshot.image.cgImage,
              let image = full.cropping(to: CGRect(x: 0, y: 0, width: full.width, height: Int(Double(full.height) * topFraction)))
        else { return -1 }
        let width = 24, height = 8
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return -1 }
        var total = 0.0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            total += (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / 255
        }
        return total / Double(width * height)
    }

    @MainActor
    private func journeyOpenTab(_ app: XCUIApplication, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        app.selectTab(name, file: file, line: line)
    }

    /// Pushes an Account row, waits for its screen, screenshots it, goes back.
    @MainActor
    private func journeyPush(_ app: XCUIApplication, row: String, title: String, waitFor identifier: String, shot: String, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[row]
        journeyScrollTo(app, button)
        button.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10), "\(title) did not open", file: file, line: line)
        XCTAssertTrue(app.descendants(matching: .any)[identifier].waitForExistence(timeout: 15), "\(title) did not load", file: file, line: line)
        journeyShot(app, shot)
        app.navigationBars[title].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars[title].waitForNonExistence(timeout: 10), "could not go back from \(title)", file: file, line: line)
    }

    /// Waits for the one-time app lock offer, answering iOS's "Save
    /// Password?" (which can arrive seconds after the offer and cover it).
    /// Returns true once the offer has been on screen with nothing over it
    /// for 6 seconds.
    @MainActor
    private func journeyWaitForLockOffer(_ app: XCUIApplication) -> Bool {
        let offer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Use ", " to open MoolaHub")).firstMatch
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let savePassword = [app.buttons["Not Now"], springboard.buttons["Not Now"]]
        let deadline = Date().addingTimeInterval(45)
        var quietSince = Date()
        while Date() < deadline {
            if let notNow = savePassword.first(where: { $0.exists && $0.isHittable }) {
                notNow.tap()
                quietSince = Date()
            } else if savePassword.contains(where: \.exists) || !offer.exists {
                quietSince = Date()
            } else if Date().timeIntervalSince(quietSince) > 6 && app.buttons["Not now"].isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return false
    }

    /// Taps keypad keys one at a time and checks the amount display.
    @MainActor
    private func journeyTapKeys(_ app: XCUIApplication, _ keys: [String], expect: String, file: StaticString = #filePath, line: UInt = #line) {
        for key in keys {
            let button = app.buttons[key]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "keypad key \(key) missing", file: file, line: line)
            button.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        let display = journeyLabeled(app, "Amount")
        XCTAssertTrue(journeyWait(for: display, valueHasPrefix: expect, timeout: 5), "amount shows \(display.value ?? "nil"), expected \(expect)", file: file, line: line)
    }

    /// Taps the first hittable element of `query` (sheets can leave a
    /// same-named control underneath).
    @MainActor
    private func journeyTap(_ query: XCUIElementQuery, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = query.allElementsBoundByIndex.first(where: { $0.exists && $0.isHittable }) {
                element.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        XCTFail("nothing hittable for \(query)", file: file, line: line)
    }

    @MainActor
    private func journeyLabeled(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A review or receipt row ("Status, Done"): starts with its label and contains its value.
    @MainActor
    private func journeyRow(_ app: XCUIApplication, _ title: String, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", title, value))
            .firstMatch
    }

    @MainActor
    private func journeyWait(for element: XCUIElement, valueHasPrefix prefix: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, let value = element.value as? String, value.hasPrefix(prefix) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func journeyWait(for element: XCUIElement, value: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, element.value as? String == value { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return false
    }

    @MainActor
    private func journeyScrollTo(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 12) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            swipes += 1
        }
    }

    /// Scrolls in small steps until `element` sits in the upper part of the
    /// screen, so a screenshot shows the section under it.
    @MainActor
    private func journeyBringNearTop(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 20) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "\(element) missing")
        let height = app.frame.height
        var swipes = 0
        while element.exists && element.frame.minY > height * 0.3 && swipes < maxSwipes {
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            start.press(forDuration: 0.05, thenDragTo: end)
            swipes += 1
        }
    }

    /// The Home balance card's figures, read from its VoiceOver value
    /// ("Total. Available …. In goals ….").
    private struct JourneyFigures {
        let total: Int
        let available: Int
        let inGoals: Int
    }

    @MainActor
    private func journeyFigures(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws -> JourneyFigures {
        let card = journeyLabeled(app, "Total balance")
        guard card.waitForExistence(timeout: 30) else {
            XCTFail("the balance never loaded", file: file, line: line)
            throw XCTSkip("no balance")
        }
        let amounts = Self.journeySpokenCents(card.value as? String ?? "")
        guard amounts.count >= 3 else {
            XCTFail("balance card value '\(card.value as? String ?? "")' has no amounts", file: file, line: line)
            throw XCTSkip("no amounts")
        }
        return JourneyFigures(total: amounts[0], available: amounts[1], inGoals: amounts[2])
    }

    @MainActor
    private func journeyWaitForFigures(_ app: XCUIApplication, timeout: TimeInterval = 20, until condition: (JourneyFigures) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let figures = try? journeyFigures(app), condition(figures) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return false
    }

    /// "1,240.50 US dollars" → 124050 (en_US, as the app speaks money).
    private static func journeySpokenCents(_ text: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: "(minus )?([0-9][0-9,]*)\\.([0-9]{2}) US dollars") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let wholeRange = Range(match.range(at: 2), in: text),
                  let fractionRange = Range(match.range(at: 3), in: text),
                  let whole = Int(text[wholeRange].replacingOccurrences(of: ",", with: "")),
                  let fraction = Int(text[fractionRange])
            else { return nil }
            let cents = whole * 100 + fraction
            return match.range(at: 1).location == NSNotFound ? cents : -cents
        }
    }
}

// MARK: - Dev API (cross-checks only; tokens stay in memory, never printed)

private struct JourneyGoal {
    let id: String
    let name: String
    let savedCents: Int
    let targetCents: Int
}

private struct JourneyActivity {
    let id: String
    let type: String
    let amountCents: Int
    let createdAt: Date
}

private struct JourneyAccount: Sendable {
    let email: String
    let password: String
}

private final class JourneyAPI: Sendable {
    private static let base = "http://localhost:8787/api"
    private let token: String

    private init(token: String) {
        self.token = token
    }

    static func signIn(email: String, password: String) throws -> JourneyAPI {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let (status, json) = try request("POST", "/auth/login", body: body, token: nil)
        guard status == 200, let token = (json as? [String: Any])?["sessionToken"] as? String else {
            throw JourneyFailure("POST /auth/login returned HTTP \(status)")
        }
        return JourneyAPI(token: token)
    }

    /// Registers "QA Journey Expiry" with a "j…@moolahub.test" email and
    /// verifies it with the code the dev backend writes to its log.
    static func registerFreshAccount() throws -> JourneyAccount {
        let handle = "j\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        let account = JourneyAccount(
            email: "\(handle)@moolahub.test",
            password: "QaJourney-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        )
        let mark = try UITestBackendLog.mark()
        let register = try JSONSerialization.data(withJSONObject: [
            "name": "QA Journey Expiry", "username": handle, "email": account.email,
            "password": account.password, "dateOfBirth": "1990-01-15",
        ])
        let (registerStatus, _) = try request("POST", "/auth/register", body: register, token: nil)
        guard registerStatus == 201 || registerStatus == 200 else {
            throw JourneyFailure("POST /auth/register returned HTTP \(registerStatus)")
        }
        let code = try UITestBackendLog.code(.verification, emailInitial: "j", after: mark)
        let verify = try JSONSerialization.data(withJSONObject: ["email": account.email, "code": code])
        let (verifyStatus, json) = try request("POST", "/auth/verify-email", body: verify, token: nil)
        guard verifyStatus == 200, let token = (json as? [String: Any])?["sessionToken"] as? String else {
            throw JourneyFailure("POST /auth/verify-email returned HTTP \(verifyStatus)")
        }
        JourneyAPI(token: token).signOut()
        return account
    }

    func signOut() {
        _ = try? Self.request("POST", "/auth/logout", body: nil, token: token)
    }

    func changePassword(current: String, new: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["currentPassword": current, "newPassword": new])
        let (status, _) = try Self.request("POST", "/auth/password", body: body, token: token)
        guard status == 200 else { throw JourneyFailure("POST /auth/password returned HTTP \(status)") }
    }

    func availableCents() throws -> Int {
        let (status, json) = try Self.request("GET", "/wallet", body: nil, token: token)
        guard status == 200, let cents = (json as? [String: Any])?["availableCents"] as? Int else {
            throw JourneyFailure("GET /wallet returned HTTP \(status)")
        }
        return cents
    }

    func goals() throws -> [JourneyGoal] {
        let (status, json) = try Self.request("GET", "/goals", body: nil, token: token)
        guard status == 200, let list = json as? [[String: Any]] else { throw JourneyFailure("GET /goals returned HTTP \(status)") }
        return list.compactMap { object in
            guard let id = object["id"] as? String, let name = object["name"] as? String,
                  let saved = object["savedCents"] as? Int, let target = object["targetCents"] as? Int
            else { return nil }
            return JourneyGoal(id: id, name: name, savedCents: saved, targetCents: target)
        }
    }

    /// The newest Activity item of this type and signed amount created no
    /// earlier than 5 seconds before `since`.
    func newestActivity(type: String, amountCents: Int, since: Date) throws -> JourneyActivity? {
        let (status, json) = try Self.request("GET", "/activity?limit=30", body: nil, token: token)
        guard status == 200, let list = json as? [[String: Any]] else { throw JourneyFailure("GET /activity returned HTTP \(status)") }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return list.compactMap { item -> JourneyActivity? in
            guard let id = item["id"] as? String, let itemType = item["type"] as? String,
                  let amount = item["amountCents"] as? Int,
                  let created = (item["createdAt"] as? String).flatMap(parser.date(from:))
            else { return nil }
            return JourneyActivity(id: id, type: itemType, amountCents: amount, createdAt: created)
        }
        .filter { $0.type == type && $0.amountCents == amountCents && $0.createdAt >= since.addingTimeInterval(-5) }
        .max { $0.createdAt < $1.createdAt }
    }

    /// Deletes (with step-up) every goal with this exact QA name; its money
    /// goes back to the balance.
    func deleteGoals(named name: String, password: String) {
        guard name.hasPrefix("QA "), let list = try? goals() else { return }
        for goal in list where goal.name == name {
            let body = try? JSONSerialization.data(withJSONObject: ["currentPassword": password])
            _ = try? Self.request("POST", "/goals/\(goal.id)/delete", body: body, token: token)
        }
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (Int, Data?, (any Error)?) = (0, nil, nil)

        func set(_ value: (Int, Data?, (any Error)?)) {
            lock.withLock { stored = value }
        }

        func get() -> (Int, Data?, (any Error)?) {
            lock.withLock { stored }
        }
    }

    private static func request(_ method: String, _ path: String, body: Data?, token: String?) throws -> (Int, Any?) {
        guard let url = URL(string: base + path) else { throw JourneyFailure("bad path \(path)") }
        var request = URLRequest(url: url)
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

private struct JourneyFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
