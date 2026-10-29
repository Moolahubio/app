import XCTest

/// Cross-feature and adversarial UI tests (QA). Keep helpers `private`.
final class QAExploratoryUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - QA: money moves on a fresh account match the ledger to the cent

    /// A fresh "QA Quinn Ledger" account (q…@moolahub.test, registered through
    /// the API) runs every money move once through the app, each time with a
    /// double tap on the main button, and the server's ledger must show
    /// exactly one move of exactly the amount the app showed:
    /// Add test money $123.45 → Move to goal $45.67 (Face ID) → Move to
    /// balance $12.34 (step-up) → Pay in $12.34 (Face ID) → Delete the goal
    /// holding $33.33 (step-up). The dev backend runs ledger-only, so goal
    /// fees are 0 ("No fee"). Nothing touches the shared demo data.
    @MainActor
    func testQAFreshAccountMoneyMovesMatchTheLedgerAndDoubleTapsMoveOnce() throws {
        guard UITestFaceID.directory != nil else {
            throw XCTSkip("needs Face ID: run through apps/ios/scripts/ui-test.sh")
        }
        let owner = try QAAPI.register(name: "QA Quinn Ledger")
        let partner = try QAAPI.register(name: "QA Quinn Partner")
        let api = try QAAPI.signIn(owner)
        let partnerAPI = try QAAPI.signIn(partner)
        addTeardownBlock {
            api.signOut()
            partnerAPI.signOut()
        }
        let stamp = Int(Date().timeIntervalSince1970) % 1_000_000
        let goalName = "QA Ledger \(stamp)"
        let groupName = "QA Ledger pot \(stamp)"
        let goalID = try api.createGoal(name: goalName, targetCents: 50_000)
        let groupID = try api.createSaveTogetherGroup(name: groupName, contributionCents: 1_234, invite: partner.email)
        try partnerAPI.acceptInvite(circleName: groupName)
        try api.startGroup(id: groupID)
        let started = Date()

        let app = XCUIApplication.launchedClean()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        qaAssertHomeTotal(app, cents: 0)

        // 1. Add test money, $123.45 typed on the keypad, double-tapped.
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10), "Add test money did not open")
        qaTapKeys(app, ["1", "2", "3", ".", "4", "5"], expect: "123.45 US dollars")
        let addSubmit = app.buttons["home.addMoney.submit"]
        XCTAssertTrue(addSubmit.isEnabled)
        let depositSent = Date()
        addSubmit.doubleTap()
        XCTAssertTrue(qaLabeled(app, "Test money added").waitForExistence(timeout: 20), "no Add test money receipt")
        XCTAssertTrue(qaRow(app, "Status", "Done").waitForExistence(timeout: 15), "deposit receipt never matched Activity as Done")
        XCTAssertTrue(qaLabeled(app, "123.45 US dollars").exists, "the receipt does not show the amount sent")
        app.attachScreenshot(named: "QA01 Add test money receipt after a double tap", to: self)
        qaSettle(3)
        XCTAssertEqual(try api.items(type: "deposit", since: depositSent).map(\.amountCents), [12_345], "a double tap must add test money once")
        XCTAssertEqual(try api.wallet().available, 12_345)
        qaTapDone(app)

        // 2. Move to goal from Home, $45.67, Confirm with Face ID double-tapped.
        XCTAssertTrue(qaRow(app, "Status", "Done").waitForNonExistence(timeout: 10), "the receipt did not close")
        app.buttons["Move to goal"].tap()
        let choice = app.buttons["savings.choose.goal.\(goalID)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 15), "the QA goal is not in Choose a goal")
        choice.tap()
        let available = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Available $")).firstMatch
        XCTAssertTrue(available.waitForExistence(timeout: 15), "the available balance did not load")
        XCTAssertEqual(available.label, "Available $123.45")
        qaTapKeys(app, ["4", "5", ".", "6", "7"], expect: "45.67 US dollars")
        app.buttons["savings.amount.continue"].tap()
        let reviewAmount = app.descendants(matching: .any)["savings.review.amount"]
        XCTAssertTrue(reviewAmount.waitForExistence(timeout: 10), "Review did not open")
        XCTAssertEqual(reviewAmount.label, "45.67 US dollars")
        XCTAssertTrue(qaRow(app, "From", "Balance").exists)
        XCTAssertTrue(qaRow(app, "To", goalName).exists)
        XCTAssertTrue(qaRow(app, "Fee", "No fee").exists)
        let confirm = app.buttons["savings.review.confirm"]
        XCTAssertEqual(confirm.label, "Confirm with Face ID")
        let allocateSent = Date()
        confirm.doubleTap()
        qaSettle(1.2)
        app.attachScreenshot(named: "QA02 Move to goal review just after a double tap (Face ID up)", to: self)
        let cancelNote = app.descendants(matching: .any)["savings.review.note"]
        let noteAfterDoubleTap = cancelNote.exists ? cancelNote.label : nil
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(qaLabeled(app, "Moved to \(goalName)").waitForExistence(timeout: 25), "no Move to goal receipt")
        XCTAssertTrue(qaRow(app, "Status", "Done").waitForExistence(timeout: 15), "allocate receipt never matched Activity as Done")
        qaSettle(4)
        app.attachScreenshot(named: "QA03 Move to goal receipt 4 s later", to: self)
        let allocations = try api.items(type: "goal_allocate", since: allocateSent)
        XCTAssertEqual(allocations.map(\.amountCents), [-4_567], "a double tap on Confirm with Face ID must move money once")
        XCTAssertEqual(try api.savedCents(goalID: goalID), 4_567)
        XCTAssertEqual(try api.wallet().available, 12_345 - 4_567)
        // "View goal" (started on Home) opens the goal's detail.
        let viewGoal = app.buttons["View goal"]
        XCTAssertTrue(viewGoal.exists, "no View goal on a receipt that started on Home")
        qaTapDone(app)

        // 3. Move to balance, $12.34, step-up submit double-tapped.
        app.selectTab("Savings")
        let card = app.buttons["savings.goalCard.\(goalID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 15), "the QA goal is not on Savings")
        card.tap()
        let header = app.descendants(matching: .any)["savings.detail.header"]
        XCTAssertTrue(qaWaitFor(header, valueHasPrefix: "45.67 US dollars saved of 500.00 US dollars."), "detail shows \(header.value ?? "nil")")
        app.buttons["savings.detail.moveToBalance"].tap()
        XCTAssertTrue(qaLabeled(app, "In this goal $45.67").waitForExistence(timeout: 10))
        qaTapKeys(app, ["1", "2", ".", "3", "4"], expect: "12.34 US dollars")
        app.buttons["savings.amount.continue"].tap()
        XCTAssertTrue(reviewAmount.waitForExistence(timeout: 10))
        XCTAssertEqual(reviewAmount.label, "12.34 US dollars")
        XCTAssertTrue(qaRow(app, "Fee", "No fee").exists)
        XCTAssertTrue(qaRow(app, "You receive", "12.34 US dollars").exists)
        app.buttons["savings.review.confirm"].tap()
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10), "no Confirm it's you")
        let stepUp = app.buttons["savings.stepUp.submit"]
        XCTAssertTrue(qaWaitEnabled(stepUp, false), "Move to balance must wait for the password")
        password.tap()
        password.typeText(owner.password)
        let releaseSent = Date()
        stepUp.doubleTap()
        XCTAssertTrue(qaLabeled(app, "Moved to your balance").waitForExistence(timeout: 20), "no Move to balance receipt")
        XCTAssertTrue(qaRow(app, "Amount", "12.34 US dollars").exists)
        XCTAssertTrue(qaRow(app, "Fee", "No fee").exists)
        XCTAssertTrue(qaRow(app, "You received", "12.34 US dollars").exists)
        XCTAssertTrue(qaRow(app, "Status", "Done").waitForExistence(timeout: 15))
        qaSettle(3)
        app.attachScreenshot(named: "QA04 Move to balance receipt after a double tap", to: self)
        XCTAssertEqual(try api.items(type: "goal_release", since: releaseSent).map(\.amountCents), [1_234], "a double tap must release once")
        XCTAssertEqual(try api.savedCents(goalID: goalID), 3_333)
        XCTAssertEqual(try api.wallet().available, 12_345 - 4_567 + 1_234)
        qaTapDone(app)
        XCTAssertTrue(qaWaitFor(header, valueHasPrefix: "33.33 US dollars saved of 500.00 US dollars."), "detail shows \(header.value ?? "nil")")

        // 4. Pay in $12.34 to the started group, Face ID double-tapped.
        app.selectTab("Groups")
        let groupCard = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "groups.card", groupName)).firstMatch
        XCTAssertTrue(groupCard.waitForExistence(timeout: 20), "the QA group is not on Groups")
        groupCard.tap()
        let payIn = app.buttons["groups.detail.payIn"]
        XCTAssertTrue(payIn.waitForExistence(timeout: 15), "no Pay in on the started group")
        XCTAssertEqual(payIn.label, "Pay in $12.34")
        payIn.tap()
        let payConfirm = app.buttons["groups.payIn.confirm"]
        XCTAssertTrue(payConfirm.waitForExistence(timeout: 10))
        XCTAssertTrue(qaWaitEnabled(payConfirm, true), "Pay in stayed disabled with $90.12 available")
        XCTAssertEqual(app.descendants(matching: .any)["groups.payIn.amount"].label, "12.34 US dollars")
        XCTAssertTrue(qaRow(app, "Round", "1 of 2").exists)
        let payInSent = Date()
        payConfirm.doubleTap()
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(qaLabeled(app, "Paid in to \(groupName)").waitForExistence(timeout: 25), "no Pay in receipt")
        XCTAssertTrue(qaRow(app, "Status", "Done").waitForExistence(timeout: 15))
        qaSettle(4)
        app.attachScreenshot(named: "QA05 Pay in receipt after a double tap", to: self)
        XCTAssertEqual(try api.items(type: "contribution", since: payInSent).map(\.amountCents), [-1_234], "a double tap must pay in once")
        XCTAssertEqual(try api.wallet().available, 12_345 - 4_567 + 1_234 - 1_234)
        qaTapDone(app)
        // Home must not keep showing the money that just left ($123.45 → $111.11).
        app.selectTab("Home")
        let homeCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", "Total balance", "US dollars")).firstMatch
        let homeCaughtUp = qaWaitFor(homeCard, valueHasPrefix: Self.qaSpoken(11_111), timeout: 10)
        let homeAfterPayIn = homeCard.value as? String ?? "nil"
        app.attachScreenshot(named: "QA05b Home right after the pay-in", to: self)

        // 5. Delete the goal holding $33.33: it all comes back, once.
        app.selectTab("Savings")
        if !app.buttons["savings.detail.more"].exists {
            XCTAssertTrue(card.waitForExistence(timeout: 15))
            card.tap()
        }
        XCTAssertTrue(qaWaitFor(header, valueHasPrefix: "33.33 US dollars saved"), "detail shows \(header.value ?? "nil")")
        app.buttons["savings.detail.more"].tap()
        qaLabeled(app, "Delete goal", type: .button).tap()
        let body = app.staticTexts["savings.delete.body"]
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertEqual(body.label, "This moves the full $33.33 back to your balance and closes the goal.")
        let deletePassword = app.secureTextFields["Password"]
        XCTAssertTrue(deletePassword.waitForExistence(timeout: 10))
        deletePassword.tap()
        deletePassword.typeText(owner.password)
        let deleteSent = Date()
        app.buttons["savings.delete.submit"].doubleTap()
        XCTAssertTrue(qaLabeled(app, "Goal deleted").waitForExistence(timeout: 20), "no Goal deleted receipt")
        XCTAssertTrue(qaRow(app, "Amount", "33.33 US dollars").exists)
        XCTAssertTrue(qaRow(app, "You received", "33.33 US dollars").exists)
        XCTAssertTrue(qaRow(app, "Status", "Done").waitForExistence(timeout: 15))
        qaSettle(3)
        app.attachScreenshot(named: "QA06 Goal deleted receipt after a double tap", to: self)
        XCTAssertEqual(try api.items(type: "goal_release", since: deleteSent).map(\.amountCents), [3_333], "a double tap must delete once")
        XCTAssertNil(try api.savedCents(goalID: goalID), "the goal still exists")
        qaTapDone(app)
        // No goals are left, so the Savings root shows its empty state (no summary).
        XCTAssertTrue(app.navigationBars["Savings"].waitForExistence(timeout: 15), "Done did not return to Savings")
        XCTAssertTrue(qaLabeled(app, "No goals yet").waitForExistence(timeout: 15), "Savings did not drop the deleted goal")

        // 6. The ledger from start to end, and Home's figures.
        let all = try api.items(since: started)
        XCTAssertEqual(all.map(\.amountCents).sorted(), [-4_567, -1_234, 1_234, 3_333, 12_345], "unexpected moves: \(all)")
        let wallet = try api.wallet()
        XCTAssertEqual(wallet.available, 11_111)
        XCTAssertEqual(wallet.total, 11_111)
        app.selectTab("Home")
        qaAssertHomeTotal(app, cents: 11_111)
        app.attachScreenshot(named: "QA07 Home after every move", to: self)
        XCTAssertTrue(homeCaughtUp, "after a pay-in Home still shows '\(homeAfterPayIn)' (the server says $111.11)")
        XCTAssertNil(noteAfterDoubleTap, "the review said '\(noteAfterDoubleTap ?? "")' while the move went through")
    }

    // MARK: - QA: amount entry edge cases (nothing is sent)

    /// The Add test money keypad on a fresh account: the decimal point, two
    /// decimals at most, a leading zero replaced, seven whole digits at most,
    /// the $0.01 minimum and the $1,000.00 maximum, presets; then Close sends
    /// nothing (the ledger stays empty).
    @MainActor
    func testQAAmountEntryEdgeCasesSendNothing() throws {
        let owner = try QAAPI.register(name: "QA Quinn Keypad")
        let api = try QAAPI.signIn(owner)
        addTeardownBlock { api.signOut() }
        let app = XCUIApplication.launchedClean()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10))
        let submit = app.buttons["home.addMoney.submit"]
        let display = qaLabeled(app, "Amount")
        XCTAssertEqual(display.value as? String, "empty")
        XCTAssertFalse(submit.isEnabled)

        // "." on empty gives "0."; zero can't be sent; a third decimal is refused.
        qaTapKeys(app, ["."], expect: "0.00 US dollars")
        XCTAssertFalse(submit.isEnabled, "$0. must not be sendable")
        qaTapKeys(app, ["0", "0"], expect: "0.00 US dollars")
        XCTAssertFalse(submit.isEnabled, "$0.00 must not be sendable")
        qaTapKeys(app, ["delete"], expect: "0.00 US dollars")
        qaTapKeys(app, ["5", "7"], expect: "0.05 US dollars")
        XCTAssertTrue(submit.isEnabled, "$0.05 is above the $0.01 minimum")
        qaTapKeys(app, ["delete", "delete", "delete", "delete"], expect: "empty")
        // The smallest amount.
        qaTapKeys(app, [".", "0", "1"], expect: "0.01 US dollars")
        XCTAssertTrue(submit.isEnabled, "$0.01 is the minimum and must be sendable")
        qaTapKeys(app, ["delete", "delete", "delete", "delete"], expect: "empty")
        // A leading zero is replaced, so a later "." still means dollars.
        qaTapKeys(app, ["0", "7", ".", "5"], expect: "7.50 US dollars")
        qaTapKeys(app, ["delete", "delete", "delete"], expect: "empty")
        // Seven whole digits at most; the eighth is refused.
        qaTapKeys(app, ["9", "9", "9", "9", "9", "9", "9", "9"], expect: "9,999,999.00 US dollars")
        XCTAssertTrue(app.staticTexts["You can add up to $1,000.00 of test money at a time."].waitForExistence(timeout: 3))
        XCTAssertFalse(submit.isEnabled)
        app.attachScreenshot(named: "QA10 Add test money above the maximum", to: self)
        qaTapKeys(app, Array(repeating: "delete", count: 7), expect: "empty")
        // One cent over the maximum, then the maximum.
        qaTapKeys(app, ["1", "0", "0", "0", ".", "0", "1"], expect: "1,000.01 US dollars")
        XCTAssertTrue(app.staticTexts["You can add up to $1,000.00 of test money at a time."].waitForExistence(timeout: 3))
        XCTAssertFalse(submit.isEnabled, "$1,000.01 must not be sendable")
        qaTapKeys(app, ["delete"], expect: "1,000.00 US dollars")
        XCTAssertTrue(submit.isEnabled, "$1,000.00 is the maximum and must be sendable")
        XCTAssertFalse(app.staticTexts["You can add up to $1,000.00 of test money at a time."].exists)
        // A preset replaces the typed amount.
        let preset = app.buttons.matching(NSPredicate(format: "label == %@", "50.00 US dollars")).firstMatch
        XCTAssertTrue(preset.exists, "no $50 preset")
        preset.tap()
        XCTAssertTrue(qaWaitFor(display, valueHasPrefix: "50.00 US dollars", timeout: 5), "the $50 preset shows \(display.value ?? "nil")")
        app.attachScreenshot(named: "QA11 Add test money after the $50 preset", to: self)

        // Close: nothing was sent.
        app.buttons["home.addMoney.close"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForNonExistence(timeout: 10))
        qaSettle(2)
        XCTAssertEqual(try api.items(since: Date.distantPast).count, 0, "closing Add test money must send nothing")
        XCTAssertEqual(try api.wallet().available, 0)
        qaAssertHomeTotal(app, cents: 0)
    }

    // MARK: - QA: app lock with a sheet open

    /// App lock relocks after a minute in the background (B1.3). The lock
    /// must cover everything, including a sheet that was open when the app
    /// left: here the Activity receipt, which shows an amount.
    @MainActor
    func testQAAppLockCoversASheetThatWasOpen() throws {
        guard UITestFaceID.directory != nil else {
            throw XCTSkip("needs Face ID: run through apps/ios/scripts/ui-test.sh")
        }
        let owner = try QAAPI.register(name: "QA Quinn Lock")
        let api = try QAAPI.signIn(owner)
        addTeardownBlock { api.signOut() }
        try api.deposit(cents: 4_321)

        let app = XCUIApplication.launchedClean()
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 30))
        app.buttons["Sign in"].tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap()
        email.typeText(owner.email)
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(owner.password)
        app.buttons["auth.signIn.submit"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        let turnOn = app.buttons["Turn on Face ID"]
        let offerDeadline = Date().addingTimeInterval(20)
        while !turnOn.exists && Date() < offerDeadline {
            let notNow = app.buttons["Not Now"]
            if notNow.exists && notNow.isHittable { notNow.tap() }
            qaSettle(0.5)
        }
        XCTAssertTrue(turnOn.exists, "no app lock offer after the first sign-in")
        turnOn.tap()
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(turnOn.waitForNonExistence(timeout: 20))
        app.dismissSignInPrompts()

        // Open the newest move's receipt from Home's Recent activity.
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.activity.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "no Recent activity row")
        qaScrollTo(app, row)
        row.tap()
        let receipt = app.descendants(matching: .any)["activity.receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 10), "the Activity receipt did not open")
        let receiptAmount = app.descendants(matching: .any)["activity.receipt.amount"]
        XCTAssertTrue(receiptAmount.waitForExistence(timeout: 5))
        XCTAssertEqual(receiptAmount.label, "plus 43.21 US dollars")
        app.attachScreenshot(named: "QA20 Activity receipt open before the background", to: self)

        // More than a minute in the background.
        XCUIDevice.shared.press(.home)
        qaSettle(65)
        app.activate()
        let locked = app.staticTexts["MoolaHub is locked"]
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "not locked after 65 seconds in the background")
        qaSettle(1.5)
        app.attachScreenshot(named: "QA21 Back after 65 s with the receipt open (automatic Face ID prompt)", to: self)
        let amountReachable = receiptAmount.exists && receiptAmount.isHittable
        let doneReachable = app.buttons.matching(identifier: "Done").allElementsBoundByIndex.contains { $0.exists && $0.isHittable }
        let unlockReachable = app.buttons["Unlock with Face ID"].exists && app.buttons["Unlock with Face ID"].isHittable

        // Unlock (the lock screen's automatic prompt) and leave the device setting off.
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(locked.waitForNonExistence(timeout: 20), "Face ID did not unlock")
        app.attachScreenshot(named: "QA22 After unlocking", to: self)
        if receipt.exists { qaTapDone(app) }
        app.selectTab("Account")
        app.buttons["account.row.security"].tap()
        let toggle = app.switches["account.security.appLock"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if (toggle.value as? String) == "1" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }

        XCTAssertFalse(amountReachable, "the receipt's amount is on screen and reachable while MoolaHub is locked")
        XCTAssertFalse(doneReachable, "the receipt's Done can be tapped while MoolaHub is locked")
        XCTAssertTrue(unlockReachable, "Unlock with Face ID is covered while MoolaHub is locked")
    }

    // MARK: - QA: the session ends while a money sheet is open

    /// The session is revoked elsewhere (a password change signs out every
    /// other session) while Add test money is open with an amount typed.
    /// Sending it gets the server's 401: the app must end the session, take
    /// the sheet away, show Sign in with the signed-out notice, and nothing
    /// may be added.
    @MainActor
    func testQASessionExpiryWithAMoneySheetOpenAddsNothing() throws {
        let owner = try QAAPI.register(name: "QA Quinn Expiry")
        let app = XCUIApplication.launchedClean()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10))
        qaTapKeys(app, ["2", "5"], expect: "25.00 US dollars")

        let other = try QAAPI.signIn(owner)
        let newPassword = owner.password + "-2"
        try other.changePassword(current: owner.password, new: newPassword)
        other.signOut()

        app.buttons["home.addMoney.submit"].tap()
        let notice = app.staticTexts["You've been signed out. Please sign in again."]
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "a 401 from a money sheet did not return to Sign in")
        XCTAssertFalse(app.staticTexts["Add test money"].exists, "the money sheet is still up over Sign in")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.attachScreenshot(named: "QA30 Signed out from Add test money", to: self)

        let fresh = try QAAPI.signIn(QAAccount(email: owner.email, username: owner.username, password: newPassword))
        defer { fresh.signOut() }
        XCTAssertEqual(try fresh.items(since: Date.distantPast).count, 0, "a refused deposit must add nothing")
        XCTAssertEqual(try fresh.wallet().available, 0)
    }

    // MARK: - QA: a fresh account's empty states, verbatim (W10.2)

    @MainActor
    func testQAFreshAccountShowsEveryEmptyStateVerbatim() throws {
        let owner = try QAAPI.register(name: "QA Quinn Empty")
        let app = XCUIApplication.launchedClean()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        XCTAssertTrue(qaLabeled(app, "Good to see you, QA").exists, "greeting with the first name")
        qaAssertHomeTotal(app, cents: 0)
        XCTAssertTrue(qaLabeled(app, "No goals yet. Create your first one.").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Create goal"].exists)
        XCTAssertTrue(qaLabeled(app, "No activity yet.").exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "home.group.")).firstMatch.exists)
        app.attachScreenshot(named: "QA40 Home empty", to: self)
        qaAssertNoEmoji(app, screen: "Home")

        // Move to goal with no goals: the Choose a goal empty state.
        app.buttons["Move to goal"].tap()
        XCTAssertTrue(qaLabeled(app, "Create a goal first, then move money into it.").waitForExistence(timeout: 15))
        XCTAssertTrue(qaLabeled(app, "No goals yet").exists)
        app.attachScreenshot(named: "QA41 Choose a goal empty", to: self)
        app.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(qaLabeled(app, "Create a goal first, then move money into it.").waitForNonExistence(timeout: 10))

        app.selectTab("Savings")
        XCTAssertTrue(qaLabeled(app, "Set a target and a date. We'll track your progress.").waitForExistence(timeout: 15))
        XCTAssertTrue(qaLabeled(app, "No goals yet").exists)
        XCTAssertTrue(app.buttons["Create goal"].exists)
        app.attachScreenshot(named: "QA42 Savings empty", to: self)
        qaAssertNoEmoji(app, screen: "Savings")

        app.selectTab("Groups")
        XCTAssertTrue(qaLabeled(app, "Save with people you trust. Everyone pays in each round.").waitForExistence(timeout: 15))
        XCTAssertTrue(qaLabeled(app, "No groups yet").exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Create group")).firstMatch.exists)
        app.attachScreenshot(named: "QA43 Groups empty", to: self)
        qaAssertNoEmoji(app, screen: "Groups")

        app.selectTab("Activity")
        XCTAssertTrue(qaLabeled(app, "Money you add, move and pay in shows up here.").waitForExistence(timeout: 15))
        XCTAssertTrue(qaLabeled(app, "No activity yet").exists)
        app.attachScreenshot(named: "QA44 Activity empty", to: self)
        qaAssertNoEmoji(app, screen: "Activity")
    }

    // MARK: - QA: sheets close, ask and block swipe-down where J0.1 says

    @MainActor
    func testQASheetsCloseAskAndBlockSwipeDownAsSpecified() throws {
        let owner = try QAAPI.register(name: "QA Quinn Sheets")
        let api = try QAAPI.signIn(owner)
        addTeardownBlock { api.signOut() }
        try api.deposit(cents: 10_000)
        let goalID = try api.createGoal(name: "QA Sheets \(Int(Date().timeIntervalSince1970) % 1_000_000)", targetCents: 20_000)
        let app = XCUIApplication.launchedClean()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))

        // Add test money closes at once on a swipe, even with an amount typed.
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10))
        qaTapKeys(app, ["5"], expect: "5.00 US dollars")
        qaSwipeSheetDown(app)
        XCTAssertTrue(app.staticTexts["Add test money"].waitForNonExistence(timeout: 5), "Add test money did not close on a swipe")

        // Move to goal from Home: past Choose a goal, swipe is blocked and Close asks.
        app.buttons["Move to goal"].tap()
        let choice = app.buttons["savings.choose.goal.\(goalID)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 15))
        choice.tap()
        XCTAssertTrue(app.buttons["savings.amount.continue"].waitForExistence(timeout: 10))
        qaSwipeSheetDown(app)
        XCTAssertTrue(app.buttons["savings.amount.continue"].exists, "swipe-down closed a step past the first one (ruling 23)")
        app.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(qaDialogButton(app, "Discard").waitForExistence(timeout: 5), "Close did not ask Discard this?")
        app.attachScreenshot(named: "QA50 Move to goal Discard this", to: self)
        // iOS 26 popovers drop the cancel button: tapping outside keeps editing (W10.7).
        let outside = app.otherElements["PopoverDismissRegion"]
        if outside.exists {
            outside.tap()
        } else {
            qaDialogButton(app, "Keep editing").tap()
        }
        qaSettle(1)
        XCTAssertTrue(app.buttons["savings.amount.continue"].waitForExistence(timeout: 5), "Keep editing closed the sheet")
        app.buttons["savings.sheet.close"].tap()
        qaDialogButton(app, "Discard").tap()
        XCTAssertTrue(app.buttons["savings.amount.continue"].waitForNonExistence(timeout: 10), "Discard did not close")

        // Create goal: closes at once while empty; after a name, swipe is blocked and Close asks.
        app.selectTab("Savings")
        let create = app.buttons["savings.createGoal"]
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        create.tap()
        XCTAssertTrue(qaLabeled(app, "Create a goal").waitForExistence(timeout: 10))
        let name = app.textFields["Goal name"]
        name.tap()
        name.typeText("QA Discard me")
        qaSwipeSheetDown(app)
        XCTAssertTrue(qaLabeled(app, "Create a goal").exists, "swipe-down closed Create goal after edits")
        app.buttons["savings.sheet.close"].tap()
        qaDialogButton(app, "Discard").tap()
        XCTAssertTrue(qaLabeled(app, "Create a goal").waitForNonExistence(timeout: 10))
        XCTAssertEqual(try api.goalNames().filter { $0 == "QA Discard me" }, [], "a discarded goal was created")

        // Create group: any edit asks (ruling 47).
        app.selectTab("Groups")
        let createGroup = app.buttons["groups.createButton"].exists ? app.buttons["groups.createButton"] : app.buttons["Create group"].firstMatch
        XCTAssertTrue(createGroup.waitForExistence(timeout: 15))
        createGroup.tap()
        let groupName = app.textFields["Name"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 10))
        groupName.tap()
        groupName.typeText("QA Discard group")
        qaSwipeSheetDown(app)
        XCTAssertTrue(groupName.exists, "swipe-down closed Create group after edits")
        app.buttons.matching(identifier: "Close").firstMatch.tap()
        qaDialogButton(app, "Discard").tap()
        XCTAssertTrue(groupName.waitForNonExistence(timeout: 10))

        // The Cash out info sheet's Done.
        app.selectTab("Home")
        app.buttons["Cash out"].tap()
        XCTAssertTrue(qaLabeled(app, "Cashing out isn't available yet. We'll let you know when it is.").waitForExistence(timeout: 10))
        qaTapDone(app)
        XCTAssertTrue(qaLabeled(app, "Cashing out isn't available yet. We'll let you know when it is.").waitForNonExistence(timeout: 10))
        XCTAssertEqual(try api.items(since: Date.distantPast).map(\.amountCents), [10_000], "a closed or discarded sheet moved money")
    }

    // MARK: - QA: pinned bars stay above the keyboard

    @MainActor
    func testQAPinnedButtonsStayAboveTheKeyboard() throws {
        let owner = try QAAPI.register(name: "QA Quinn Keyboard")
        let api = try QAAPI.signIn(owner)
        addTeardownBlock { api.signOut() }
        try api.deposit(cents: 5_000)
        let goalID = try api.createGoal(name: "QA Keys \(Int(Date().timeIntervalSince1970) % 1_000_000)", targetCents: 20_000)

        let app = XCUIApplication.launchedClean()
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 30))
        app.buttons["Sign in"].tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap()
        qaAssertAboveKeyboard(app, app.buttons["auth.signIn.submit"], "Sign in")
        app.terminate()

        let signedIn = XCUIApplication.launchedClean()
        signedIn.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(signedIn.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))

        // Create goal: the name field.
        signedIn.selectTab("Savings")
        signedIn.buttons["savings.createGoal"].tap()
        let name = signedIn.textFields["Goal name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap()
        qaAssertAboveKeyboard(signedIn, signedIn.buttons["savings.create.submit"], "Create goal")
        signedIn.buttons["savings.sheet.close"].tap()
        qaSettle(1)
        if qaDialogButton(signedIn, "Discard").exists { qaDialogButton(signedIn, "Discard").tap() }

        // Move to balance needs money in the goal: Delete goal's password field instead.
        let card = signedIn.buttons["savings.goalCard.\(goalID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        signedIn.buttons["savings.detail.more"].tap()
        qaLabeled(signedIn, "Delete goal", type: .button).tap()
        let password = signedIn.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        qaAssertAboveKeyboard(signedIn, signedIn.buttons["savings.delete.submit"], "Delete goal")
        signedIn.buttons["savings.sheet.close"].tap()
        XCTAssertTrue(password.waitForNonExistence(timeout: 10))

        // Create group: the name field.
        signedIn.selectTab("Groups")
        signedIn.buttons["groups.createButton"].tap()
        let groupName = signedIn.textFields["Name"]
        XCTAssertTrue(groupName.waitForExistence(timeout: 10))
        groupName.tap()
        qaAssertAboveKeyboard(signedIn, signedIn.buttons["groups.create.submit"], "Create group")
        signedIn.buttons.matching(identifier: "Close").firstMatch.tap()
    }

    // MARK: - QA: uncertain outcomes are never retried and point to Activity (J0.7, J0.8)

    /// Runs the app through a fault proxy (`apps/ios/scripts/fault-api-proxy.py`,
    /// started by ui-test.sh; TEST_RUNNER_MH_QA_FAULT_API is its base URL and
    /// TEST_RUNNER_MH_QA_FAULT_MODE_FILE the file this test writes the mode to).
    /// The proxy forwards each money POST, so the move happens, then drops the
    /// connection ("drop") or answers 200 with a body that is not JSON
    /// ("garble"). Every flow must show "We couldn't confirm this move. Check
    /// Activity before you try again." with "View activity", keep its main
    /// button disabled, and the ledger must hold exactly one move. Before
    /// that, GET /wallet answers as the server does when its balance read
    /// fails (availableCents 0, balanceUnavailable true): Move to goal and Pay
    /// in must not present $0.00 as the person's available money (J0.8). The
    /// read counts as failed: Move to goal shows "We couldn't load your
    /// balance" with "Try again" (B3.19) and Pay in its balance banner with
    /// the confirm disabled and no "Add money first" refusal (B4.25).
    @MainActor
    func testQAUncertainMoneyMovesAreNeverRetriedAndPointToActivity() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let faultAPI = environment["MH_QA_FAULT_API"], !faultAPI.isEmpty,
              let modeFile = environment["MH_QA_FAULT_MODE_FILE"], !modeFile.isEmpty
        else {
            throw XCTSkip("needs the QA fault proxy: set TEST_RUNNER_MH_QA_FAULT_API and TEST_RUNNER_MH_QA_FAULT_MODE_FILE")
        }
        guard UITestFaceID.directory != nil else {
            throw XCTSkip("needs Face ID: run through apps/ios/scripts/ui-test.sh")
        }
        let modeURL = URL(fileURLWithPath: modeFile)
        func setMode(_ mode: String) {
            XCTAssertNoThrow(try Data(mode.utf8).write(to: modeURL))
        }
        setMode("pass")
        addTeardownBlock { try? Data("pass".utf8).write(to: modeURL) }

        let owner = try QAAPI.register(name: "QA Quinn Fault")
        let partner = try QAAPI.register(name: "QA Quinn Fault Partner")
        let api = try QAAPI.signIn(owner)
        let partnerAPI = try QAAPI.signIn(partner)
        addTeardownBlock {
            api.signOut()
            partnerAPI.signOut()
        }
        let stamp = Int(Date().timeIntervalSince1970) % 1_000_000
        let goalName = "QA Fault \(stamp)"
        let groupName = "QA Fault pot \(stamp)"
        try api.deposit(cents: 10_000)
        let goalID = try api.createGoal(name: goalName, targetCents: 50_000)
        let groupID = try api.createSaveTogetherGroup(name: groupName, contributionCents: 1_234, invite: partner.email)
        try partnerAPI.acceptInvite(circleName: groupName)
        try api.startGroup(id: groupID)

        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state", "-dev.apiBaseURL", faultAPI]
        app.launch()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        qaAssertHomeTotal(app, cents: 10_000)
        let uncertain = "We couldn't confirm this move. Check Activity before you try again."
        var findings: [String] = []

        // A. The balance read failed: no $0.00 presented as a fact.
        setMode("wallet-unavailable")
        app.buttons["Move to goal"].tap()
        let choice = app.buttons["savings.choose.goal.\(goalID)"]
        XCTAssertTrue(choice.waitForExistence(timeout: 15))
        choice.tap()
        let balanceError = qaLabeled(app, "We couldn't load your balance")
        XCTAssertTrue(balanceError.waitForExistence(timeout: 15), "Move to goal did not treat the failed balance read as an error (B3.19)")
        XCTAssertTrue(app.buttons["Try again"].exists, "no Try again on the failed balance read")
        qaSettle(1)
        if app.staticTexts["Available $0.00"].exists { findings.append("Move to goal says 'Available $0.00' while the server says balanceUnavailable") }
        if app.buttons["savings.amount.continue"].exists {
            findings.append("Move to goal offers an amount step while the balance read failed")
        }
        app.attachScreenshot(named: "QA70 Move to goal while the balance read failed", to: self)
        app.buttons["savings.sheet.close"].tap()
        qaDialogButton(app, "Discard").tap()
        XCTAssertTrue(balanceError.waitForNonExistence(timeout: 10))
        app.selectTab("Groups")
        let groupCard = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "groups.card", groupName)).firstMatch
        XCTAssertTrue(groupCard.waitForExistence(timeout: 20))
        groupCard.tap()
        let payIn = app.buttons["groups.detail.payIn"]
        XCTAssertTrue(payIn.waitForExistence(timeout: 15))
        payIn.tap()
        XCTAssertTrue(app.buttons["groups.payIn.confirm"].waitForExistence(timeout: 10))
        qaSettle(3)
        if app.staticTexts["groups.payIn.insufficient"].exists {
            findings.append("Pay in says '\(app.staticTexts["groups.payIn.insufficient"].label)' while the server says balanceUnavailable")
        }
        if app.buttons["groups.payIn.addTestMoney"].exists {
            findings.append("Pay in offers Add test money while the balance read failed")
        }
        XCTAssertTrue(app.descendants(matching: .any)["groups.payIn.balanceError"].exists, "Pay in shows no balance error for the failed read")
        XCTAssertFalse(app.buttons["groups.payIn.confirm"].isEnabled, "Pay in can be confirmed while the balance read failed")
        app.attachScreenshot(named: "QA71 Pay in while the balance read failed", to: self)
        app.buttons.matching(identifier: "Close").firstMatch.tap()
        XCTAssertTrue(app.buttons["groups.payIn.confirm"].waitForNonExistence(timeout: 10))
        setMode("pass")

        // B. Add test money: sent, connection dropped.
        app.selectTab("Home")
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10))
        qaTapKeys(app, ["5"], expect: "5.00 US dollars")
        setMode("drop")
        let depositSent = Date()
        app.buttons["home.addMoney.submit"].tap()
        let depositBanner = qaLabeled(app, uncertain)
        let depositUncertain = depositBanner.waitForExistence(timeout: 30)
        setMode("pass")
        app.attachScreenshot(named: "QA72 Add test money, outcome unknown", to: self)
        XCTAssertTrue(depositUncertain, "Add test money: no uncertain-outcome banner after a dropped connection")
        XCTAssertFalse(app.buttons["home.addMoney.submit"].isEnabled, "Add test money can be sent again after an unknown outcome")
        qaSettle(3)
        XCTAssertEqual(try api.items(type: "deposit", since: depositSent).map(\.amountCents), [500], "the deposit was retried or lost")
        qaLabeled(app, "View activity", type: .button).tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForNonExistence(timeout: 10), "View activity did not close the sheet")
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected, "View activity did not open Activity")

        // C. Move to goal: Face ID, then the connection drops.
        app.selectTab("Home")
        app.buttons["Move to goal"].tap()
        XCTAssertTrue(choice.waitForExistence(timeout: 15))
        choice.tap()
        XCTAssertTrue(app.staticTexts["Available $105.00"].waitForExistence(timeout: 15), "available after the dropped deposit")
        qaTapKeys(app, ["1", ".", "2", "3"], expect: "1.23 US dollars")
        app.buttons["savings.amount.continue"].tap()
        let confirm = app.buttons["savings.review.confirm"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        setMode("drop")
        let allocateSent = Date()
        confirm.tap()
        UITestFaceID.answer("match", app: app)
        let allocateUncertain = qaLabeled(app, uncertain).waitForExistence(timeout: 30)
        setMode("pass")
        app.attachScreenshot(named: "QA73 Move to goal, outcome unknown", to: self)
        XCTAssertTrue(allocateUncertain, "Move to goal: no uncertain-outcome banner")
        XCTAssertFalse(confirm.isEnabled, "Move to goal can be confirmed again after an unknown outcome")
        XCTAssertFalse(app.buttons["Edit amount"].exists, "Edit amount offered after an unknown outcome")
        qaSettle(3)
        XCTAssertEqual(try api.items(type: "goal_allocate", since: allocateSent).map(\.amountCents), [-123], "the allocation was retried or lost")
        qaLabeled(app, "View activity", type: .button).tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected, "View activity did not open Activity")

        // D. Move to balance: step-up, then a 200 that can't be read.
        app.selectTab("Savings")
        let card = app.buttons["savings.goalCard.\(goalID)"]
        XCTAssertTrue(card.waitForExistence(timeout: 15))
        card.tap()
        XCTAssertTrue(qaWaitFor(app.descendants(matching: .any)["savings.detail.header"], valueHasPrefix: "1.23 US dollars saved"))
        app.buttons["savings.detail.moveToBalance"].tap()
        qaTapKeys(app, ["1"], expect: "1.00 US dollars")
        app.buttons["savings.amount.continue"].tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let password = app.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        password.tap()
        password.typeText(owner.password)
        let stepUp = app.buttons["savings.stepUp.submit"]
        XCTAssertTrue(qaWaitEnabled(stepUp, true))
        setMode("garble")
        let releaseSent = Date()
        stepUp.tap()
        let releaseUncertain = qaLabeled(app, uncertain).waitForExistence(timeout: 30)
        setMode("pass")
        app.attachScreenshot(named: "QA74 Move to balance, unreadable answer", to: self)
        XCTAssertTrue(releaseUncertain, "Move to balance: no uncertain-outcome banner for an unreadable 200")
        XCTAssertFalse(stepUp.isEnabled, "Move to balance can be sent again after an unknown outcome")
        qaSettle(3)
        XCTAssertEqual(try api.items(type: "goal_release", since: releaseSent).map(\.amountCents), [100], "the release was retried or lost")
        qaLabeled(app, "View activity", type: .button).tap()
        XCTAssertTrue(stepUp.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected, "View activity did not open Activity")

        // E. Pay in: Face ID, then the connection drops.
        app.selectTab("Groups")
        if !payIn.exists {
            XCTAssertTrue(groupCard.waitForExistence(timeout: 20))
            groupCard.tap()
        }
        XCTAssertTrue(payIn.waitForExistence(timeout: 15))
        payIn.tap()
        let payConfirm = app.buttons["groups.payIn.confirm"]
        XCTAssertTrue(qaWaitEnabled(payConfirm, true), "Pay in stayed disabled")
        setMode("drop")
        let payInSent = Date()
        payConfirm.tap()
        UITestFaceID.answer("match", app: app)
        let payInUncertain = qaLabeled(app, uncertain).waitForExistence(timeout: 30)
        setMode("pass")
        app.attachScreenshot(named: "QA75 Pay in, outcome unknown", to: self)
        XCTAssertTrue(payInUncertain, "Pay in: no uncertain-outcome banner")
        XCTAssertFalse(payConfirm.isEnabled, "Pay in can be confirmed again after an unknown outcome")
        qaSettle(3)
        XCTAssertEqual(try api.items(type: "contribution", since: payInSent).map(\.amountCents), [-1_234], "the pay-in was retried or lost")
        qaLabeled(app, "View activity", type: .button).tap()
        XCTAssertTrue(payConfirm.waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected, "View activity did not open Activity")

        // F. Delete goal: step-up, then the connection drops.
        app.selectTab("Savings")
        if !app.buttons["savings.detail.more"].exists {
            XCTAssertTrue(card.waitForExistence(timeout: 15))
            card.tap()
        }
        XCTAssertTrue(qaWaitFor(app.descendants(matching: .any)["savings.detail.header"], valueHasPrefix: "0.23 US dollars saved"), "goal after the release")
        app.buttons["savings.detail.more"].tap()
        qaLabeled(app, "Delete goal", type: .button).tap()
        let deletePassword = app.secureTextFields["Password"]
        XCTAssertTrue(deletePassword.waitForExistence(timeout: 10))
        deletePassword.tap()
        deletePassword.typeText(owner.password)
        let deleteSubmit = app.buttons["savings.delete.submit"]
        XCTAssertTrue(qaWaitEnabled(deleteSubmit, true))
        setMode("drop")
        let deleteSent = Date()
        deleteSubmit.tap()
        let deleteUncertain = qaLabeled(app, uncertain).waitForExistence(timeout: 30)
        setMode("pass")
        app.attachScreenshot(named: "QA76 Delete goal, outcome unknown", to: self)
        XCTAssertTrue(deleteUncertain, "Delete goal: no uncertain-outcome banner")
        XCTAssertFalse(deleteSubmit.isEnabled, "Delete goal can be sent again after an unknown outcome")
        qaSettle(3)
        XCTAssertEqual(try api.items(type: "goal_release", since: deleteSent).map(\.amountCents), [23], "the delete was retried or lost")
        XCTAssertNil(try api.savedCents(goalID: goalID))
        qaLabeled(app, "View activity", type: .button).tap()
        XCTAssertTrue(deleteSubmit.waitForNonExistence(timeout: 10))

        // Home caught up (J0.7: Home is told to refresh): $105.00 − $12.34 pay-in.
        app.selectTab("Home")
        qaAssertHomeTotal(app, cents: 10_500 - 1_234)
        app.attachScreenshot(named: "QA77 Home after the unknown outcomes", to: self)
        XCTAssertEqual(findings, [], "the balance read failed and the app presented $0.00 as a fact")
    }

    // MARK: - QA: a gateway 5xx after the move landed is not "your money hasn't moved"

    /// Through the QA fault proxy (see the test above), the deposit reaches
    /// the server and lands, then a gateway answers 504 (what a load balancer
    /// in front of the API does when the app server answers too late). The
    /// app can't know the move failed, so it must not say "Your money hasn't
    /// moved" nor invite a second attempt: it is an unknown outcome (J0.7).
    @MainActor
    func testQAGatewayTimeoutAfterTheMoveLandedIsNotReportedAsNothingMoved() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let faultAPI = environment["MH_QA_FAULT_API"], !faultAPI.isEmpty,
              let modeFile = environment["MH_QA_FAULT_MODE_FILE"], !modeFile.isEmpty
        else {
            throw XCTSkip("needs the QA fault proxy: set TEST_RUNNER_MH_QA_FAULT_API and TEST_RUNNER_MH_QA_FAULT_MODE_FILE")
        }
        let modeURL = URL(fileURLWithPath: modeFile)
        XCTAssertNoThrow(try Data("pass".utf8).write(to: modeURL))
        addTeardownBlock { try? Data("pass".utf8).write(to: modeURL) }
        let owner = try QAAPI.register(name: "QA Quinn Gateway")
        let api = try QAAPI.signIn(owner)
        addTeardownBlock { api.signOut() }

        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state", "-dev.apiBaseURL", faultAPI]
        app.launch()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        app.buttons["Add money"].tap()
        XCTAssertTrue(app.staticTexts["Add test money"].waitForExistence(timeout: 10))
        qaTapKeys(app, ["7"], expect: "7.00 US dollars")
        XCTAssertNoThrow(try Data("gateway-timeout".utf8).write(to: modeURL))
        let sent = Date()
        let submit = app.buttons["home.addMoney.submit"]
        submit.tap()
        let serverError = qaLabeled(app, "Something went wrong on our side. Your money hasn't moved. Please try again in a minute.")
        let uncertain = qaLabeled(app, "We couldn't confirm this move. Check Activity before you try again.")
        let deadline = Date().addingTimeInterval(30)
        while !serverError.exists && !uncertain.exists && Date() < deadline { qaSettle(0.5) }
        XCTAssertNoThrow(try Data("pass".utf8).write(to: modeURL))
        app.attachScreenshot(named: "QA80 Add test money after a gateway 504 (the deposit landed)", to: self)
        let saidNothingMoved = serverError.exists
        let canSendAgain = submit.isEnabled
        qaSettle(2)
        XCTAssertEqual(try api.items(type: "deposit", since: sent).map(\.amountCents), [700], "the deposit should have landed exactly once")
        XCTAssertFalse(saidNothingMoved, "the app said 'Your money hasn't moved' while $7.00 had landed")
        XCTAssertFalse(canSendAgain, "Add test money can be sent again after a gateway 5xx whose outcome is unknown")
        XCTAssertTrue(uncertain.exists, "no 'We couldn't confirm this move' with View activity after a gateway 5xx")
    }

    // MARK: - QA: "View activity" from Add test money opened on top of Pay in

    /// Pay in with too little money offers "Add test money", which opens on
    /// top of Pay in (J5, A9.3). When that deposit's outcome is unknown (the
    /// QA fault proxy drops the connection after the deposit lands), "View
    /// activity" must close the sheets and show Activity (J0.7), not leave
    /// Pay in covering it.
    @MainActor
    func testQAViewActivityFromAddTestMoneyOverPayInShowsActivity() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let faultAPI = environment["MH_QA_FAULT_API"], !faultAPI.isEmpty,
              let modeFile = environment["MH_QA_FAULT_MODE_FILE"], !modeFile.isEmpty
        else {
            throw XCTSkip("needs the QA fault proxy: set TEST_RUNNER_MH_QA_FAULT_API and TEST_RUNNER_MH_QA_FAULT_MODE_FILE")
        }
        let modeURL = URL(fileURLWithPath: modeFile)
        XCTAssertNoThrow(try Data("pass".utf8).write(to: modeURL))
        addTeardownBlock { try? Data("pass".utf8).write(to: modeURL) }
        let owner = try QAAPI.register(name: "QA Quinn Nested")
        let partner = try QAAPI.register(name: "QA Quinn Nested Partner")
        let api = try QAAPI.signIn(owner)
        let partnerAPI = try QAAPI.signIn(partner)
        addTeardownBlock {
            api.signOut()
            partnerAPI.signOut()
        }
        let groupName = "QA Nested pot \(Int(Date().timeIntervalSince1970) % 1_000_000)"
        let groupID = try api.createSaveTogetherGroup(name: groupName, contributionCents: 1_234, invite: partner.email)
        try partnerAPI.acceptInvite(circleName: groupName)
        try api.startGroup(id: groupID)

        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state", "-dev.apiBaseURL", faultAPI]
        app.launch()
        app.signIn(email: owner.email, password: owner.password)
        XCTAssertTrue(app.descendants(matching: .any)["home.greeting"].waitForExistence(timeout: 20))
        app.selectTab("Groups")
        let groupCard = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@", "groups.card", groupName)).firstMatch
        XCTAssertTrue(groupCard.waitForExistence(timeout: 20))
        groupCard.tap()
        let payIn = app.buttons["groups.detail.payIn"]
        XCTAssertTrue(payIn.waitForExistence(timeout: 15))
        payIn.tap()
        let addTestMoney = app.buttons["groups.payIn.addTestMoney"]
        XCTAssertTrue(addTestMoney.waitForExistence(timeout: 15), "no Add test money on Pay in with a $0.00 balance")
        addTestMoney.tap()
        XCTAssertTrue(app.buttons["home.addMoney.submit"].waitForExistence(timeout: 10))
        qaTapKeys(app, ["5"], expect: "5.00 US dollars")
        XCTAssertNoThrow(try Data("drop".utf8).write(to: modeURL))
        let sent = Date()
        app.buttons["home.addMoney.submit"].tap()
        let uncertain = qaLabeled(app, "We couldn't confirm this move. Check Activity before you try again.")
        let sawUncertain = uncertain.waitForExistence(timeout: 30)
        XCTAssertNoThrow(try Data("pass".utf8).write(to: modeURL))
        XCTAssertTrue(sawUncertain, "no uncertain-outcome banner")
        qaLabeled(app, "View activity", type: .button).tap()
        qaSettle(3)
        app.attachScreenshot(named: "QA90 After View activity from Add test money over Pay in", to: self)
        XCTAssertEqual(try api.items(type: "deposit", since: sent).map(\.amountCents), [500])
        XCTAssertTrue(app.tabBars.buttons["Activity"].isSelected, "View activity did not select Activity")
        XCTAssertFalse(app.buttons["groups.payIn.confirm"].exists, "Pay in is still on screen over Activity after View activity")
    }
}

// MARK: - QA helpers (private to this file)

private extension QAExploratoryUITests {
    @MainActor
    func qaLabeled(_ app: XCUIApplication, _ label: String, type: XCUIElement.ElementType = .any) -> XCUIElement {
        app.descendants(matching: type).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// A review or receipt row ("Fee, No fee"): starts with its label and contains its value.
    @MainActor
    func qaRow(_ app: XCUIApplication, _ title: String, _ value: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", title, value))
            .firstMatch
    }

    @MainActor
    func qaSettle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Taps keypad keys one at a time ("." is "decimal point"), then checks
    /// the amount display's VoiceOver value.
    @MainActor
    func qaTapKeys(_ app: XCUIApplication, _ keys: [String], expect: String, file: StaticString = #filePath, line: UInt = #line) {
        for key in keys {
            let name = key == "." ? "decimal point" : key
            let button = qaLabeled(app, name, type: .button)
            XCTAssertTrue(button.waitForExistence(timeout: 5), "keypad key \(name) missing", file: file, line: line)
            button.tap()
            qaSettle(0.4)
        }
        let display = qaLabeled(app, "Amount")
        XCTAssertTrue(qaWaitFor(display, valueHasPrefix: expect, timeout: 5), "amount shows \(display.value ?? "nil"), expected \(expect)", file: file, line: line)
    }

    @MainActor
    func qaWaitFor(_ element: XCUIElement, valueHasPrefix prefix: String, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists, let value = element.value as? String, value.hasPrefix(prefix) { return true }
            qaSettle(0.3)
        } while Date() < deadline
        return false
    }

    @MainActor
    func qaWaitEnabled(_ element: XCUIElement, _ enabled: Bool, timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if element.exists && element.isEnabled == enabled { return true }
            qaSettle(0.3)
        } while Date() < deadline
        return false
    }

    /// The receipt's or info sheet's primary "Done" (no identifier, J0.6).
    @MainActor
    func qaTapDone(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let done = app.buttons.matching(identifier: "Done").allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                done.tap()
                return
            }
            qaSettle(0.3)
        }
        XCTFail("no hittable Done", file: file, line: line)
    }

    /// Home's "Total balance" carries the figures in its VoiceOver value
    /// ("1,234.56 US dollars. Available …").
    @MainActor
    func qaAssertHomeTotal(_ app: XCUIApplication, cents: Int, file: StaticString = #filePath, line: UInt = #line) {
        let card = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND value CONTAINS %@", "Total balance", "US dollars")).firstMatch
        let expected = Self.qaSpoken(cents)
        XCTAssertTrue(qaWaitFor(card, valueHasPrefix: expected, timeout: 20), "Home total is \(card.value ?? "nil"), expected \(expected)", file: file, line: line)
    }

    static func qaSpoken(_ cents: Int) -> String {
        let style = Decimal.FormatStyle.Currency(code: "USD", locale: Locale(identifier: "en_US"))
            .precision(.fractionLength(2))
            .presentation(.fullName)
        return (Decimal(cents.magnitude) / 100).formatted(style)
    }

    @MainActor
    func qaScrollTo(_ app: XCUIApplication, _ element: XCUIElement, maxSwipes: Int = 8) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            app.swipeUp()
            swipes += 1
        }
    }

    /// Drags a large sheet down from just under its top edge.
    @MainActor
    func qaSwipeSheetDown(_ app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end)
        qaSettle(1.5)
    }

    /// A button of a system confirmation dialog (an iOS 26 popover or an action sheet).
    @MainActor
    func qaDialogButton(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let inSheet = app.sheets.buttons[label]
        if inSheet.waitForExistence(timeout: 3) { return inSheet }
        let candidates = app.buttons.matching(identifier: label).allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        return candidates.last ?? app.buttons[label]
    }

    /// The main button is fully above the keyboard and can be tapped.
    @MainActor
    func qaAssertAboveKeyboard(_ app: XCUIApplication, _ button: XCUIElement, _ screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        guard keyboard.waitForExistence(timeout: 5) else {
            app.attachScreenshot(named: "QA \(screen) no software keyboard", to: self)
            XCTFail("\(screen): no software keyboard to measure against", file: file, line: line)
            return
        }
        qaSettle(1)
        XCTAssertTrue(button.exists, "\(screen): main button missing", file: file, line: line)
        app.attachScreenshot(named: "QA60 \(screen) with the keyboard up", to: self)
        XCTAssertLessThanOrEqual(button.frame.maxY, keyboard.frame.minY + 0.5,
                                 "\(screen): the main button (\(button.frame)) is under the keyboard (\(keyboard.frame))", file: file, line: line)
        XCTAssertTrue(button.isHittable, "\(screen): the main button can't be tapped with the keyboard up", file: file, line: line)
    }

    /// No visible text or button label on this screen contains an emoji
    /// (founder decision 2: emoji only as goal identity art).
    @MainActor
    func qaAssertNoEmoji(_ app: XCUIApplication, screen: String, file: StaticString = #filePath, line: UInt = #line) {
        let labels = (app.staticTexts.allElementsBoundByIndex + app.buttons.allElementsBoundByIndex).map(\.label)
        let offending = labels.filter { label in
            let scalars = Array(label.unicodeScalars)
            return scalars.indices.contains { index in
                let scalar = scalars[index]
                if scalar.properties.isEmojiPresentation || scalar.value == 0x20E3 { return true }
                let next = index + 1 < scalars.count ? scalars[index + 1].value : 0
                return !scalar.isASCII && scalar.properties.isEmoji && next == 0xFE0F
            }
        }
        XCTAssertTrue(offending.isEmpty, "\(screen) shows emoji in: \(offending)", file: file, line: line)
    }
}

// MARK: - QA backend calls (setup and ledger checks; never through the app)

private struct QAAccount: Sendable {
    let email: String
    let username: String
    let password: String
}

private struct QAItem: Sendable, CustomStringConvertible {
    let id: String
    let type: String
    let amountCents: Int
    let status: String
    let createdAt: Date

    var description: String { "\(type) \(amountCents) \(status)" }
}

private struct QAFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Direct calls to the dev API with the QA account's own session. Nothing is
/// logged; passwords and tokens never leave this type; money requests are
/// sent once.
private final class QAAPI: Sendable {
    private static let base = "http://localhost:8787/api"
    private let token: String

    private init(token: String) {
        self.token = token
    }

    /// Registers and verifies a fresh account "q<time><nnn>@moolahub.test"
    /// with a generated password (QA's own first letter in the backend log).
    static func register(name: String) throws -> QAAccount {
        let handle = "q\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        let account = QAAccount(
            email: "\(handle)@moolahub.test",
            username: handle,
            password: "QaQuinn-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        )
        let mark = try UITestBackendLog.mark()
        let register = try JSONSerialization.data(withJSONObject: [
            "name": name, "username": account.username, "email": account.email,
            "password": account.password, "dateOfBirth": "1990-01-15",
        ])
        let (registerStatus, _) = try request("POST", "/auth/register", body: register, token: nil)
        guard registerStatus == 200 || registerStatus == 201 else { throw QAFailure("register returned HTTP \(registerStatus)") }
        let code = try UITestBackendLog.code(.verification, emailInitial: "q", after: mark)
        let verify = try JSONSerialization.data(withJSONObject: ["email": account.email, "code": code])
        let (verifyStatus, json) = try request("POST", "/auth/verify-email", body: verify, token: nil)
        guard verifyStatus == 200, let token = (json as? [String: Any])?["sessionToken"] as? String else {
            throw QAFailure("verify-email returned HTTP \(verifyStatus)")
        }
        QAAPI(token: token).signOut()
        return account
    }

    static func signIn(_ account: QAAccount) throws -> QAAPI {
        let body = try JSONSerialization.data(withJSONObject: ["email": account.email, "password": account.password])
        let (status, json) = try request("POST", "/auth/login", body: body, token: nil)
        guard status == 200, let token = (json as? [String: Any])?["sessionToken"] as? String else {
            throw QAFailure("login returned HTTP \(status)")
        }
        return QAAPI(token: token)
    }

    func signOut() {
        _ = try? Self.request("POST", "/auth/logout", body: nil, token: token)
    }

    func deposit(cents: Int) throws {
        let body = try JSONSerialization.data(withJSONObject: ["amountCents": cents])
        let (status, _) = try Self.request("POST", "/wallet/deposit", body: body, token: token)
        guard status == 200 else { throw QAFailure("deposit returned HTTP \(status)") }
    }

    func createGoal(name: String, targetCents: Int) throws -> String {
        let deadline = Calendar(identifier: .gregorian).date(byAdding: .month, value: 8, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "emoji": "\u{1F3AF}", "color": "jade", "targetCents": targetCents,
            "deadline": formatter.string(from: deadline), "frequency": "weekly",
        ])
        let (status, json) = try Self.request("POST", "/goals", body: body, token: token)
        guard status == 201 || status == 200, let id = (json as? [String: Any])?["id"] as? String else {
            throw QAFailure("create goal returned HTTP \(status)")
        }
        return id
    }

    /// The goal's saved cents, or nil when the goal no longer exists.
    func savedCents(goalID: String) throws -> Int? {
        let (status, json) = try Self.request("GET", "/goals/\(goalID)", body: nil, token: token)
        if status == 404 { return nil }
        guard status == 200, let saved = (json as? [String: Any])?["savedCents"] as? Int else {
            throw QAFailure("GET goal returned HTTP \(status)")
        }
        return saved
    }

    func goalNames() throws -> [String] {
        let (status, json) = try Self.request("GET", "/goals", body: nil, token: token)
        guard status == 200, let list = json as? [[String: Any]] else { throw QAFailure("GET /goals returned HTTP \(status)") }
        return list.compactMap { $0["name"] as? String }
    }

    func wallet() throws -> (available: Int, total: Int) {
        let (status, json) = try Self.request("GET", "/wallet", body: nil, token: token)
        guard status == 200, let object = json as? [String: Any],
              let available = object["availableCents"] as? Int, let total = object["totalCents"] as? Int
        else { throw QAFailure("GET /wallet returned HTTP \(status)") }
        return (available, total)
    }

    /// Every Activity item (of `type`, when given) created no earlier than
    /// 5 seconds before `since`, oldest first.
    func items(type: String? = nil, since: Date) throws -> [QAItem] {
        let (status, json) = try Self.request("GET", "/activity?limit=100", body: nil, token: token)
        guard status == 200, let list = json as? [[String: Any]] else { throw QAFailure("GET /activity returned HTTP \(status)") }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let cutoff = since == .distantPast ? since : since.addingTimeInterval(-5)
        return list.compactMap { item -> QAItem? in
            guard let id = item["id"] as? String, let itemType = item["type"] as? String,
                  let amount = item["amountCents"] as? Int,
                  let created = (item["createdAt"] as? String).flatMap(parser.date(from:))
            else { return nil }
            return QAItem(id: id, type: itemType, amountCents: amount, status: item["onchainStatus"] as? String ?? "", createdAt: created)
        }
        .filter { (type == nil || $0.type == type) && $0.createdAt >= cutoff }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// A "Save together" group of two rounds that invites `invite`.
    func createSaveTogetherGroup(name: String, contributionCents: Int, invite: String) throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name, "type": "accumulation", "contributionCents": contributionCents,
            "numRounds": 2, "frequency": "weekly", "memberEmails": [invite],
        ])
        let (status, json) = try Self.request("POST", "/circles", body: body, token: token)
        guard status == 201 || status == 200, let id = (json as? [String: Any])?["id"] as? String else {
            throw QAFailure("create group returned HTTP \(status)")
        }
        return id
    }

    func acceptInvite(circleName: String) throws {
        let (status, json) = try Self.request("GET", "/circles/invites", body: nil, token: token)
        guard status == 200, let list = json as? [[String: Any]],
              let id = list.first(where: { ($0["circleName"] as? String) == circleName })?["id"] as? String
        else { throw QAFailure("no invite to \(circleName) (HTTP \(status))") }
        let (acceptStatus, _) = try Self.request("POST", "/circles/invites/\(id)/accept", body: nil, token: token)
        guard acceptStatus == 200 else { throw QAFailure("accept returned HTTP \(acceptStatus)") }
    }

    func startGroup(id: String) throws {
        let (status, _) = try Self.request("POST", "/circles/\(id)/start", body: nil, token: token)
        guard status == 200 else { throw QAFailure("start returned HTTP \(status)") }
    }

    func changePassword(current: String, new: String) throws {
        let body = try JSONSerialization.data(withJSONObject: ["currentPassword": current, "newPassword": new])
        let (status, _) = try Self.request("POST", "/auth/password", body: body, token: token)
        guard status == 200 else { throw QAFailure("change password returned HTTP \(status)") }
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
        guard let url = URL(string: base + path) else { throw QAFailure("bad path \(path)") }
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
