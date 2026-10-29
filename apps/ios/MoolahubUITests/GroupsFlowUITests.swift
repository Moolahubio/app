import XCTest

/// End-to-end UI tests for the Groups feature, run against the local dev backend.
/// Owned by the Groups engineer. Keep helpers `private` so they never collide
/// with another feature's test file.
///
/// Seeded data these tests rely on (artifacts/api-server/scripts/seed-ios-dev.ts):
/// demo (@ama) is in "Family susu" (take turns, round 3 of 4) and "Holiday pot"
/// (save together, round 4 of 6), and has a pending "Wedding fund" invite from
/// Esi. The tests never pay into, leave, accept or decline those. Everything
/// they create is named "QA …".
///
/// Every test is synchronous so `continueAfterFailure = false` stops it at the
/// first failure (an async test keeps going, which is unsafe around money moves).
///
/// Dark mode: `testGroupsListAndDetailInDarkMode` needs the simulator in dark
/// appearance (`xcrun simctl ui '<sim>' appearance dark`); it skips otherwise.
///
/// Face ID: on a device without a passcode the pay-in confirm needs no device
/// gate. The iOS 26.5 simulator reports a passcode, so the pay-in shows the
/// system prompt: `apps/ios/scripts/ui-test.sh` enrolls Face ID for the run and
/// its host helper posts one match per request (`UITestFaceID`).
final class GroupsFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Seeded list and detail (read only)

    @MainActor
    func testListShowsSeededGroupsInviteAndFamilySusuDetail() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.groupsSignIn(password: password)
        app.groupsOpenTab()

        // Invitations section with the seeded Wedding fund invite.
        app.groupsRequire(app.staticTexts["Invitations (1)"], "Invitations (1) header")
        let wedding = app.groupsAny("groups.invite.Wedding fund")
        app.groupsRequire(wedding, "Wedding fund invite card")
        XCTAssertTrue(wedding.buttons["Accept"].exists)
        XCTAssertTrue(wedding.buttons["Decline"].exists)
        XCTAssertTrue(wedding.staticTexts["esi invited you"].exists)
        XCTAssertTrue(wedding.staticTexts["25.00 US dollars weekly"].exists)

        // Your groups: both seeded groups.
        app.groupsRequire(app.staticTexts["Your groups"], "Your groups header")
        let family = app.groupsCard(named: "Family susu")
        app.groupsRequire(family, "Family susu card")
        XCTAssertTrue(family.label.contains("Take turns, Monthly. Active."), family.label)
        XCTAssertTrue(family.label.contains("Each round 100.00 US dollars"), family.label)
        XCTAssertTrue(family.label.contains("Your payout 400.00 US dollars"), family.label)
        XCTAssertTrue(family.label.contains("Round 3 of 4 \u{00B7} Your turn: round 4"), family.label)
        let holiday = app.groupsCard(named: "Holiday pot")
        app.groupsRequire(holiday, "Holiday pot card")
        XCTAssertTrue(holiday.label.contains("Save together, Monthly. Active."), holiday.label)
        XCTAssertTrue(holiday.label.contains("You get back 300.00 US dollars"), holiday.label)
        XCTAssertTrue(holiday.label.contains("Round 4 of 6"), holiday.label)
        app.attachScreenshot(named: "Groups list", to: self)

        // How groups work.
        let explainer = app.buttons["groups.howItWorks"]
        app.groupsScrollTo(explainer)
        app.attachScreenshot(named: "Groups list bottom", to: self)
        explainer.tap()
        app.groupsRequire(app.staticTexts["How groups work"], "How groups work sheet")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "A group is a savings circle, sometimes called a Susu.")).firstMatch.exists)
        app.attachScreenshot(named: "How groups work", to: self)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForNonExistence(timeout: 5), "How groups work sheet should close")

        // Family susu detail: round 3 of 4, members, payout order.
        app.groupsScrollTo(app.groupsCard(named: "Family susu"), up: true)
        app.groupsCard(named: "Family susu").tap()
        app.groupsRequire(app.groupsAny("groups.detail.round"), "Round fact")
        XCTAssertTrue(app.navigationBars["Family susu"].exists)
        XCTAssertTrue(app.groupsAny("groups.detail.round").label.contains("3 of 4"), app.groupsAny("groups.detail.round").label)
        let payout = app.groupsAny("groups.detail.payout").label
        XCTAssertTrue(payout.contains("Payout each round") && payout.contains("400.00 US dollars"), payout)
        // Demo's round 3 pay-in is due in the seed; another engineer may have paid it.
        let payIn = app.buttons["groups.detail.payIn"]
        let paidIn = app.groupsAny("groups.detail.paidIn")
        XCTAssertTrue(payIn.exists || paidIn.exists, "neither Pay in nor Paid in this round is shown")
        if payIn.exists {
            XCTAssertEqual(payIn.label, "Pay in $100.00")
        }
        XCTAssertFalse(app.buttons["groups.detail.menu"].exists, "an active group can't be deleted")
        app.attachScreenshot(named: "Family susu detail", to: self)

        let order = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Round 4, @ama, Up next")).firstMatch
        app.groupsScrollTo(order)
        XCTAssertTrue(app.staticTexts["Payout order"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Round 1, @kofi, Received")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Round 3, @yaw, Receiving now")).firstMatch.exists)
        XCTAssertTrue(order.label.contains("Up next"), order.label)
        app.attachScreenshot(named: "Family susu payout order", to: self)

        let you = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "@ama, you.")).firstMatch
        app.groupsScrollTo(you)
        XCTAssertTrue(you.label.contains("Payout in round 4"), you.label)
        let kofi = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "@kofi.")).firstMatch
        XCTAssertTrue(kofi.label.contains("Received payout") && kofi.label.contains("Paid in"), kofi.label)
        XCTAssertTrue(app.staticTexts["Members (4)"].exists)
        app.attachScreenshot(named: "Family susu members", to: self)
        app.groupsScrollTo(app.staticTexts["Your pay-ins"])
        app.groupsScrollTo(app.groupsPayInRow(round: 2, amount: "100.00 US dollars"))
        app.attachScreenshot(named: "Family susu pay-ins", to: self)

        // Holiday pot detail: save-together progress.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let holidayCard = app.groupsCard(named: "Holiday pot")
        app.groupsScrollTo(holidayCard)
        holidayCard.tap()
        app.groupsRequire(app.groupsAny("groups.detail.round"), "Holiday pot detail")
        XCTAssertTrue(app.groupsAny("groups.detail.payout").label.contains("You get back"), app.groupsAny("groups.detail.payout").label)
        XCTAssertTrue(app.groupsAny("groups.detail.round").label.contains("4 of 6"), app.groupsAny("groups.detail.round").label)
        XCTAssertFalse(app.staticTexts["Payout order"].exists, "save together has no payout order")
        app.attachScreenshot(named: "Holiday pot detail", to: self)
        app.groupsScrollTo(app.staticTexts["Everyone gets their own savings back after round 6."])
        XCTAssertTrue(app.staticTexts["Progress"].exists)
        app.attachScreenshot(named: "Holiday pot progress", to: self)
    }

    // MARK: - Appearance: the largest text size and dark mode

    @MainActor
    func testGroupsListAndDetailAtLargestTextSize() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.groupsSignIn(password: password)
        app.terminate()

        // Largest accessibility size (the relaunch keeps the session).
        let large = XCUIApplication()
        large.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        large.launch()
        large.groupsOpenTab()
        large.groupsRequire(large.groupsAny("groups.invite.Wedding fund"), "Wedding fund invite at AX5")
        large.attachScreenshot(named: "Groups list AX5", to: self)
        let family = large.groupsCard(named: "Family susu")
        large.groupsScrollTo(family)
        large.attachScreenshot(named: "Groups list AX5 cards", to: self)
        family.tap()
        large.groupsRequire(large.groupsAny("groups.detail.payout"), "detail at AX5")
        large.attachScreenshot(named: "Family susu detail AX5", to: self)
        large.groupsScrollTo(large.groupsAny("groups.detail.round"))
        large.attachScreenshot(named: "Family susu detail AX5 facts", to: self)
        large.terminate()
    }

    @MainActor
    func testGroupsListAndDetailInDarkMode() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.groupsSignIn(password: password)
        app.groupsOpenTab()
        app.groupsRequire(app.groupsCard(named: "Family susu"), "Family susu card")
        guard let luminance = app.groupsCanvasLuminance(), luminance < 0.3 else {
            throw XCTSkip("The simulator is in light appearance. Run `xcrun simctl ui '<sim>' appearance dark`, then this test alone.")
        }
        app.attachScreenshot(named: "Groups list dark", to: self)
        app.groupsScrollTo(app.groupsCard(named: "Holiday pot"))
        app.attachScreenshot(named: "Groups list dark cards", to: self)
        app.groupsCard(named: "Family susu").tap()
        app.groupsRequire(app.groupsAny("groups.detail.round"), "detail in dark mode")
        app.attachScreenshot(named: "Family susu detail dark", to: self)
        let order = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Round 4, @ama, Up next")).firstMatch
        app.groupsScrollTo(order)
        app.attachScreenshot(named: "Family susu payout order dark", to: self)
    }

    // MARK: - Create group: validation (creates nothing)

    @MainActor
    func testCreateGroupValidation() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.groupsSignIn(password: password)
        app.groupsOpenTab()
        app.buttons["groups.createButton"].tap()

        let submit = app.buttons["groups.create.submit"]
        app.groupsRequire(submit, "Create group sheet")
        XCTAssertTrue(app.staticTexts["Create group"].exists)
        XCTAssertFalse(submit.isEnabled, "Create group must start disabled")
        app.attachScreenshot(named: "Create group empty", to: self)

        let name = app.textFields["Name"]
        app.groupsType("QA Validation", into: name)
        name.typeText("\n")

        // Below the minimum. The keypad sits below the fold (and is lazy).
        app.groupsScrollTo(app.buttons["0"])
        app.buttons["0"].tap()
        app.buttons["decimal point"].tap()
        app.buttons["5"].tap()
        app.groupsRequire(app.staticTexts["Enter at least $1.00."], "minimum message")
        XCTAssertFalse(submit.isEnabled)
        app.attachScreenshot(named: "Create group below minimum", to: self)

        // Above the maximum. (Single taps on delete: after a long-press clear
        // the next preset tap was sometimes ignored on the loaded simulator.)
        app.groupsTapDelete(times: 3)
        for key in ["1", "0", "0", "0", "1"] { app.buttons[key].tap() }
        app.groupsRequire(app.staticTexts["Enter at most $10,000.00."], "maximum message")
        XCTAssertFalse(submit.isEnabled)

        // A preset makes it valid; the summary uses the people count.
        app.groupsTapDelete(times: 5)
        XCTAssertEqual(app.groupsAny("Amount").value as? String, "empty")
        app.groupsScrollTo(app.buttons["20.00 US dollars"], up: true)
        app.buttons["20.00 US dollars"].tap()
        XCTAssertEqual(app.groupsAny("Amount").value as? String, "20.00 US dollars")
        let summary = app.staticTexts["groups.create.summary"]
        app.groupsScrollTo(summary)
        XCTAssertEqual(
            summary.label,
            "Each round, everyone pays in $20 plus a small fee. One person receives $100. There are 5 rounds, so everyone gets one payout. The group starts automatically when everyone has joined."
        )
        XCTAssertTrue(submit.isEnabled)
        app.attachScreenshot(named: "Create group take turns summary", to: self)

        // Three people allow two invitations; a third is over the limit.
        let people = app.groupsStepperButton("groups.create.people", increment: false)
        people.tap()
        people.tap()
        XCTAssertTrue(app.staticTexts["groups.create.summary"].label.contains("One person receives $60. There are 3 rounds"), app.staticTexts["groups.create.summary"].label)

        let email = app.textFields["Invite by email \u{00B7} optional"]
        app.groupsScrollTo(email)
        app.groupsType("not-an-email", into: email)
        app.buttons["groups.create.addEmail"].tap()
        app.groupsRequire(app.staticTexts["Please enter a valid email address."], "invalid email message")
        for address in ["esi@moolahub.test", "abena@moolahub.test", "yaw@moolahub.test"] {
            app.groupsType(address, into: email)
            app.buttons["groups.create.addEmail"].tap()
        }
        XCTAssertTrue(app.buttons["Remove esi@moolahub.test"].exists)
        XCTAssertTrue(app.buttons["Remove abena@moolahub.test"].exists)
        XCTAssertFalse(app.buttons["Remove yaw@moolahub.test"].exists)
        let limitMessage = app.staticTexts["You can invite up to 2 people for this group."]
        app.groupsRequire(limitMessage, "invite limit message")
        email.typeText("\n") // dismisses the keyboard
        app.groupsScrollTo(limitMessage)
        app.attachScreenshot(named: "Create group invite limit", to: self)

        // Fewer people than invitations: blocked until fixed.
        app.groupsScrollTo(app.groupsStepperButton("groups.create.people", increment: false), up: true)
        app.groupsStepperButton("groups.create.people", increment: false).tap()
        app.groupsRequire(app.staticTexts["You can invite up to 1 person for this group."], "over-limit message")
        XCTAssertFalse(submit.isEnabled)
        app.buttons["Remove abena@moolahub.test"].tap()
        XCTAssertTrue(submit.isEnabled)

        // Save together switches the stepper to rounds and the summary copy.
        let together = app.buttons["groups.create.saveTogether"]
        app.groupsScrollTo(together, up: true)
        together.tap()
        XCTAssertTrue(together.isSelected, "Save together should be selected")
        let rounds = app.groupsStepperButton("groups.create.rounds", increment: false)
        app.groupsScrollTo(rounds)
        XCTAssertTrue(rounds.exists)
        app.buttons["Weekly"].tap()
        XCTAssertEqual(
            app.staticTexts["groups.create.summary"].label,
            "You pay in $20 weekly. After 10 rounds you get back $200. You start the group once people have joined."
        )
        app.groupsScrollTo(app.staticTexts["groups.create.summary"])
        app.attachScreenshot(named: "Create group save together", to: self)

        // Close without creating anything: the form has edits, so Close asks
        // "Discard this?" first (DESIGN.md v2 B4.12, U7).
        app.buttons["Close"].tap()
        let discard = app.groupsDialogButton("Discard")
        app.attachScreenshot(named: "Create group discard dialog", to: self)
        discard.tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 5))
    }

    // MARK: - Create, invite, join, pay in, start, decline, delete

    /// The groups this test creates become active and can't be deleted, so
    /// they belong to a fresh "QA Groups Owner" account (g…@moolahub.test,
    /// Groups' own first letter in the backend log), never to the shared demo
    /// account that Home, Groups and Activity open on for the founder's
    /// review. kofi (a seeded friend) joins as before.
    @MainActor
    func testCreateInviteJoinPayInStartDeclineDelete() throws {
        let password = try UITestAccount.demoPassword()
        let owner = try GroupsDevAPI.registerFreshOwner()
        let ownerAPI = try GroupsDevAPI.signIn(email: owner.email, password: owner.password)
        // Enough for the $20.40 pay-in; far below the $10,000.00 one.
        try ownerAPI.addTestMoney(cents: 10_000)
        let stamp = String(Int(Date().timeIntervalSince1970) % 1_000_000)
        let turns = "QA Turns \(stamp)"
        let together = "QA Together \(stamp)"
        let declined = "QA Decline \(stamp)"

        // 1. The owner creates three groups.
        var app = XCUIApplication.launchedClean()
        app.groupsSignIn(email: owner.email, password: owner.password)
        app.groupsOpenTab()

        app.groupsCreate(name: turns, saveTogether: false, keys: nil, preset: "20.00 US dollars", stepperDecrements: 3, frequency: nil, invite: nil)
        let formingBody = app.staticTexts["groups.detail.formingBody"]
        app.groupsRequire(formingBody, "forming card")
        XCTAssertEqual(formingBody.label, "1 of 2 have joined. The group starts automatically when the last person joins.")
        XCTAssertFalse(app.buttons["groups.detail.start"].exists, "take-turns groups start on their own")
        XCTAssertTrue(app.groupsAny("groups.detail.payout").label.contains("40.00 US dollars"), app.groupsAny("groups.detail.payout").label)
        XCTAssertTrue(app.buttons["groups.detail.menu"].exists, "a forming group with one member can be deleted")
        app.attachScreenshot(named: "Created take-turns group", to: self)
        app.groupsScrollTo(app.staticTexts["No pay-ins yet."])
        XCTAssertTrue(app.staticTexts["Each pay-in includes a 2% fee."].exists)
        app.attachScreenshot(named: "Created take-turns group bottom", to: self)
        app.groupsScrollTo(app.buttons["groups.detail.invite"], up: true)

        // Invite sheet: a server refusal, then a real invite.
        app.buttons["groups.detail.invite"].tap()
        let inviteEmail = app.textFields["Email"]
        app.groupsRequire(inviteEmail, "Invite sheet")
        XCTAssertEqual(app.staticTexts["groups.inviteSheet.spots"].label, "1 spot left")
        app.attachScreenshot(named: "Invite sheet", to: self)
        app.groupsType(owner.email, into: inviteEmail)
        app.buttons["groups.inviteSheet.send"].tap()
        app.groupsRequire(app.staticTexts["That person is already a member."], "already-a-member error")
        app.attachScreenshot(named: "Invite sheet error", to: self)
        app.groupsType("kofi@moolahub.test", into: inviteEmail)
        app.buttons["groups.inviteSheet.send"].tap()
        app.groupsRequire(app.staticTexts["Invite sent to kofi@moolahub.test."], "invite sent message")
        app.groupsRequire(app.staticTexts["This group is full."], "full message")
        XCTAssertEqual(app.staticTexts["groups.inviteSheet.spots"].label, "0 spots left")
        XCTAssertTrue(app.groupsAny("kofi@moolahub.test. Invited.").exists)
        app.attachScreenshot(named: "Invite sheet sent", to: self)
        app.buttons["Close"].tap()
        app.groupsRequire(app.groupsAny("kofi@moolahub.test. Invited."), "pending invite on detail")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.groupsCreate(name: together, saveTogether: true, keys: ["1", "0", "0", "0", "0"], preset: nil, stepperDecrements: 8, frequency: "Weekly", invite: "kofi@moolahub.test")
        app.groupsRequire(app.staticTexts["groups.detail.formingBody"], "forming card")
        XCTAssertEqual(
            app.staticTexts["groups.detail.formingBody"].label,
            "Invite people by email. Everyone saves into one pot for 2 rounds, then gets their savings back. Start the group once everyone's in."
        )
        XCTAssertTrue(app.staticTexts["Invite at least one more person to start the group."].exists)
        XCTAssertTrue(app.groupsAny("kofi@moolahub.test. Invited.").exists)
        XCTAssertFalse(app.buttons["groups.detail.start"].exists, "can't start with one member")
        app.attachScreenshot(named: "Created save-together group", to: self)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.groupsCreate(name: declined, saveTogether: false, keys: nil, preset: "20.00 US dollars", stepperDecrements: 3, frequency: nil, invite: "kofi@moolahub.test")
        app.groupsRequire(app.staticTexts["groups.detail.formingBody"], "forming card")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.groupsRequire(app.groupsCard(named: declined), "\(declined) card")
        XCTAssertTrue(app.groupsCard(named: declined).label.contains("1 of 2 joined. Starts when everyone joins."), app.groupsCard(named: declined).label)
        app.attachScreenshot(named: "Groups list with forming groups", to: self)
        app.terminate()

        // 2. Kofi accepts two invitations and declines one.
        app = XCUIApplication.launchedClean()
        app.groupsSignIn(email: "kofi@moolahub.test", password: password)
        app.groupsOpenTab()
        let turnsInvite = app.groupsAny("groups.invite.\(turns)")
        app.groupsRequire(turnsInvite, "invite to \(turns)")
        XCTAssertTrue(turnsInvite.staticTexts["\(owner.username) invited you"].exists)
        app.attachScreenshot(named: "Invitations for kofi", to: self)

        app.groupsScrollTo(turnsInvite.buttons["Accept"])
        turnsInvite.buttons["Accept"].tap()
        app.groupsRequire(app.staticTexts["Join \(turns)?"], "join dialog")
        XCTAssertTrue(app.staticTexts["You'll pay in $20.40 monthly."].exists)
        app.attachScreenshot(named: "Join dialog", to: self)
        app.groupsDialogButton("Join group").tap()
        app.groupsCheckToast("You joined \(turns).")
        app.groupsRequire(app.groupsCard(named: turns), "joined group card")
        XCTAssertTrue(app.groupsCard(named: turns).label.contains("Active"), app.groupsCard(named: turns).label)
        app.attachScreenshot(named: "Kofi joined", to: self)

        let togetherInvite = app.groupsAny("groups.invite.\(together)")
        app.groupsScrollTo(togetherInvite.buttons["Accept"])
        togetherInvite.buttons["Accept"].tap()
        app.groupsDialogButton("Join group").tap()
        app.groupsRequire(app.groupsCard(named: together), "joined save-together card")

        let declineInvite = app.groupsAny("groups.invite.\(declined)")
        app.groupsScrollTo(declineInvite.buttons["Decline"])
        declineInvite.buttons["Decline"].tap()
        app.groupsRequire(app.staticTexts["Decline this invitation?"], "decline dialog")
        app.attachScreenshot(named: "Decline dialog", to: self)
        app.groupsDialogButton("Decline").tap()
        XCTAssertTrue(app.groupsAny("groups.invite.\(declined)").waitForNonExistence(timeout: 10), "declined invite should disappear")
        XCTAssertFalse(app.groupsCard(named: declined).exists)
        app.attachScreenshot(named: "Kofi after accept and decline", to: self)

        // Kofi's view of the started take-turns group and the forming one.
        app.groupsScrollTo(app.groupsCard(named: turns), up: true)
        app.groupsCard(named: turns).tap()
        app.groupsRequire(app.buttons["Pay in $20.40"], "kofi's pay-in button")
        XCTAssertTrue(app.groupsAny("groups.detail.round").label.contains("1 of 2"))
        app.attachScreenshot(named: "Take-turns group as kofi", to: self)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let togetherAsKofi = app.groupsCard(named: together)
        app.groupsScrollTo(togetherAsKofi)
        togetherAsKofi.tap()
        app.groupsRequire(app.staticTexts["This group hasn't started yet."], "not-started text for a member")
        XCTAssertFalse(app.buttons["groups.detail.start"].exists)
        XCTAssertFalse(app.buttons["groups.detail.invite"].exists)
        app.attachScreenshot(named: "Forming group as member", to: self)
        app.terminate()

        // 3. The owner pays in, starts the save-together group, meets the
        //    balance check, and deletes the declined group.
        app = XCUIApplication.launchedClean()
        app.groupsSignIn(email: owner.email, password: owner.password)
        let api = ownerAPI
        let start = try api.stableSnapshot()

        app.groupsOpenTab()
        let turnsCard = app.groupsCard(named: turns)
        app.groupsRequire(turnsCard, "\(turns) card")
        app.groupsScrollTo(turnsCard)
        turnsCard.tap()
        let payIn = app.buttons["groups.detail.payIn"]
        app.groupsRequire(payIn, "Pay in button")
        XCTAssertEqual(payIn.label, "Pay in $20.40")
        app.attachScreenshot(named: "Take-turns group active", to: self)
        payIn.tap()
        let confirm = app.buttons["groups.payIn.confirm"]
        app.groupsRequire(confirm, "Pay in review")
        XCTAssertTrue(app.staticTexts["Pay in"].exists)
        XCTAssertTrue(app.staticTexts["Pay-ins can't be undone."].exists)
        XCTAssertTrue(app.groupsLabeled(containing: "Included (2%)").exists)
        XCTAssertTrue(app.groupsLabeled(containing: "1 of 2").exists)
        XCTAssertTrue(app.groupsLabeled(containing: "Balance").exists)
        app.groupsWait(for: confirm, enabled: true)
        // "Confirm" when the simulator has no passcode (no device gate,
        // DESIGN.md §4.13). The iOS 26.5 simulator reports a passcode, so this
        // is "Confirm with Face ID" with Face ID enrolled by ui-test.sh, and
        // its host helper answers the prompt (UITestFaceID).
        let confirmLabel = confirm.label
        XCTAssertTrue(["Confirm", "Confirm with Face ID"].contains(confirmLabel), confirmLabel)
        XCTAssertFalse(app.buttons["groups.payIn.addTestMoney"].exists, "enough balance: no Add test money")
        app.attachScreenshot(named: "Pay in review", to: self)
        confirm.tap()
        if confirmLabel != "Confirm" {
            UITestFaceID.answer("match", app: app)
        }

        app.groupsRequire(app.staticTexts["Paid in to \(turns)"], "Pay in receipt", timeout: 20)
        let doneStatus = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Status", "Done")).firstMatch
        app.groupsRequire(doneStatus, "receipt status Done (matched in Activity)", timeout: 10)
        app.attachScreenshot(named: "Pay in receipt", to: self)
        app.buttons["Done"].tap()
        app.groupsRequire(app.groupsAny("groups.detail.paidIn"), "Paid in this round pill")
        XCTAssertFalse(app.buttons["groups.detail.payIn"].exists, "no second pay-in in the same round")
        app.attachScreenshot(named: "Take-turns group after pay in", to: self)
        app.groupsScrollTo(app.staticTexts["Your pay-ins"])
        let payInRow = app.groupsPayInRow(round: 1, amount: "20.40 US dollars")
        app.groupsScrollTo(payInRow)
        XCTAssertTrue(payInRow.exists, "the pay-in is listed under Your pay-ins")
        app.attachScreenshot(named: "Your pay-ins after pay in", to: self)

        // The balance dropped by exactly the contribution: every other change
        // between the two snapshots (other engineers share the demo account)
        // is a new Activity item, and those are netted out.
        let end = try api.stableSnapshot()
        let newItems = end.items.filter { !start.itemIDs.contains($0.id) }
        let ours = newItems.filter { $0.type == "contribution" && $0.amountCents == -2_040 }
        XCTAssertEqual(ours.count, 1, "exactly one new contribution of -$20.40 in Activity")
        let others = newItems.filter { item in item.id != ours.first?.id }.reduce(Int64(0)) { $0 + $1.amountCents }
        XCTAssertEqual(
            end.availableCents - start.availableCents - others, -2_040,
            "available went from \(start.availableCents) to \(end.availableCents) (others moved \(others))"
        )

        // Save together: start it, then the pay-in is blocked by the balance.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let togetherCard = app.groupsCard(named: together)
        app.groupsScrollTo(togetherCard)
        togetherCard.tap()
        let startButton = app.buttons["groups.detail.start"]
        app.groupsRequire(startButton, "Start group button")
        XCTAssertFalse(app.staticTexts["Invite at least one more person to start the group."].exists)
        app.attachScreenshot(named: "Save-together group ready to start", to: self)
        startButton.tap()
        app.groupsRequire(app.staticTexts["Start this group?"], "start dialog")
        XCTAssertTrue(app.staticTexts["Rounds begin now and the payout order is set."].exists)
        app.attachScreenshot(named: "Start dialog", to: self)
        app.groupsDialogButton("Start group").tap()
        let bigPayIn = app.buttons["groups.detail.payIn"]
        app.groupsRequire(bigPayIn, "Pay in after start")
        XCTAssertEqual(bigPayIn.label, "Pay in $10,000.00")
        XCTAssertTrue(app.groupsAny("groups.detail.round").label.contains("1 of 2"))
        app.attachScreenshot(named: "Save-together group started", to: self)

        let available = try api.stableSnapshot().availableCents
        XCTAssertLessThan(available, 1_000_000, "the owner needs less than $10,000.00 available for the balance check")
        bigPayIn.tap()
        let insufficient = app.staticTexts["groups.payIn.insufficient"]
        app.groupsRequire(insufficient, "insufficient balance message")
        XCTAssertEqual(insufficient.label, "You need $10,000.00 available to pay in. Add money first.")
        XCTAssertFalse(app.buttons["groups.payIn.confirm"].isEnabled)
        let addMoney = app.buttons["groups.payIn.addTestMoney"]
        XCTAssertTrue(addMoney.exists)
        app.attachScreenshot(named: "Pay in not enough balance", to: self)
        addMoney.tap()
        let addMoneySheet = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND identifier != %@", "Add test money", "groups.payIn.addTestMoney"))
            .firstMatch
        app.groupsRequire(addMoneySheet, "Add test money sheet")
        app.attachScreenshot(named: "Add test money from pay in", to: self)
        let addMoneyClose = app.buttons["home.addMoney.close"]
        if addMoneyClose.waitForExistence(timeout: 3) {
            addMoneyClose.tap()
        } else {
            app.groupsTapHittable(app.buttons.matching(identifier: "Close"))
        }
        XCTAssertTrue(addMoneySheet.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["groups.payIn.confirm"].isEnabled, "still not enough after closing Add test money")
        app.groupsTapHittable(app.buttons.matching(identifier: "Close"))
        XCTAssertTrue(app.buttons["groups.payIn.confirm"].waitForNonExistence(timeout: 5))
        let afterBlocked = try api.stableSnapshot()
        XCTAssertFalse(
            afterBlocked.items.contains { !end.itemIDs.contains($0.id) && $0.type == "contribution" && $0.amountCents == -1_000_000 },
            "a blocked pay-in must not reach the server"
        )
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Delete the forming group kofi declined.
        let declinedCard = app.groupsCard(named: declined)
        app.groupsScrollTo(declinedCard)
        declinedCard.tap()
        let menu = app.buttons["groups.detail.menu"]
        app.groupsRequire(menu, "group menu")
        menu.tap()
        app.groupsTapHittable(app.buttons.matching(identifier: "Delete group"))
        app.groupsRequire(app.staticTexts["Delete this group?"], "delete dialog")
        XCTAssertTrue(app.staticTexts["This removes the group and any pending invites."].exists)
        app.attachScreenshot(named: "Delete group dialog", to: self)
        app.groupsDialogButton("Delete group").tap()
        app.groupsCheckToast("Group deleted.")
        XCTAssertTrue(app.navigationBars["Groups"].exists, "back on the Groups list")
        XCTAssertTrue(app.groupsCard(named: declined).waitForNonExistence(timeout: 10))
        app.attachScreenshot(named: "Groups list after delete", to: self)
    }

    // MARK: - Every Group detail section and the sheets at the largest text size (read only)

    /// Review screenshots at AX5 (DESIGN.md v2 B4.13 to B4.20, B4.9, B4.10):
    /// Family susu's payout order, members and pay-ins, How groups work, and
    /// Create group opened and closed with no edits. Creates nothing and
    /// pays nothing.
    @MainActor
    func testGroupDetailSectionsAndSheetsAtLargestTextSize() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.groupsSignIn(password: password)
        app.terminate()

        // Largest accessibility size (the relaunch keeps the session).
        let large = XCUIApplication()
        large.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        large.launch()
        large.groupsOpenTab()

        let family = large.groupsCard(named: "Family susu")
        large.groupsRequire(family, "Family susu card at AX5")
        large.groupsScrollTo(family)
        family.tap()
        large.groupsRequire(large.groupsAny("groups.detail.payout"), "detail at AX5")
        let order = large.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Round 4, @ama, Up next")).firstMatch
        large.groupsScrollTo(order, maxSwipes: 20)
        XCTAssertTrue(order.exists, "payout order at AX5")
        large.attachScreenshot(named: "Family susu payout order AX5", to: self)
        let you = large.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "@ama, you.")).firstMatch
        large.groupsScrollTo(you, maxSwipes: 20)
        XCTAssertTrue(you.exists, "members at AX5")
        large.attachScreenshot(named: "Family susu members AX5", to: self)
        let payIn = large.groupsPayInRow(round: 2, amount: "100.00 US dollars")
        large.groupsScrollTo(payIn, maxSwipes: 20)
        XCTAssertTrue(payIn.exists, "pay-ins at AX5")
        large.attachScreenshot(named: "Family susu pay-ins AX5", to: self)
        large.navigationBars.buttons.element(boundBy: 0).tap()

        // How groups work: the pinned Done stays reachable.
        let explainer = large.buttons["groups.howItWorks"]
        large.groupsScrollTo(explainer, maxSwipes: 40)
        large.attachScreenshot(named: "Groups list AX5 bottom", to: self)
        explainer.tap()
        large.groupsRequire(large.staticTexts["How groups work"], "How groups work at AX5")
        large.attachScreenshot(named: "How groups work AX5", to: self)
        XCTAssertTrue(large.buttons["Done"].isHittable, "Done is reachable at AX5")
        large.buttons["Done"].tap()
        XCTAssertTrue(large.buttons["Done"].waitForNonExistence(timeout: 5), "How groups work should close")

        // Create group with no edits: the pinned button is reachable, and
        // Close shuts it at once.
        large.buttons["groups.createButton"].tap()
        let submit = large.buttons["groups.create.submit"]
        large.groupsRequire(submit, "Create group at AX5")
        XCTAssertTrue(submit.isHittable, "the pinned button is reachable at AX5")
        XCTAssertFalse(submit.isEnabled)
        large.attachScreenshot(named: "Create group AX5", to: self)
        large.buttons["Close"].tap()
        XCTAssertTrue(submit.waitForNonExistence(timeout: 5), "Create group should close")
        large.terminate()
    }
}

// MARK: - Helpers (private to this file)

private extension XCUIApplication {
    /// Signs in through the real Sign in screen, then answers "not now" to the
    /// prompts that can cover the tabs right after: iOS's "Save Password?" and
    /// the one-time app lock offer (only when the simulator has a passcode).
    func groupsSignIn(email: String = UITestAccount.demoEmail, password: String, file: StaticString = #filePath, line: UInt = #line) {
        signIn(email: email, password: password, file: file, line: line)
        // "Save Password?" shows a few seconds after the tabs appear, on top of
        // the app lock offer when there is one.
        let savePassword = buttons["Not Now"]
        let lockOffer = buttons["Not now"]
        for _ in 0..<2 {
            if savePassword.waitForExistence(timeout: 8) {
                groupsTapWhenHittable(savePassword)
                _ = savePassword.waitForNonExistence(timeout: 5)
            }
            if lockOffer.waitForExistence(timeout: 1) {
                groupsTapWhenHittable(lockOffer)
                _ = lockOffer.waitForNonExistence(timeout: 5)
            }
        }
        let tab = tabBars.buttons["Groups"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Groups tab missing", file: file, line: line)
        let deadline = Date().addingTimeInterval(10)
        while !tab.isHittable && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(tab.isHittable, "something still covers the tabs after sign in", file: file, line: line)
    }

    /// Taps `element` once it can be tapped (prompts animate in).
    func groupsTapWhenHittable(_ element: XCUIElement) {
        let deadline = Date().addingTimeInterval(5)
        while !(element.exists && element.isHittable) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if element.exists && element.isHittable {
            element.tap()
        }
    }

    /// Any element by identifier or label, whatever its type.
    func groupsAny(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A row under "Your pay-ins" ("Round 1", the amount, the status).
    func groupsPayInRow(round: Int, amount: String) -> XCUIElement {
        descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Round \(round)", amount))
            .firstMatch
    }

    /// A toast (shown for 3 s), whatever element type it is exposed as.
    func groupsToast(_ text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// Toasts stay 3 s. On a loaded machine one XCUITest snapshot can take
    /// longer than that, so a missed toast is recorded in the result bundle
    /// (activity "Toast …") instead of failing the money-moving flow.
    @discardableResult
    func groupsCheckToast(_ text: String, timeout: TimeInterval = 6) -> Bool {
        let seen = groupsToast(text).waitForExistence(timeout: timeout)
        XCTContext.runActivity(named: seen ? "Toast seen: \(text)" : "Toast not caught within its 3 s: \(text)") { _ in }
        return seen
    }

    /// Types `text` into `field` and checks what landed before anything is
    /// sent. On a loaded Mac XCUITest has dropped synthesized keystrokes while
    /// a medium sheet was still moving up for the keyboard (one run invited
    /// "demo@moolahub.te" instead of getting the already-a-member error), so
    /// this waits for the keyboard and the field to settle, and clears and
    /// types again (at most three times) until the field holds exactly `text`.
    func groupsType(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<3 {
            groupsClear(field)
            groupsFocus(field)
            field.typeText(text)
            if field.value as? String == text { return }
        }
        XCTAssertEqual(field.value as? String, text, "the field did not take the typed text", file: file, line: line)
    }

    /// Taps near the trailing end of `field` (so the caret lands after the
    /// text), then waits for the keyboard and for the field to stop moving.
    /// On a loaded Mac a tap that lands while a sheet is still settling can
    /// leave the field without focus (a dark run then typed into nothing), so
    /// the tap is repeated, at most three times, until the field has focus.
    func groupsFocus(_ field: XCUIElement) {
        groupsKeepClearOfBottomBars(field)
        if let top = groupsBottomBarTop(below: field), field.frame.midY > top - 4 {
            // Never tap: the tap would land on the pinned button.
            XCTFail("\(field) is still under the pinned bar")
            return
        }
        for _ in 0..<3 {
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            if groupsWaitForFocus(field, timeout: 5) { break }
        }
        var last = field.frame
        var stableSince = Date()
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            let now = field.frame
            if now != last {
                last = now
                stableSince = Date()
            } else if Date().timeIntervalSince(stableSince) >= 0.6 {
                return
            }
        }
    }

    /// Whether `field` has keyboard focus within `timeout` seconds.
    func groupsWaitForFocus(_ field: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if field.exists, (field.value(forKey: "hasKeyboardFocus") as? Bool) == true { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    /// Deletes whatever `field` holds (an empty field reports its placeholder
    /// as its value), checking after each pass.
    func groupsClear(_ field: XCUIElement) {
        for _ in 0..<3 {
            guard let current = field.value as? String, !current.isEmpty, current != field.placeholderValue else { return }
            groupsFocus(field)
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
    }

    /// Taps the keypad's delete key `times` times.
    func groupsTapDelete(times: Int) {
        for _ in 0..<times { buttons["delete"].tap() }
    }

    /// The first element whose label contains `text`.
    func groupsLabeled(containing text: String) -> XCUIElement {
        descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func groupsOpenTab(file: StaticString = #filePath, line: UInt = #line) {
        // Right after a launch at an accessibility text size the iOS 26.5 tab
        // bar can expose the Groups item twice for a moment (a dark AX5 run
        // failed on it), and `selectTab` needs a single match: wait it out.
        let deadline = Date().addingTimeInterval(10)
        while tabBars.buttons.matching(identifier: "Groups").count > 1 && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        selectTab("Groups", file: file, line: line)
        XCTAssertTrue(navigationBars["Groups"].waitForExistence(timeout: 10), "Groups list did not open", file: file, line: line)
    }

    /// A group card on the list, matched by its accessibility label prefix.
    func groupsCard(named name: String) -> XCUIElement {
        buttons.matching(identifier: "groups.card")
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(name)."))
            .firstMatch
    }

    func groupsRequire(_ element: XCUIElement, _ what: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        if !element.waitForExistence(timeout: timeout) {
            XCTFail("missing: \(what)", file: file, line: line)
        }
    }

    func groupsWait(for element: XCUIElement, enabled: Bool, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while element.isEnabled != enabled && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertEqual(element.isEnabled, enabled, "\(element) enabled", file: file, line: line)
    }

    /// Swipes the frontmost scroll view until `element` is hittable.
    func groupsScrollTo(_ element: XCUIElement, up: Bool = false, maxSwipes: Int = 12) {
        var swipes = 0
        while !(element.exists && element.isHittable) && swipes < maxSwipes {
            groupsDrag(from: up ? 0.3 : 0.7, to: up ? 0.7 : 0.3)
            swipes += 1
        }
        groupsKeepClearOfBottomBars(element)
    }

    /// Drags the frontmost scroll view in the side margin (x 12 pt), where no
    /// control sits: a drag that starts on the segmented "How often" control
    /// moves its selection instead of scrolling.
    func groupsDrag(from startY: CGFloat, to endY: CGFloat) {
        let start = coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: startY))
        let end = coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// On iOS 26.5 XCUITest reports an element as hittable while Create
    /// group's pinned button (or the floating tab bar) covers its centre, and
    /// the tap lands on the cover: two runs created a group by "tapping" the
    /// invite field whose top edge showed just above "Create group". This
    /// nudges the content up until the element ends above them.
    func groupsKeepClearOfBottomBars(_ element: XCUIElement) {
        for _ in 0..<5 {
            guard let top = groupsBottomBarTop(below: element), element.frame.maxY > top - 8 else { return }
            // Drag just above the bar (it sits on the keyboard when one is up),
            // in the side margin, by 120 pt.
            let origin = coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: 12, dy: top - 30))
            let end = origin.withOffset(CGVector(dx: 12, dy: max(120, top - 150)))
            start.press(forDuration: 0.05, thenDragTo: end)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    /// The top of whatever covers the bottom of the screen under `element`
    /// (Create group's pinned button, else the tab bar); nil when nothing does.
    func groupsBottomBarTop(below element: XCUIElement) -> CGFloat? {
        guard element.exists else { return nil }
        let minY = element.frame.minY
        return [buttons["groups.create.submit"], tabBars.firstMatch]
            .filter { $0.exists && $0.frame.minY > minY }
            .map(\.frame.minY)
            .min()
    }

    /// The button in a confirmation dialog (it can share a label with the
    /// control that opened it).
    func groupsDialogButton(_ label: String) -> XCUIElement {
        let inSheet = sheets.buttons[label]
        if inSheet.waitForExistence(timeout: 3) { return inSheet }
        let inAlert = alerts.buttons[label]
        if inAlert.exists { return inAlert }
        let candidates = buttons.matching(identifier: label).allElementsBoundByIndex.filter(\.isHittable)
        return candidates.last ?? buttons[label]
    }

    func groupsTapHittable(_ query: XCUIElementQuery, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let element = query.allElementsBoundByIndex.last(where: { $0.exists && $0.isHittable }) {
                element.tap()
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTFail("no hittable element for \(query)", file: file, line: line)
    }

    /// The − or + button of a SwiftUI `Stepper`, however it is exposed.
    func groupsStepperButton(_ identifier: String, increment: Bool) -> XCUIElement {
        let suffix = NSPredicate(format: "label ENDSWITH %@", increment ? "Increment" : "Decrement")
        let candidates = [
            steppers[identifier].buttons.matching(suffix).firstMatch,
            otherElements[identifier].buttons.matching(suffix).firstMatch,
            buttons.matching(identifier: identifier).matching(suffix).firstMatch,
        ]
        return candidates.first(where: \.exists) ?? candidates[0]
    }

    /// Relative luminance (0–1) of the canvas at the left edge, mid-screen, to
    /// tell whether the app is drawing in dark appearance.
    func groupsCanvasLuminance() -> Double? {
        guard let image = screenshot().image.cgImage,
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

    /// Fills and submits Create group from the Groups list.
    func groupsCreate(
        name: String, saveTogether: Bool, keys: [String]?, preset: String?, stepperDecrements: Int,
        frequency: String?, invite: String?, file: StaticString = #filePath, line: UInt = #line
    ) {
        buttons["groups.createButton"].tap()
        let submit = buttons["groups.create.submit"]
        groupsRequire(submit, "Create group sheet", file: file, line: line)
        let nameField = textFields["Name"]
        groupsType(name, into: nameField, file: file, line: line)
        nameField.typeText("\n")
        if saveTogether {
            buttons["groups.create.saveTogether"].tap()
        }
        if let keys {
            // The keypad sits below the fold (and is lazy).
            groupsScrollTo(buttons["0"])
            for key in keys { buttons[key].tap() }
        }
        if let preset {
            groupsScrollTo(buttons[preset])
            buttons[preset].tap()
        }
        let stepper = groupsStepperButton(saveTogether ? "groups.create.rounds" : "groups.create.people", increment: false)
        groupsScrollTo(stepper)
        for _ in 0..<stepperDecrements { stepper.tap() }
        if let frequency {
            buttons[frequency].tap()
        }
        if let invite {
            let email = textFields["Invite by email \u{00B7} optional"]
            groupsScrollTo(email)
            groupsType(invite, into: email, file: file, line: line)
            buttons["groups.create.addEmail"].tap()
            groupsRequire(buttons["Remove \(invite)"], "invite chip", file: file, line: line)
        }
        XCTAssertTrue(submit.isEnabled, "Create group should be enabled", file: file, line: line)
        submit.tap()
        groupsCheckToast("Group created.")
        groupsRequire(groupsAny("groups.detail.payout"), "new group detail", timeout: 20, file: file, line: line)
        XCTAssertTrue(navigationBars[name].exists, "detail title should be the group name", file: file, line: line)
    }
}

/// A throwaway account the test registered (its password is generated and
/// never printed; ui-test.sh redacts it from the log).
private struct GroupsFreshAccount {
    let email: String
    let username: String
    let password: String
}

/// Reads an account straight from the dev API to check balances, and
/// registers the throwaway group owner. Calls are synchronous so the tests
/// stay synchronous (see the class comment).
private struct GroupsDevAPI {
    struct ActivityEntry {
        let id: String
        let type: String
        let amountCents: Int64
    }

    /// Available balance plus the newest Activity items, read so that no move
    /// landed between the two reads.
    struct Snapshot {
        let availableCents: Int64
        let items: [ActivityEntry]
        var itemIDs: Set<String> { Set(items.map(\.id)) }
    }

    let token: String
    static let base = "http://localhost:8787/api"

    static func signIn(email: String, password: String) throws -> GroupsDevAPI {
        var request = URLRequest(url: URL(string: base + "/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let object = try JSONSerialization.jsonObject(with: send(request)) as? [String: Any]
        guard let token = object?["sessionToken"] as? String, !token.isEmpty else {
            throw GroupsDevAPIError("dev API sign-in did not return a session token")
        }
        return GroupsDevAPI(token: token)
    }

    /// Registers and verifies "QA Groups Owner" (g…@moolahub.test) with a
    /// generated password, reading the emailed code from the backend log.
    static func registerFreshOwner() throws -> GroupsFreshAccount {
        let handle = "g\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        let account = GroupsFreshAccount(
            email: "\(handle)@moolahub.test",
            username: handle,
            password: "QaGroups-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
        )
        let mark = try UITestBackendLog.mark()
        var register = URLRequest(url: URL(string: base + "/auth/register")!)
        register.httpMethod = "POST"
        register.setValue("ios", forHTTPHeaderField: "X-Client")
        register.setValue("application/json", forHTTPHeaderField: "Content-Type")
        register.httpBody = try JSONSerialization.data(withJSONObject: [
            "name": "QA Groups Owner", "username": account.username, "email": account.email,
            "password": account.password, "dateOfBirth": "1990-01-15",
        ])
        _ = try send(register)
        let code = try UITestBackendLog.code(.verification, emailInitial: "g", after: mark)
        var verify = URLRequest(url: URL(string: base + "/auth/verify-email")!)
        verify.httpMethod = "POST"
        verify.setValue("ios", forHTTPHeaderField: "X-Client")
        verify.setValue("application/json", forHTTPHeaderField: "Content-Type")
        verify.httpBody = try JSONSerialization.data(withJSONObject: ["email": account.email, "code": code])
        let object = try JSONSerialization.jsonObject(with: send(verify)) as? [String: Any]
        if let token = object?["sessionToken"] as? String, !token.isEmpty {
            GroupsDevAPI(token: token).signOut()
        }
        return account
    }

    /// `POST /wallet/deposit` (dev test money), once.
    func addTestMoney(cents: Int64) throws {
        var request = URLRequest(url: URL(string: Self.base + "/wallet/deposit")!)
        request.httpMethod = "POST"
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-session-token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["amountCents": cents])
        _ = try Self.send(request)
    }

    /// Ends this API session (best effort).
    func signOut() {
        var request = URLRequest(url: URL(string: Self.base + "/auth/logout")!)
        request.httpMethod = "POST"
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "x-session-token")
        request.httpBody = Data("{}".utf8)
        _ = try? Self.send(request)
    }

    /// Activity, balance, Activity again; retried until both Activity reads match.
    func stableSnapshot() throws -> Snapshot {
        for _ in 0..<5 {
            let first = try activity()
            let available = try availableCents()
            let second = try activity()
            if first.map(\.id) == second.map(\.id) {
                return Snapshot(availableCents: available, items: second)
            }
        }
        throw GroupsDevAPIError("Activity kept changing while reading the balance")
    }

    private func availableCents() throws -> Int64 {
        let wallet = try JSONSerialization.jsonObject(with: get("/wallet")) as? [String: Any]
        guard let cents = (wallet?["availableCents"] as? NSNumber)?.int64Value else {
            throw GroupsDevAPIError("no availableCents in /wallet")
        }
        return cents
    }

    private func activity() throws -> [ActivityEntry] {
        let items = try JSONSerialization.jsonObject(with: get("/activity?limit=50")) as? [[String: Any]] ?? []
        return items.compactMap { item in
            guard let id = item["id"] as? String,
                  let type = item["type"] as? String,
                  let cents = (item["amountCents"] as? NSNumber)?.int64Value
            else { return nil }
            return ActivityEntry(id: id, type: type, amountCents: cents)
        }
    }

    private func get(_ path: String) throws -> Data {
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue(token, forHTTPHeaderField: "x-session-token")
        return try Self.send(request)
    }

    private static func send(_ request: URLRequest) throws -> Data {
        let box = GroupsResponseBox()
        let finished = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.store(data: data, status: (response as? HTTPURLResponse)?.statusCode, error: error)
            finished.signal()
        }.resume()
        guard finished.wait(timeout: .now() + 20) == .success else {
            throw GroupsDevAPIError("dev API request timed out")
        }
        return try box.result()
    }
}

private struct GroupsDevAPIError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Hands a URLSession completion back to the waiting test thread.
private final class GroupsResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var status: Int?
    private var error: (any Error)?

    func store(data: Data?, status: Int?, error: (any Error)?) {
        lock.lock()
        defer { lock.unlock() }
        self.data = data
        self.status = status
        self.error = error
    }

    func result() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        guard let status, (200..<300).contains(status), let data else {
            throw GroupsDevAPIError("dev API answered \(status.map(String.init) ?? "nothing")")
        }
        return data
    }
}
