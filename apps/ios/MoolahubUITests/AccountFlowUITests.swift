import XCTest

/// End-to-end UI tests for the Account feature, run against the local dev backend.
/// Owned by the Account engineer. Keep helpers `private` so they never collide
/// with another feature's test file.
///
/// Data etiquette: the demo account (demo@) is used only for read-only checks,
/// device-setting toggles and notification preferences (always set back to
/// "Everything"). Profile edits and password changes use a fresh "QA …" account
/// whose email starts with "x", registered through the API at test time.
final class AccountFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Account, Profile (read-only), Security, About, Technical details, Sign out

    @MainActor
    func testAccountScreensTechnicalDetailsAndSignOut() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)

        // Home with Technical details off (the default): no crypto words.
        accountWaitForHome(app)
        try accountAssertNoCryptoWords(app, screen: "Home (technical details off)")

        accountOpenTab(app)
        let header = app.descendants(matching: .any)["account.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Account header missing")
        XCTAssertTrue(header.label.contains("Ama Owusu"), "header: \(header.label)")
        XCTAssertTrue(header.label.contains("@ama"), "header: \(header.label)")
        XCTAssertTrue(header.label.contains("demo@moolahub.test"), "header: \(header.label)")
        for row in ["profile", "security", "notifications", "technicalDetails", "about"] {
            XCTAssertTrue(app.buttons["account.row.\(row)"].exists, "missing row \(row)")
        }
        XCTAssertTrue(app.buttons["account.row.technicalDetails"].label.contains("Off"))
        try accountAssertNoCryptoWords(app, screen: "Account")
        app.attachScreenshot(named: "01 Account", to: self)

        // Profile (read-only look at the demo account; nothing is saved).
        app.buttons["account.row.profile"].tap()
        let nameField = app.textFields["Full name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10), "Profile did not load")
        XCTAssertEqual(nameField.value as? String, "Ama Owusu")
        XCTAssertEqual(app.textFields["Username"].value as? String, "ama")
        let email = app.descendants(matching: .any)["account.profile.email"]
        XCTAssertTrue(email.label.contains("demo@moolahub.test"), "email: \(email.label)")
        XCTAssertTrue(email.label.contains("Verified"), "email: \(email.label)")
        XCTAssertTrue(app.descendants(matching: .any)["account.profile.dateOfBirth"].label.contains("1993"))
        XCTAssertFalse(app.buttons["account.profile.save"].isEnabled, "Save changes must be disabled with no changes")
        try accountAssertNoCryptoWords(app, screen: "Profile")
        app.attachScreenshot(named: "02 Profile", to: self)
        accountGoBack(app)

        // Security: 2FA status, app lock toggle. Off after a clean launch; usable
        // only when the device can authenticate. (The iOS 26.5 simulator answers
        // canEvaluatePolicy(.deviceOwnerAuthentication) = true even with Face ID
        // unenrolled, so both states are accepted as long as the screen agrees
        // with itself.)
        app.buttons["account.row.security"].tap()
        let twoFactor = app.descendants(matching: .any)["account.security.twoFactor"]
        XCTAssertTrue(twoFactor.waitForExistence(timeout: 10))
        XCTAssertTrue(accountWait(for: twoFactor, labelContains: "Off"), "2FA row: \(twoFactor.label)")
        let lock = app.switches["account.security.appLock"]
        XCTAssertTrue(lock.exists, "app lock toggle missing")
        XCTAssertEqual(lock.value as? String, "0", "app lock must be off after a clean launch")
        XCTAssertTrue(lock.label.hasPrefix("Lock with "), "toggle: \(lock.label)")
        if app.staticTexts["Set a passcode on your iPhone to use app lock."].exists {
            XCTAssertFalse(lock.isEnabled, "app lock must be disabled without a device passcode")
        } else {
            XCTAssertTrue(lock.isEnabled, "app lock must be usable when the device can authenticate")
            let asks = app.staticTexts.matching(NSPredicate(
                format: "label BEGINSWITH %@ AND label ENDSWITH %@",
                "MoolaHub asks for ", " when you open it, and after a minute in the background."
            )).firstMatch
            XCTAssertTrue(asks.exists, "app lock footnote missing")
        }
        XCTAssertTrue(app.staticTexts["You can turn two-factor on or off on the MoolaHub website."].exists)
        try accountAssertNoCryptoWords(app, screen: "Security")
        app.attachScreenshot(named: "03 Security", to: self)

        // Change password screen (not submitted on the shared demo account).
        app.buttons["account.security.password"].tap()
        XCTAssertTrue(app.secureTextFields["Current password"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["New password"].exists)
        XCTAssertTrue(app.secureTextFields["Confirm new password"].exists)
        XCTAssertFalse(app.textFields["Authenticator code"].exists, "demo has no 2FA")
        try accountAssertNoCryptoWords(app, screen: "Change password")
        app.attachScreenshot(named: "04 Change password", to: self)
        accountGoBack(app)
        accountGoBack(app)

        // About and legal: version and the two disclosures (no font licences:
        // the app bundles no fonts, DESIGN.md v2 A2.1, B5.8).
        app.buttons["account.row.about"].tap()
        let version = app.descendants(matching: .any)["account.about.version"]
        XCTAssertTrue(version.waitForExistence(timeout: 5))
        XCTAssertNotNil(version.label.range(of: #"Version, \d+\.\d+(\.\d+)? \(\d+\)"#, options: .regularExpression), "version: \(version.label)")
        app.attachScreenshot(named: "05 About and legal", to: self)

        app.buttons["account.about.disclosure.aboutBalance"].tap()
        let disclosure = app.staticTexts["account.disclosure.text"]
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
        XCTAssertTrue(disclosure.label.hasPrefix("Your balance is held as USDC, a US-dollar digital currency issued by Circle."))
        app.attachScreenshot(named: "06 About your balance", to: self)
        accountGoBack(app)

        app.buttons["account.about.disclosure.testMoney"].tap()
        XCTAssertTrue(app.staticTexts["This build of MoolaHub uses test money only. Nothing in it is real money and nothing can be cashed out."].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "06b Test money", to: self)
        accountGoBack(app)

        accountGoBack(app)

        // Technical details: rows only when on; back to off; Home stays clean.
        let technicalRow = app.buttons["account.row.technicalDetails"]
        XCTAssertTrue(technicalRow.waitForExistence(timeout: 5))
        technicalRow.tap()
        let toggle = app.switches["account.technical.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "Technical details must be off by default")
        XCTAssertFalse(app.descendants(matching: .any)["account.technical.network"].exists)
        app.attachScreenshot(named: "08 Technical details off", to: self)

        accountFlip(toggle)
        XCTAssertTrue(accountWait(for: toggle, value: "1"))
        let network = app.descendants(matching: .any)["account.technical.network"]
        XCTAssertTrue(network.waitForExistence(timeout: 10), "network row missing when on")
        let address = app.descendants(matching: .any)["account.technical.address"]
        XCTAssertTrue(address.exists, "address row missing when on")
        XCTAssertTrue(app.staticTexts["Your balance is held as USDC, a US-dollar digital currency."].exists)
        app.attachScreenshot(named: "09 Technical details on", to: self)

        accountFlip(toggle)
        XCTAssertTrue(accountWait(for: toggle, value: "0"))
        XCTAssertTrue(network.waitForNonExistence(timeout: 5), "network row must hide when off")
        XCTAssertFalse(address.exists)
        accountGoBack(app)
        XCTAssertTrue(app.buttons["account.row.technicalDetails"].label.contains("Off"))

        app.tabBars.buttons["Home"].tap()
        accountWaitForHome(app)
        try accountAssertNoCryptoWords(app, screen: "Home after Technical details off")
        app.attachScreenshot(named: "10 Home technical details off", to: self)

        // Sign out: cancel keeps you here; confirm goes to Welcome.
        accountOpenTab(app)
        let signOut = app.buttons["account.signOut"]
        accountScrollTo(signOut, in: app)
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForExistence(timeout: 5), "sign-out dialog missing")
        app.attachScreenshot(named: "11 Sign out dialog", to: self)
        accountCancelDialog(app)
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.firstMatch.exists, "Cancel must keep the user signed in")
        XCTAssertTrue(app.descendants(matching: .any)["account.header"].exists, "Cancel must stay on Account")

        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForExistence(timeout: 5))
        accountConfirmSignOut(app)
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 15), "Welcome did not appear after sign out")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.attachScreenshot(named: "12 Welcome after sign out", to: self)
    }

    // MARK: - Largest accessibility text size

    @MainActor
    func testAccountScreensAtTheLargestTextSize() throws {
        let password = try UITestAccount.demoPassword()
        // Sign in at the default size (Sign in belongs to another feature),
        // then relaunch at AX5 with the session kept.
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored at AX5")
        accountOpenTab(app)
        let header = app.descendants(matching: .any)["account.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains("Ama Owusu"), "header: \(header.label)")
        XCTAssertTrue(header.label.contains("@ama"), "header: \(header.label)")
        XCTAssertTrue(header.label.contains("demo@moolahub.test"), "header: \(header.label)")
        app.attachScreenshot(named: "23 Account AX5 top", to: self)
        app.swipeUp()
        app.attachScreenshot(named: "24 Account AX5 middle", to: self)
        let signOut = app.buttons["account.signOut"]
        accountScrollTo(signOut, in: app)
        XCTAssertTrue(signOut.isHittable, "Sign out must be reachable at AX5")
        app.attachScreenshot(named: "25 Account AX5 bottom", to: self)
        // Back up to the header first, as in the current-settings test: one
        // swipe down from the end can leave the Profile row under the status
        // and navigation bars (60 pt rows), where it counts as hittable but a
        // tap lands on the bars (merge run 2026-10-29: "profile did not load").
        var swipes = 0
        while !header.isHittable && swipes < 8 {
            app.swipeDown()
            swipes += 1
        }

        // The other Account screens at the same size.
        for (row, ready, shot) in [
            ("profile", app.textFields["Full name"], "26 Profile AX5"),
            ("security", app.switches["account.security.appLock"], "27 Security AX5"),
            ("notifications", app.buttons["account.notifications.option.everything"], "28 Notifications AX5"),
            ("about", app.descendants(matching: .any)["account.about.version"], "28b About AX5"),
        ] {
            let link = app.buttons["account.row.\(row)"]
            accountReveal(link, in: app)
            link.tap()
            XCTAssertTrue(ready.waitForExistence(timeout: 10), "\(row) did not load at AX5")
            app.attachScreenshot(named: shot, to: self)
            accountGoBack(app)
            XCTAssertTrue(header.waitForExistence(timeout: 10), "did not return to Account")
        }
    }

    // MARK: - Dark mode

    /// `XCUIDevice.appearance` doesn't switch these simulators, so this test
    /// runs in its own pass with the simulator already in dark appearance:
    ///
    ///     xcrun simctl ui '<sim>' appearance dark
    ///     TEST_RUNNER_MH_ACCOUNT_APPEARANCE=dark MH_BACKEND_LOG=… apps/ios/scripts/ui-test.sh '<sim>' <dd> \
    ///       -only-testing:MoolahubUITests/AccountFlowUITests/testAccountScreensInDarkMode
    ///     xcrun simctl ui '<sim>' appearance light
    @MainActor
    func testAccountScreensInDarkMode() throws {
        guard ProcessInfo.processInfo.environment["MH_ACCOUNT_APPEARANCE"] == "dark" else {
            throw XCTSkip("Dark-mode pass only: set the simulator to dark and TEST_RUNNER_MH_ACCOUNT_APPEARANCE=dark")
        }
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        accountOpenTab(app)
        XCTAssertTrue(app.descendants(matching: .any)["account.header"].waitForExistence(timeout: 10))
        app.attachScreenshot(named: "21 Account dark", to: self)

        app.buttons["account.row.security"].tap()
        XCTAssertTrue(app.switches["account.security.appLock"].waitForExistence(timeout: 10))
        app.attachScreenshot(named: "22 Security dark", to: self)
        accountGoBack(app)

        app.buttons["account.row.notifications"].tap()
        XCTAssertTrue(app.buttons["account.notifications.option.everything"].waitForExistence(timeout: 10))
        app.attachScreenshot(named: "29 Notifications dark", to: self)
        accountGoBack(app)

        app.buttons["account.row.profile"].tap()
        XCTAssertTrue(app.textFields["Full name"].waitForExistence(timeout: 10))
        app.attachScreenshot(named: "29b Profile dark", to: self)
        accountGoBack(app)

        let about = app.buttons["account.row.about"]
        accountReveal(about, in: app)
        about.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.about.version"].waitForExistence(timeout: 10))
        app.attachScreenshot(named: "29c About dark", to: self)
        accountGoBack(app)

        let signOut = app.buttons["account.signOut"]
        accountScrollTo(signOut, in: app)
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "29d Sign out dialog dark", to: self)
        accountCancelDialog(app)
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForNonExistence(timeout: 5))
    }

    // MARK: - Every Account screen in the simulator's current settings

    /// Screenshots of every Account screen (DESIGN.md v2 B5.1 to B5.9) in
    /// whatever the simulator is set to, so one test covers light, dark,
    /// Increase Contrast and text sizes (`xcrun simctl ui <sim> appearance …`,
    /// `increase_contrast …`, `content_size …`). Read-only on the demo
    /// account: nothing is saved, and Technical details is turned back off.
    @MainActor
    func testEveryAccountScreenInCurrentSettings() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        // Optional text size for this pass (TEST_RUNNER_MH_ACCOUNT_CONTENT_SIZE,
        // e.g. UICTContentSizeCategoryAccessibilityXXXL): sign in at the
        // simulator's size (Sign in belongs to another feature), then relaunch
        // at this size with the session kept, as the AX5 test does.
        if let size = ProcessInfo.processInfo.environment["MH_ACCOUNT_CONTENT_SIZE"], !size.isEmpty {
            app.terminate()
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored at \(size)")
        }
        accountOpenTab(app)
        let header = app.descendants(matching: .any)["account.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10), "Account header missing")
        app.attachScreenshot(named: "S01 Account", to: self)
        let signOut = app.buttons["account.signOut"]
        if !signOut.isHittable {
            accountScrollTo(signOut, in: app)
            // To the end of the list, so the shot shows where the last row
            // rests against the tab bar (isHittable can already be true
            // while the row is still partly under the bar).
            app.swipeUp()
            app.swipeUp()
            XCTAssertTrue(signOut.isHittable, "Sign out must be reachable")
            app.attachScreenshot(named: "S01b Account bottom", to: self)
            // Back up to the header: at the end of the list the Profile row
            // can rest under the status and navigation bars (60 pt rows),
            // where it still counts as hittable but a tap lands on the bars.
            var swipes = 0
            while !header.isHittable && swipes < 8 {
                app.swipeDown()
                swipes += 1
            }
            accountReveal(app.buttons["account.row.profile"], in: app)
        }

        // Profile (nothing is edited).
        app.buttons["account.row.profile"].tap()
        XCTAssertTrue(app.textFields["Full name"].waitForExistence(timeout: 10), "Profile did not load")
        XCTAssertTrue(app.descendants(matching: .any)["account.profile.email"].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "S02 Profile", to: self)
        accountShootLower(app, past: app.descendants(matching: .any)["account.profile.dateOfBirth"], named: "S02b Profile lower")
        accountBack(app, from: "Profile", to: "Account")

        // Security, then Change password (not submitted).
        let security = app.buttons["account.row.security"]
        accountReveal(security, in: app)
        security.tap()
        let twoFactor = app.descendants(matching: .any)["account.security.twoFactor"]
        XCTAssertTrue(twoFactor.waitForExistence(timeout: 10))
        XCTAssertTrue(accountWait(for: twoFactor, labelContains: "Off"), "2FA row: \(twoFactor.label)")
        XCTAssertTrue(app.switches["account.security.appLock"].exists)
        app.attachScreenshot(named: "S03 Security", to: self)
        accountShootLower(app, past: app.descendants(matching: .any)["account.security.appLock.footnote"], named: "S03b Security lower")
        let passwordRow = app.buttons["account.security.password"]
        accountReveal(passwordRow, in: app)
        passwordRow.tap()
        let save = app.buttons["account.changePassword.save"]
        XCTAssertTrue(app.secureTextFields["Current password"].waitForExistence(timeout: 10))
        XCTAssertTrue(accountWaitEnabled(save), "Save password stays disabled")
        app.attachScreenshot(named: "S04 Change password", to: self)
        accountShootLower(app, past: app.secureTextFields["Confirm new password"], named: "S04b Change password lower")
        accountBack(app, from: "Change password", to: "Security")
        accountBack(app, from: "Security", to: "Account")

        // Notifications (nothing is changed).
        let notifications = app.buttons["account.row.notifications"]
        accountReveal(notifications, in: app)
        notifications.tap()
        let everything = app.buttons["account.notifications.option.everything"]
        XCTAssertTrue(everything.waitForExistence(timeout: 10), "Notifications did not load")
        let levels = ["everything", "essential", "minimal", "custom"].map { app.buttons["account.notifications.option.\($0)"] }
        let loadedBy = Date().addingTimeInterval(15)
        while !levels.contains(where: { $0.isSelected }), Date() < loadedBy {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertTrue(levels.contains(where: { $0.isSelected }), "no level is checked")
        app.attachScreenshot(named: "S05 Notifications", to: self)
        accountShootLower(app, past: app.buttons["account.notifications.option.custom"], named: "S05b Notifications lower")
        accountBack(app, from: "Notifications", to: "Account")

        // Technical details off, on (the rows load), and off again.
        let technical = app.buttons["account.row.technicalDetails"]
        accountReveal(technical, in: app)
        technical.tap()
        let toggle = app.switches["account.technical.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
        app.attachScreenshot(named: "S06 Technical details off", to: self)
        accountFlipForShots(toggle, to: "1")
        let network = app.descendants(matching: .any)["account.technical.network"]
        XCTAssertTrue(network.waitForExistence(timeout: 10), "network row missing when on")
        XCTAssertTrue(app.descendants(matching: .any)["account.technical.address"].exists)
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "S07 Technical details on", to: self)
        accountShootLower(app, past: app.descendants(matching: .any)["account.technical.address"], named: "S07b Technical details on lower")
        accountReveal(toggle, in: app)
        accountFlipForShots(toggle, to: "0")
        XCTAssertTrue(network.waitForNonExistence(timeout: 5))
        accountBack(app, from: "Technical details", to: "Account")
        XCTAssertTrue(accountWait(for: technical, labelContains: "Off"))

        // About and legal and its two disclosures.
        let about = app.buttons["account.row.about"]
        accountReveal(about, in: app)
        about.tap()
        XCTAssertTrue(app.descendants(matching: .any)["account.about.version"].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "S08 About and legal", to: self)
        accountShootLower(app, past: app.buttons["account.about.disclosure.testMoney"], named: "S08b About and legal lower")
        accountReveal(app.buttons["account.about.disclosure.aboutBalance"], in: app)
        app.buttons["account.about.disclosure.aboutBalance"].tap()
        XCTAssertTrue(app.staticTexts["account.disclosure.text"].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "S09 About your balance", to: self)
        accountBack(app, from: "About your balance", to: "About and legal")
        let testMoney = app.buttons["account.about.disclosure.testMoney"]
        XCTAssertTrue(testMoney.waitForExistence(timeout: 5))
        testMoney.tap()
        XCTAssertTrue(app.staticTexts["account.disclosure.text"].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "S10 Test money", to: self)
        accountBack(app, from: "Test money", to: "About and legal")
        accountBack(app, from: "About and legal", to: "Account")

        // The sign-out dialog, cancelled.
        XCTAssertTrue(header.waitForExistence(timeout: 10), "did not return to Account")
        accountScrollTo(signOut, in: app)
        signOut.tap()
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForExistence(timeout: 5), "sign-out dialog missing")
        app.attachScreenshot(named: "S11 Sign out dialog", to: self)
        accountCancelDialog(app)
        XCTAssertTrue(app.staticTexts["Sign out of MoolaHub?"].waitForNonExistence(timeout: 5))
    }

    // MARK: - App lock with Face ID (host-assisted pass)

    /// Needs Face ID enrolled on the simulator and a host loop that answers
    /// each prompt, because only the host can post the simulated face:
    ///
    ///     xcrun simctl spawn '<sim>' notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
    ///     xcrun simctl spawn '<sim>' notifyutil -p com.apple.BiometricKit.enrollmentChanged
    ///     # loop: when <dir>/request appears, post
    ///     #   notifyutil -p com.apple.BiometricKit_Sim.pearl.<match|nomatch> and delete it
    ///     TEST_RUNNER_MH_ACCOUNT_FACEID_DIR=<dir> MH_BACKEND_LOG=… apps/ios/scripts/ui-test.sh '<sim>' <dd> \
    ///       -only-testing:MoolahubUITests/AccountFlowUITests/testAppLockToggleWithFaceID
    ///     # then unenroll: notifyutil -s com.apple.BiometricKit.enrollmentChanged 0 and -p again
    @MainActor
    func testAppLockToggleWithFaceID() throws {
        guard let dir = ProcessInfo.processInfo.environment["MH_ACCOUNT_FACEID_DIR"], !dir.isEmpty else {
            throw XCTSkip("Face ID pass only: enroll the simulator, run the host helper and set TEST_RUNNER_MH_ACCOUNT_FACEID_DIR")
        }
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        accountOpenTab(app)
        app.buttons["account.row.security"].tap()
        let lock = app.switches["account.security.appLock"]
        XCTAssertTrue(lock.waitForExistence(timeout: 10))
        XCTAssertEqual(lock.label, "Lock with Face ID")
        XCTAssertTrue(lock.isEnabled, "toggle must be usable with Face ID enrolled")
        XCTAssertEqual(lock.value as? String, "0")
        XCTAssertTrue(app.staticTexts["MoolaHub asks for Face ID when you open it, and after a minute in the background."].exists)

        // A face that doesn't match, then Cancel: the setting stays off.
        accountFlip(lock)
        try accountAnswerFaceID("nomatch", dir: dir)
        let cancelled = accountCancelFaceIDPrompt(app)
        XCTAssertTrue(cancelled, "no Cancel on the Face ID prompt after a failed match")
        XCTAssertTrue(accountWaitEnabled(lock), "toggle stayed busy after Cancel")
        XCTAssertEqual(lock.value as? String, "0", "a cancelled prompt must not turn app lock on")

        // A matching face: on.
        accountFlip(lock)
        try accountAnswerFaceID("match", dir: dir)
        XCTAssertTrue(accountWait(for: lock, value: "1", timeout: 20), "app lock did not turn on after a matching face")
        app.attachScreenshot(named: "13 Security app lock on", to: self)

        // Relaunch: locked until Face ID matches.
        app.terminate()
        app.launchArguments = []
        app.launch()
        let locked = app.staticTexts["MoolaHub is locked"]
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "lock screen did not appear on launch")
        app.attachScreenshot(named: "14 Locked on launch", to: self)
        try accountAnswerFaceID("match", dir: dir)
        XCTAssertTrue(locked.waitForNonExistence(timeout: 20), "Face ID did not unlock")
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 10))

        // Turning it off needs no prompt.
        accountOpenTab(app)
        app.buttons["account.row.security"].tap()
        XCTAssertTrue(lock.waitForExistence(timeout: 10))
        XCTAssertEqual(lock.value as? String, "1", "app lock did not persist across launches")
        accountFlip(lock)
        XCTAssertTrue(accountWait(for: lock, value: "0"), "app lock did not turn off")
    }

    // MARK: - Notifications: optimistic save, revert on failure, persists

    @MainActor
    func testNotificationPreferencesRevertAndPersist() throws {
        let password = try UITestAccount.demoPassword()
        // Always hand the shared demo account back on "Everything".
        addTeardownBlock {
            try await AccountTestAPI.resetDemoNotifications(password: password)
        }
        try accountRun { try await AccountTestAPI.resetDemoNotifications(password: password) }

        // 1. A save the server refuses: the selection reverts and the banner shows.
        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state", "-mh-account-reject-preference-saves"]
        app.launch()
        accountSignIn(app, password: password)
        accountOpenNotifications(app)
        let everything = app.buttons["account.notifications.option.everything"]
        let essential = app.buttons["account.notifications.option.essential"]
        XCTAssertTrue(accountWait(selected: everything), "Everything should start selected")
        essential.tap()
        let banner = app.descendants(matching: .any)["account.notifications.error"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no error banner after a refused save")
        XCTAssertTrue(banner.label.contains("We couldn't save that. Please try again."), "banner: \(banner.label)")
        XCTAssertTrue(accountWait(selected: everything), "selection must revert to Everything")
        XCTAssertFalse(essential.isSelected)
        app.attachScreenshot(named: "30 Notifications save failed", to: self)
        app.terminate()

        // 2. Real saves persist across relaunches.
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        accountOpenNotifications(app)
        XCTAssertTrue(accountWait(selected: everything))
        try accountAssertNoCryptoWords(app, screen: "Notifications")
        app.attachScreenshot(named: "31 Notifications", to: self)
        essential.tap()
        XCTAssertTrue(accountWait(selected: essential), "Essential not selected after tap")
        XCTAssertTrue(accountWaitEnabled(essential), "save did not finish")
        XCTAssertFalse(banner.exists)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        accountOpenNotifications(app)
        XCTAssertTrue(accountWait(selected: essential), "Essential did not persist")

        let custom = app.buttons["account.notifications.option.custom"]
        custom.tap()
        XCTAssertTrue(accountWait(selected: custom))
        let tips = app.switches["account.notifications.category.engagement"]
        XCTAssertTrue(tips.waitForExistence(timeout: 5), "custom toggles did not appear")
        XCTAssertTrue(accountWaitEnabled(tips))
        let tipsBefore = tips.value as? String
        accountFlip(tips)
        let tipsAfter = tipsBefore == "1" ? "0" : "1"
        XCTAssertTrue(accountWait(for: tips, value: tipsAfter), "Tips toggle did not change")
        XCTAssertTrue(accountWaitEnabled(tips), "save did not finish")
        app.attachScreenshot(named: "32 Notifications custom", to: self)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        accountOpenNotifications(app)
        XCTAssertTrue(accountWait(selected: custom), "Custom did not persist")
        XCTAssertTrue(accountWait(for: app.switches["account.notifications.category.engagement"], value: tipsAfter), "Tips did not persist")

        // Put the demo account back through the UI as well.
        everything.tap()
        XCTAssertTrue(accountWait(selected: everything))
        XCTAssertTrue(accountWaitEnabled(everything))
        XCTAssertFalse(app.switches["account.notifications.category.engagement"].exists, "custom toggles must hide")
        let server = try accountRun { try await AccountTestAPI.demoNotificationPreference(password: password) }
        XCTAssertEqual(server, "everything")
    }

    // MARK: - Profile edit on a fresh account

    @MainActor
    func testProfileEditValidationAndPersistence() throws {
        let account = try accountRun { try await AccountTestAPI.registerFreshAccount() }
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, email: account.email, password: account.password)
        accountOpenTab(app)
        let header = app.descendants(matching: .any)["account.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains(account.name), "header: \(header.label)")
        XCTAssertTrue(header.label.contains("@\(account.username)"), "header: \(header.label)")
        XCTAssertTrue(header.label.contains(account.email), "header: \(header.label)")

        app.buttons["account.row.profile"].tap()
        let nameField = app.textFields["Full name"]
        let usernameField = app.textFields["Username"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 10))
        XCTAssertEqual(nameField.value as? String, account.name)
        XCTAssertEqual(usernameField.value as? String, account.username)
        let save = app.buttons["account.profile.save"]
        XCTAssertFalse(save.isEnabled)

        // Username already taken (@ama): live check, then the server's refusal.
        accountReplaceText(in: usernameField, with: "ama")
        let status = app.descendants(matching: .any)["account.profile.usernameStatus"]
        XCTAssertTrue(accountWait(for: status, labelContains: "Taken", timeout: 30), "no Taken indicator")
        XCTAssertTrue(save.isEnabled)
        save.tap()
        let error = app.descendants(matching: .any)["account.profile.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "no server error banner")
        XCTAssertTrue(error.label.contains("That username is already taken."), "banner: \(error.label)")
        app.attachScreenshot(named: "40 Profile username taken", to: self)

        // Empty name is refused before any request.
        accountReplaceText(in: usernameField, with: account.username)
        accountReplaceText(in: nameField, with: "")
        accountDismissKeyboard(app)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Name cannot be empty."].waitForExistence(timeout: 5))
        app.attachScreenshot(named: "41 Profile empty name", to: self)

        // A real change saves, shows the toast and updates the header.
        let newName = "QA Xena Edited"
        let newUsername = account.username + "e"
        accountReplaceText(in: nameField, with: newName)
        accountReplaceText(in: usernameField, with: newUsername)
        XCTAssertTrue(accountWait(for: status, labelContains: "Available", timeout: 30), "no Available indicator")
        app.attachScreenshot(named: "42 Profile edited", to: self)
        accountDismissKeyboard(app)
        save.tap()
        XCTAssertTrue(accountWaitForLabel("Saved.", in: app), "no Saved. toast")
        XCTAssertTrue(accountWaitDisabled(save), "Save changes should disable after saving")
        accountGoBack(app)
        XCTAssertTrue(accountWait(for: header, labelContains: newName), "header not updated: \(header.label)")
        XCTAssertTrue(header.label.contains("@\(newUsername)"), "header: \(header.label)")

        // Persists after a relaunch (session kept).
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 20))
        accountOpenTab(app)
        XCTAssertTrue(accountWait(for: header, labelContains: newName), "header after relaunch: \(header.label)")
        app.buttons["account.row.profile"].tap()
        XCTAssertTrue(accountWait(for: nameField, value: newName), "name after relaunch: \(String(describing: nameField.value))")
        XCTAssertEqual(usernameField.value as? String, newUsername)
        app.attachScreenshot(named: "43 Profile after relaunch", to: self)
    }

    // MARK: - Change password on a fresh account

    @MainActor
    func testChangePasswordErrorsSuccessAndSignInAgain() throws {
        let account = try accountRun { try await AccountTestAPI.registerFreshAccount() }
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, email: account.email, password: account.password)
        accountOpenTab(app)
        app.buttons["account.row.security"].tap()
        let passwordRow = app.buttons["account.security.password"]
        XCTAssertTrue(passwordRow.waitForExistence(timeout: 10))
        passwordRow.tap()

        let current = app.secureTextFields["Current password"]
        let newField = app.secureTextFields["New password"]
        let confirm = app.secureTextFields["Confirm new password"]
        let save = app.buttons["account.changePassword.save"]
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertTrue(accountWaitEnabled(save), "Save password stays disabled (2FA status not loaded)")

        // Client-side checks.
        accountType("short", into: newField)
        accountType("short", into: confirm)
        accountDismissKeyboard(app)
        save.tap()
        XCTAssertTrue(app.staticTexts["Password must be at least 8 characters."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Please confirm your password to continue."].exists)
        let newPassword = account.password + "-new"
        accountReplaceSecureText(in: newField, with: newPassword)
        accountReplaceSecureText(in: confirm, with: newPassword + "x")
        accountDismissKeyboard(app)
        save.tap()
        XCTAssertTrue(app.staticTexts["Passwords don't match."].waitForExistence(timeout: 5))

        // Wrong current password: the server's 401 inline, still signed in.
        accountType("wrong-password-1", into: current)
        accountReplaceSecureText(in: confirm, with: newPassword)
        accountDismissKeyboard(app)
        save.tap()
        let error = app.staticTexts["account.changePassword.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), "no inline error")
        XCTAssertEqual(error.label, "Your password is incorrect.")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "a wrong password must not sign the user out")
        XCTAssertTrue(app.navigationBars["Change password"].exists, "should stay on Change password")
        XCTAssertEqual(current.value as? String ?? "", "", "current password must be cleared after the request")
        app.attachScreenshot(named: "50 Change password wrong current", to: self)

        // Success: pop to Security with the toast.
        accountType(account.password, into: current)
        accountDismissKeyboard(app)
        save.tap()
        XCTAssertTrue(accountWaitForLabel("Password updated.", in: app), "no Password updated. toast")
        XCTAssertTrue(app.navigationBars["Security"].waitForExistence(timeout: 5), "did not pop to Security")
        app.attachScreenshot(named: "51 Password updated", to: self)
        // iOS may offer to save the new password once the form is gone.
        accountDismissSystemPrompts(app)

        // Sign out, then sign in with the new password.
        accountGoBack(app)
        let signOut = app.buttons["account.signOut"]
        accountScrollTo(signOut, in: app)
        signOut.tap()
        accountConfirmSignOut(app)
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 15))
        accountSignIn(app, email: account.email, password: newPassword)
        accountOpenTab(app)
        let header = app.descendants(matching: .any)["account.header"]
        XCTAssertTrue(header.waitForExistence(timeout: 10))
        XCTAssertTrue(header.label.contains(account.email))
        app.attachScreenshot(named: "52 Signed in with new password", to: self)
    }

    // MARK: - Wave 1: the new Account rows (account.md §17 tests 1 and 2)

    /// Test 1 (AC-1, AC-3, AC-4): the four new rows exist, in the order of
    /// B5.1 amended, between the rows that were already there; no crypto
    /// words. Read-only on the demo account.
    @MainActor
    func testAccountRootShowsManageAndNewRows() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        accountOpenTab(app)

        var order = ["profile", "security", "notifications", "streakFrequency", "learn", "technicalDetails", "about"]
            .map { "account.row.\($0)" }
        // Debug builds (every UI run) add Developer settings before the
        // Manage group.
        if app.buttons["account.row.developerSettings"].exists {
            order.append("account.row.developerSettings")
        }
        order += ["account.deactivate", "account.row.deleteAccount", "account.signOut"]
        var lastY = -CGFloat.greatestFiniteMagnitude
        for id in order {
            let row = app.buttons[id]
            XCTAssertTrue(row.waitForExistence(timeout: 10), "missing row \(id)")
            XCTAssertGreaterThan(row.frame.minY, lastY, "\(id) is out of order")
            lastY = row.frame.minY
        }
        XCTAssertEqual(app.buttons["account.row.learn"].label, "Learn")
        XCTAssertEqual(app.buttons["account.deactivate"].label, "Deactivate account")
        XCTAssertEqual(app.buttons["account.row.deleteAccount"].label, "Delete account")
        XCTAssertTrue(app.buttons["account.row.streakFrequency"].label.hasPrefix("Streak frequency"))
        try accountAssertNoCryptoWords(app, screen: "Account")
        app.attachScreenshot(named: "A01 Account top", to: self)
        let signOut = app.buttons["account.signOut"]
        accountScrollTo(signOut, in: app)
        XCTAssertTrue(app.buttons["account.deactivate"].isHittable)
        XCTAssertTrue(app.buttons["account.row.deleteAccount"].isHittable)
        try accountAssertNoCryptoWords(app, screen: "Account bottom")
        app.attachScreenshot(named: "A02 Account bottom", to: self)
    }

    /// Test 2's push-and-title half (AC-2), which F0's stubs already carry,
    /// and AC-2b's rule that the row never shows a guess: with the streak
    /// store empty the label is exactly "Streak frequency"; with it loaded,
    /// the server's word. Until Home loads the store (lane H) nothing does
    /// and the launch clears the cache, so the label is exactly the title;
    /// after that merge either may hold here, and the strict value half is
    /// `testStreakFrequencyRowShowsTheServerFrequencyOnceHomeLoaded`.
    @MainActor
    func testLearnAndStreakRowsPushTheirScreens() throws {
        let password = try UITestAccount.demoPassword()
        let word = try accountRun { try await AccountTestAPI.demoStreakFrequencyWord() }
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        accountOpenTab(app)

        let frequency = app.buttons["account.row.streakFrequency"]
        XCTAssertTrue(frequency.waitForExistence(timeout: 10))
        if Self.homeLoadsTheStreakStore {
            let accepted = ["Streak frequency"] + (word.map { ["Streak frequency, \($0)"] } ?? [])
            XCTAssertTrue(accepted.contains(frequency.label), "Streak frequency row: \(frequency.label)")
        } else {
            XCTAssertEqual(frequency.label, "Streak frequency", "with no overview loaded the row shows no value (AC-2b)")
        }
        frequency.tap()
        XCTAssertTrue(app.navigationBars["Streak frequency"].waitForExistence(timeout: 10), "Streak frequency did not open")
        app.attachScreenshot(named: "A03 Streak frequency pushed", to: self)
        accountBack(app, from: "Streak frequency", to: "Account")

        let learn = app.buttons["account.row.learn"]
        accountReveal(learn, in: app)
        learn.tap()
        XCTAssertTrue(app.navigationBars["Learn"].waitForExistence(timeout: 10), "Learn did not open")
        app.attachScreenshot(named: "A04 Learn pushed", to: self)
        accountBack(app, from: "Learn", to: "Account")
    }

    /// Test 2's value half (AC-2b): once Home has loaded the streak store,
    /// the row reads "Streak frequency, {Daily|Weekly|Monthly}" as the server
    /// says. Home loads the store in lane H (D-42), so it runs after that merge.
    @MainActor
    func testStreakFrequencyRowShowsTheServerFrequencyOnceHomeLoaded() throws {
        try XCTSkipIf(Self.homeLoadsTheStreakStore == false, "waits for lane H: Home loads the streak store")
        let password = try UITestAccount.demoPassword()
        let word = try XCTUnwrap(try accountRun { try await AccountTestAPI.demoStreakFrequencyWord() })
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        accountWaitForHome(app)
        accountOpenTab(app)
        let frequency = app.buttons["account.row.streakFrequency"]
        XCTAssertTrue(accountWait(for: frequency, labelContains: word), "Streak frequency row: \(frequency.label)")
        XCTAssertEqual(frequency.label, "Streak frequency, \(word)")
    }

    /// Flipped at the merge after lane H (D-42).
    private static let homeLoadsTheStreakStore = false

    // MARK: - Wave 1: Deactivate (tests 3, 4, 5 and 14)

    /// Test 3 (AC-5): Cancel leaves the person signed in on Account.
    @MainActor
    func testDeactivateCancelKeepsTheSession() throws {
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount() }
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, email: account.email, password: account.password)
        accountOpenTab(app)
        accountOpenDeactivateDialog(app)
        app.attachScreenshot(named: "A10 Deactivate dialog", to: self)
        XCTAssertTrue(app.staticTexts["You'll be signed out on all your devices. Signing in again turns it back on."].exists)
        accountCancelDialog(app)
        XCTAssertTrue(app.staticTexts["Deactivate your account?"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 3), "Cancel must not open the step-up")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "Cancel must keep the person signed in")
        XCTAssertTrue(app.buttons["account.deactivate"].exists, "Cancel must stay on Account")
        let status = try accountRun { try await AuthTestAPI.loginStatus(email: account.email, password: account.password) }
        XCTAssertEqual(status, 200, "the account must still sign in")
    }

    /// Test 4 (AC-6, AC-7, AC-9's count): the dialog opens "Confirm it's
    /// you" with the action's verb; a wrong password shows the server's
    /// message under the field, clears it, and keeps the person signed in
    /// with the sheet open; the tap sent exactly one request (D-36). Return
    /// closes the keyboard before the tap, so the refusal is seen to give
    /// focus back to Password (B5.15 "Refused").
    @MainActor
    func testDeactivateWithAWrongPasswordStaysSignedIn() throws {
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount() }
        let testRun = UUID().uuidString
        let app = XCUIApplication.launchedForCounting(testRun: testRun)
        accountSignIn(app, email: account.email, password: account.password)
        accountOpenTab(app)
        accountOpenDeactivateDialog(app)
        accountConfirmDialog(app, label: "Deactivate account", excluding: ["account.deactivate"])

        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10), "the step-up did not open")
        let submit = app.buttons["account.stepUp.submit"]
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        XCTAssertEqual(submit.label, "Deactivate account")
        XCTAssertTrue(app.staticTexts["Enter your password to continue."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["Authenticator code"].exists, "no two-factor on this account")
        XCTAssertFalse(submit.isEnabled, "the button waits for a password")
        app.attachScreenshot(named: "A11 Step-up deactivate", to: self)

        let field = app.secureTextFields["Password"]
        accountType(account.password + "-wrong\n", into: field)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Return did not close the keyboard")
        XCTAssertTrue(accountWaitEnabled(submit, timeout: 10))
        let mark = try UITestBackendLog.mark()
        submit.tap()
        let error = app.staticTexts["account.stepUp.fieldError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "no inline error for a wrong password")
        XCTAssertEqual(error.label, "Your password is incorrect.")
        XCTAssertTrue(accountWaitForKeyboardFocus(field), "focus must go back to Password after a refusal")
        let sent = try UITestBackendLog.requests(method: "POST", path: "/account/deactivate", after: mark, testRun: testRun)
        XCTAssertEqual(sent.count, 1, "one tap must send exactly one request")
        XCTAssertEqual(app.secureTextFields["Password"].value as? String ?? "", "", "the password must be cleared")
        XCTAssertTrue(app.staticTexts["Confirm it's you"].exists, "the sheet must stay open")
        XCTAssertFalse(submit.isEnabled)
        XCTAssertLessThanOrEqual(error.frame.maxY, submit.frame.minY, "the refusal must sit above the pinned bar")
        app.attachScreenshot(named: "A12 Step-up wrong password", to: self)

        app.buttons["account.stepUp.close"].tap()
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForNonExistence(timeout: 10), "Close did not close the sheet")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "a wrong password must not sign the person out")
        let status = try accountRun { try await AuthTestAPI.loginStatus(email: account.email, password: account.password) }
        XCTAssertEqual(status, 200, "the account must not be deactivated")
    }

    /// Test 5 (AC-6, AC-10, AC-18): deactivate a fresh account, land on
    /// Welcome with "Account deactivated." (gone after 3 s), then sign in
    /// again with the same email and password and reach Home.
    @MainActor
    func testDeactivateThenSignInReactivates() throws {
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount() }
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, email: account.email, password: account.password)
        accountOpenTab(app)
        accountOpenDeactivateDialog(app)
        accountConfirmDialog(app, label: "Deactivate account", excluding: ["account.deactivate"])
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10), "the step-up did not open")
        let submit = app.buttons["account.stepUp.submit"]
        accountType(account.password, into: app.secureTextFields["Password"])
        XCTAssertTrue(accountWaitEnabled(submit, timeout: 10))
        submit.tap()

        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 20), "Welcome did not appear after deactivating")
        XCTAssertTrue(accountWaitForLabel("Account deactivated.", in: app, timeout: 5), "no Account deactivated. toast")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "the tabs must be gone")
        app.attachScreenshot(named: "A13 Welcome after deactivate", to: self)
        let toast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Account deactivated.")).firstMatch
        XCTAssertTrue(toast.waitForNonExistence(timeout: 8), "the toast must leave after 3 s")
        let deactivated = try accountRun { try await AuthTestAPI.loginStatus(email: account.email, password: account.password + "-wrong") }
        XCTAssertEqual(deactivated, 401)

        // Signing in again turns the account back on.
        accountSignIn(app, email: account.email, password: account.password)
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        app.attachScreenshot(named: "A14 Home after reactivating", to: self)
    }

    /// Test 14 (AC-8): with two-factor on, the code field appears once
    /// `GET /security/2fa` answers, and the button stays disabled until the
    /// password and 6 digits are in.
    @MainActor
    func testDeactivateWithTwoFactorAsksForTheCode() throws {
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount(enableTwoFactor: true) }
        let secret = try XCTUnwrap(account.totpSecret)
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, email: account.email, password: account.password, twoFactorSecret: secret)
        accountOpenTab(app)
        accountOpenDeactivateDialog(app)
        accountConfirmDialog(app, label: "Deactivate account", excluding: ["account.deactivate"])
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10), "the step-up did not open")
        let code = app.textFields["Authenticator code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15), "the code field did not appear")
        XCTAssertTrue(app.staticTexts["Enter your password and the 6-digit code from your authenticator app."].exists)
        let submit = app.buttons["account.stepUp.submit"]
        XCTAssertFalse(submit.isEnabled)
        accountType(account.password, into: app.secureTextFields["Password"])
        XCTAssertFalse(submit.isEnabled, "a password alone must not be enough")
        accountType("12345", into: code)
        XCTAssertFalse(submit.isEnabled, "five digits must not be enough")
        code.typeText("6")
        XCTAssertTrue(accountWaitEnabled(submit, timeout: 10), "six digits and a password must enable the button")
        app.attachScreenshot(named: "A15 Step-up with two-factor", to: self)
        app.buttons["account.stepUp.close"].tap()
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForNonExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.firstMatch.exists)
    }

    /// At AX5 a refusal is scrolled into view above the pinned bar, which
    /// rides on the keyboard (B5.15 AX1 to AX5, A8.30): two-factor on (the
    /// longest form), the code typed last, so the number pad is up when the
    /// refusal sends focus back to Password (test 4 covers the move from a
    /// closed keyboard). The password is wrong, so nothing changes.
    @MainActor
    func testStepUpRefusalStaysInViewAtTheLargestTextSize() throws {
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount(enableTwoFactor: true) }
        let secret = try XCTUnwrap(account.totpSecret)
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, email: account.email, password: account.password, twoFactorSecret: secret)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored at AX5")
        accountOpenTab(app)
        accountOpenDeactivateDialog(app)
        accountConfirmDialog(app, label: "Deactivate account", excluding: ["account.deactivate"])
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10), "the step-up did not open")
        let code = app.textFields["Authenticator code"]
        XCTAssertTrue(code.waitForExistence(timeout: 15), "the code field did not appear")

        // Return closes the password keyboard, so the code field can be
        // scrolled out from under the bar at rest.
        let submit = app.buttons["account.stepUp.submit"]
        func clearOfTheBar(_ field: XCUIElement) {
            var swipes = 0
            while (!field.isHittable || field.frame.maxY > submit.frame.minY - 12) && swipes < 6 {
                app.swipeUp()
                swipes += 1
            }
        }
        let password = app.secureTextFields["Password"]
        clearOfTheBar(password)
        accountType(account.password + "-wrong\n", into: password)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Return did not close the keyboard")
        clearOfTheBar(code)
        accountType(AuthTOTP.code(secret: secret, at: Date()), into: code)
        XCTAssertTrue(accountWaitEnabled(submit, timeout: 10))
        submit.tap()

        let error = app.staticTexts["account.stepUp.fieldError"]
        XCTAssertTrue(error.waitForExistence(timeout: 15), "no inline error for a wrong password")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(accountWaitForKeyboardFocus(password), "focus must go back to Password after a refusal")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard must still be up for this check")
        XCTAssertLessThanOrEqual(error.frame.maxY, submit.frame.minY, "the refusal must sit above the pinned bar")
        XCTAssertTrue(error.isHittable, "the refusal must be in view")
        // Which field holds the keyboard once the screen has settled.
        let focus = XCTAttachment(string: [
            "Password: \(password.value(forKey: "hasKeyboardFocus") as? Bool ?? false)",
            "Authenticator code: \(code.value(forKey: "hasKeyboardFocus") as? Bool ?? false)",
            "Frames: refusal \(error.frame), Password \(password.frame), submit \(submit.frame)",
        ].joined(separator: "\n"))
        focus.name = "Keyboard focus after the refusal"
        focus.lifetime = .keepAlways
        add(focus)
        app.attachScreenshot(named: "A16 Step-up refusal AX5 keyboard up", to: self)

        app.buttons["account.stepUp.close"].tap()
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForNonExistence(timeout: 10), "Close did not close the sheet")
        XCTAssertTrue(app.tabBars.firstMatch.exists, "a wrong password must not sign the person out")
    }

    // MARK: - Wave 1: Delete account (tests 6 to 9)

    /// Test 6 (AC-11, AC-12, AC-16; SPEC §4.3): the demo account shows its
    /// three blockers in the server's order with the server's figures and the
    /// exact sub-lines, a disabled button with its reason, no password field
    /// anywhere, and none of the server's 409 words. Read-only.
    @MainActor
    func testDeleteAccountShowsBlockersForTheDemoAccount() throws {
        let password = try UITestAccount.demoPassword()
        let facts = try accountRun { try await AccountTestAPI.demoDeletionFacts(password: password) }
        XCTAssertFalse(facts.balanceUnavailable, "the demo balance must be readable for this test")
        XCTAssertGreaterThan(facts.totalCents, 0)
        XCTAssertGreaterThan(facts.openGroups, 0)
        XCTAssertGreaterThan(facts.goals, 0)
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        accountOpenTab(app)
        accountOpenDeleteAccount(app)

        let balance = app.descendants(matching: .any)["account.delete.blocker.balance"]
        let groups = app.buttons["account.delete.blocker.groups"]
        let goals = app.buttons["account.delete.blocker.goals"]
        XCTAssertTrue(balance.waitForExistence(timeout: 20), "the balance row did not appear")
        XCTAssertTrue(groups.exists && goals.exists, "groups or goals row missing")
        XCTAssertTrue(app.staticTexts["Before you can delete your account"].exists)
        XCTAssertLessThan(balance.frame.minY, groups.frame.minY)
        XCTAssertLessThan(groups.frame.minY, goals.frame.minY)

        // Each row is one element that speaks its sub-line in its value
        // (D-14); the drawn words are Domain's, unit-tested in
        // AccountRulesTests.
        XCTAssertEqual(balance.label, "Total balance")
        XCTAssertEqual(
            balance.value as? String,
            "\(Self.dollarsInWords(facts.totalCents)). Needs to be 0.00 US dollars. Cashing out isn't available yet."
        )
        XCTAssertEqual(groups.label, "Forming or active groups")
        XCTAssertEqual(
            groups.value as? String,
            "\(facts.openGroups). Leaving a group isn't available yet. You can delete a group you started before anyone joins."
        )
        XCTAssertEqual(goals.label, "Goals")
        XCTAssertEqual(goals.value as? String, "\(facts.goals). Money in a goal counts toward your balance.")

        let start = app.buttons["account.delete.start"]
        accountScrollTo(start, in: app)
        XCTAssertFalse(start.isEnabled, "Delete account must be disabled while something is in the way")
        let reason = app.staticTexts.matching(NSPredicate(format: "label == %@", "Clear the items above to continue.")).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "no reason under the disabled button")
        XCTAssertFalse(app.secureTextFields["Password"].exists, "no password field while blocked")
        start.tap()
        XCTAssertFalse(app.staticTexts["Delete your account?"].waitForExistence(timeout: 2), "a disabled button must not open the dialog")

        let labels = accountLabelsAndValues(in: try app.snapshot())
        for label in labels {
            let lower = label.lowercased()
            for banned in ["funds", "withdraw", "release", "circle", "wait for them to finish"] {
                XCTAssertFalse(lower.contains(banned), "Delete account shows '\(banned)' in: \(label)")
            }
        }
        try accountAssertNoCryptoWords(app, screen: "Delete account")
        app.attachScreenshot(named: "A20 Delete account blocked", to: self)
    }

    /// Test 7 (AC-14): Goals selects Savings, Groups selects Groups, and the
    /// Account tab still holds Delete account, checked again: the last
    /// result stays drawn while a re-check runs, so each return is proven by
    /// the three reads it sends (D-36 count). Read-only.
    @MainActor
    func testDeleteAccountRowsSwitchTabs() throws {
        let password = try UITestAccount.demoPassword()
        let testRun = UUID().uuidString
        let app = XCUIApplication.launchedForCounting(testRun: testRun)
        accountSignIn(app, password: password)
        accountOpenTab(app)
        accountOpenDeleteAccount(app)
        let goals = app.buttons["account.delete.blocker.goals"]
        XCTAssertTrue(goals.waitForExistence(timeout: 20))
        accountScrollTo(goals, in: app)
        goals.tap()
        XCTAssertTrue(accountWait(selected: app.tabBars.buttons["Savings"], timeout: 10), "Goals did not open Savings")

        try accountReturnToDeleteAccount(app, from: "Savings", testRun: testRun)
        let groups = app.buttons["account.delete.blocker.groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 20), "the re-check did not land")
        accountScrollTo(groups, in: app)
        groups.tap()
        XCTAssertTrue(accountWait(selected: app.tabBars.buttons["Groups"], timeout: 10), "Groups did not open Groups")
        try accountReturnToDeleteAccount(app, from: "Groups", testRun: testRun)
        XCTAssertTrue(app.buttons["account.delete.blocker.goals"].waitForExistence(timeout: 20))
    }

    /// Selects the Account tab again and checks that Delete account is still
    /// there and read its three conditions again. The tab just left loads
    /// its own data (Savings reads `/goals`, Groups `/circles`), so that is
    /// let finish before the mark.
    @MainActor
    private func accountReturnToDeleteAccount(
        _ app: XCUIApplication, from tab: String, testRun: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        Thread.sleep(forTimeInterval: 3)
        let mark = try UITestBackendLog.mark()
        app.selectTab("Account")
        XCTAssertTrue(app.navigationBars["Delete account"].waitForExistence(timeout: 10), "Delete account was not kept", file: file, line: line)
        for (index, path) in ["/dashboard/summary", "/circles", "/goals"].enumerated() {
            let sent = try UITestBackendLog.requests(method: "GET", path: path, after: mark, testRun: testRun, settle: index == 0 ? 3 : 0)
            XCTAssertGreaterThanOrEqual(sent.count, 1, "back from \(tab), Delete account did not read \(path) again", file: file, line: line)
        }
    }

    /// Test 8 (AC-15, AC-17, AC-18; test 13's Welcome audit): a fresh account
    /// has nothing in the way; the dialog cancels without sending; confirm,
    /// step-up, Welcome with "Account deleted." (held for the audit), and the
    /// old email and password are refused.
    @MainActor
    func testDeleteAnEmptyAccount() throws {
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount() }
        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state", "-mh-hold-toasts"]
        app.launch()
        accountSignIn(app, email: account.email, password: account.password)
        accountOpenTab(app)
        accountOpenDeleteAccount(app)

        let start = app.buttons["account.delete.start"]
        XCTAssertTrue(accountWaitEnabled(start, timeout: 20), "Delete account must be enabled for an empty account")
        XCTAssertFalse(app.staticTexts["Before you can delete your account"].exists, "no heading when clear")
        XCTAssertFalse(app.descendants(matching: .any)["account.delete.blocker.balance"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label == %@", "Clear the items above to continue.")).firstMatch.exists)
        app.attachScreenshot(named: "A21 Delete account clear", to: self)

        start.tap()
        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5), "the confirmation did not open")
        XCTAssertTrue(app.staticTexts["This can't be undone."].exists)
        app.attachScreenshot(named: "A22 Delete confirmation", to: self)
        accountCancelDialog(app)
        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 3), "Cancel must send nothing")

        start.tap()
        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5))
        accountConfirmDialog(app, label: "Delete account", excluding: ["account.delete.start", "account.row.deleteAccount"])
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10), "the step-up did not open")
        let submit = app.buttons["account.stepUp.submit"]
        XCTAssertEqual(submit.label, "Delete account")
        accountType(account.password, into: app.secureTextFields["Password"])
        XCTAssertTrue(accountWaitEnabled(submit, timeout: 10))
        app.attachScreenshot(named: "A23 Step-up delete", to: self)
        submit.tap()

        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 20), "Welcome did not appear after deleting")
        XCTAssertTrue(accountWaitForLabel("Account deleted.", in: app, timeout: 5), "no Account deleted. toast")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        app.attachScreenshot(named: "A24 Welcome after delete", to: self)
        try accountAudit(app, screen: "Welcome with the Account deleted. toast")

        // The old email and password are refused, in the app as on the API.
        app.buttons["Sign in"].firstMatch.tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        accountType(account.email, into: email)
        accountType(account.password, into: app.secureTextFields["Password"])
        app.buttons["auth.signIn.submit"].tap()
        let banner = app.descendants(matching: .any)["auth.signIn.error"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "no error for the deleted account")
        XCTAssertEqual(banner.label, "Invalid email or password.")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
    }

    /// Test 9: at AX5 the Delete account screen wraps and scrolls, and the
    /// button and its reason are reached. Read-only on the demo account.
    @MainActor
    func testDeleteAccountAtTheLargestTextSize() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored at AX5")
        accountOpenTab(app)
        accountOpenDeleteAccount(app)
        let balance = app.descendants(matching: .any)["account.delete.blocker.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 20))
        app.attachScreenshot(named: "A25 Delete account AX5 top", to: self)
        // The heading and the balance row with its amount, which moves under
        // the title at accessibility sizes (A8.21).
        if accountScrollWhole(balance, in: app) {
            app.attachScreenshot(named: "A25b Delete account AX5 balance", to: self)
        }
        let start = app.buttons["account.delete.start"]
        accountScrollTo(start, in: app)
        XCTAssertTrue(start.isHittable, "the button must be reachable at AX5")
        XCTAssertFalse(start.isEnabled)
        let reason = app.staticTexts.matching(NSPredicate(format: "label == %@", "Clear the items above to continue.")).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5))
        if !reason.isHittable { app.swipeUp() }
        XCTAssertTrue(reason.exists && reason.isHittable, "the reason must be reachable at AX5")
        app.attachScreenshot(named: "A26 Delete account AX5 bottom", to: self)
    }

    /// AC-13's failure half (B5.16 States): relaunched signed in against a
    /// local port where nothing listens (the Debug-only `dev.apiBaseURL`
    /// launch argument, never saved), Delete account cannot read its
    /// conditions, so it shows "We couldn't check your account" with the
    /// offline sentence and "Try again", and no row, amount, banner, reason
    /// or Delete button; "Try again" offline changes nothing. In the
    /// simulator's current settings, at TEST_RUNNER_MH_ACCOUNT_CONTENT_SIZE
    /// when set. Read-only on the demo account; nothing reaches the server.
    @MainActor
    func testDeleteAccountOfflineShowsTheErrorState() throws {
        let password = try UITestAccount.demoPassword()
        let size = ProcessInfo.processInfo.environment["MH_ACCOUNT_CONTENT_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        app.terminate()
        app.launchArguments = ["-dev.apiBaseURL", "http://127.0.0.1:9/api"]
            + (size.map { ["-UIPreferredContentSizeCategoryName", $0] } ?? [])
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "the cached session did not open the tabs")
        accountOpenTab(app)
        accountOpenDeleteAccount(app)

        let title = app.staticTexts["We couldn't check your account"]
        let retries = app.buttons.matching(NSPredicate(format: "label == %@", "Try again"))
        let retry = retries.firstMatch
        func assertTheErrorStateAlone(_ moment: String) throws {
            XCTAssertTrue(title.waitForExistence(timeout: 30), "\(moment): no error state when the reads fail")
            XCTAssertTrue(app.staticTexts["We couldn't reach MoolaHub. Check your connection and try again."].exists, "\(moment): no offline sentence")
            XCTAssertTrue(accountWaitEnabled(retry, timeout: 20), "\(moment): no Try again")
            XCTAssertEqual(retries.count, 1, "\(moment): one Try again on the screen")
            XCTAssertFalse(app.buttons["account.delete.start"].exists, "\(moment): no Delete account button when the check failed")
            XCTAssertFalse(app.staticTexts["Before you can delete your account"].exists, "\(moment): no blockers when the check failed")
            XCTAssertFalse(app.descendants(matching: .any)["account.delete.blocker.balance"].exists, "\(moment): no balance row")
            XCTAssertFalse(app.descendants(matching: .any)["account.delete.banner"].exists, "\(moment): no 409 banner")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label == %@", "Clear the items above to continue.")).firstMatch.exists)
            let labels = accountLabelsAndValues(in: try app.snapshot())
            XCTAssertFalse(labels.contains { $0.contains("$") }, "\(moment): an amount shows while nothing could be read: \(labels)")
        }
        try assertTheErrorStateAlone("first check")
        app.attachScreenshot(named: "A27 Delete account cannot check", to: self)
        if !retry.isHittable {
            accountScrollTo(retry, in: app)
            app.attachScreenshot(named: "A27b Delete account cannot check lower", to: self)
        }
        retry.tap()
        try assertTheErrorStateAlone("after Try again")
    }

    // MARK: - Wave 1: Technical details' send warning (test 10)

    /// Test 10 (AC-24): with the setting on and an address, the warning
    /// shows under the footnote, with the third sentence while the server
    /// does not credit deposits. The setting is turned back off.
    @MainActor
    func testTechnicalDetailsShowsTheSendWarning() throws {
        let password = try UITestAccount.demoPassword()
        let syncEnabled = try accountRun { try await AccountTestAPI.demoWalletSyncEnabled(password: password) }
        let app = XCUIApplication.launchedClean()
        accountSignIn(app, password: password)
        accountOpenTab(app)
        let technical = app.buttons["account.row.technicalDetails"]
        accountReveal(technical, in: app)
        technical.tap()
        let toggle = app.switches["account.technical.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["account.technical.sendWarning"].exists, "no warning while off")
        accountFlip(toggle)
        XCTAssertTrue(accountWait(for: toggle, value: "1"))
        let warning = app.descendants(matching: .any)["account.technical.sendWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 15), "no send warning with an address shown")
        XCTAssertTrue(warning.label.contains("Sending to this address"), "warning: \(warning.label)")
        XCTAssertTrue(warning.label.contains("Only send USDC on the network shown above. Anything else may be lost."), "warning: \(warning.label)")
        XCTAssertEqual(warning.label.contains("isn't added to your balance yet"), !syncEnabled, "warning: \(warning.label)")
        let address = app.descendants(matching: .any)["account.technical.address"]
        XCTAssertTrue(address.buttons["Copy"].exists, "the address shows with Copy")
        XCTAssertLessThan(address.frame.maxY, warning.frame.minY, "the warning sits under the address")
        if !warning.isHittable { app.swipeUp() }
        app.attachScreenshot(named: "A30 Technical details send warning", to: self)
        accountReveal(toggle, in: app)
        accountFlip(toggle)
        XCTAssertTrue(accountWait(for: toggle, value: "0"))
        XCTAssertTrue(warning.waitForNonExistence(timeout: 5))
    }

    // MARK: - Wave 1: the time zone sender (test 15)

    /// Test 15 (account AC-26; SPEC §4.5 "UI test", CP-10): lane T's sender
    /// on a throwaway account (every simulator rewrites the demo account's
    /// zone with its Mac's). Each launch sets `TZ` and `MH_TIME_ZONE` to the
    /// same zone, and one `MH_TEST_RUN_ID` runs through the whole test
    /// (D-36). A sign-in in Africa/Accra sends one `PATCH /profile`; a second
    /// launch in the same zone sends none; a launch in Europe/London sends one.
    @MainActor
    func testTimeZoneSentOnceAfterSignIn() throws {
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount() }
        guard try accountProfile(account).keys.contains("timezone") else {
            throw XCTSkip("GET /profile has no timezone: restart the dev backend after lane B step 7 (C3)")
        }
        let testRun = UUID().uuidString

        // 1. Sign in in Africa/Accra: the zone is sent once.
        let app = XCUIApplication.launchedForCounting(testRun: testRun, timeZone: "Africa/Accra")
        let signInMark = try UITestBackendLog.mark()
        accountSignIn(app, email: account.email, password: account.password)
        XCTAssertTrue(app.staticTexts["home.greeting"].waitForExistence(timeout: 30), "Home did not appear after sign in")
        XCTAssertTrue(accountWaitForProfileTimeZone("Africa/Accra", of: account), "GET /profile must return Africa/Accra")
        let afterSignIn = try UITestBackendLog.requests(method: "PATCH", path: "/profile", after: signInMark, testRun: testRun)
        XCTAssertEqual(afterSignIn.count, 1, "signing in must send the zone exactly once")

        // 2. Launch again in the same zone: the session and the sent zone
        // survive, so nothing is sent.
        app.terminate()
        let sameZoneMark = try UITestBackendLog.mark()
        let sameZone = XCUIApplication.launchedForCounting(testRun: testRun, timeZone: "Africa/Accra", resetState: false)
        XCTAssertTrue(sameZone.staticTexts["home.greeting"].waitForExistence(timeout: 30), "Home did not appear after the second launch")
        let afterSameZone = try UITestBackendLog.requests(method: "PATCH", path: "/profile", after: sameZoneMark, testRun: testRun)
        XCTAssertEqual(afterSameZone.count, 0, "a second launch in the same zone must send nothing")

        // 3. Launch in Europe/London: the new zone is sent once.
        sameZone.terminate()
        let newZoneMark = try UITestBackendLog.mark()
        let newZone = XCUIApplication.launchedForCounting(testRun: testRun, timeZone: "Europe/London", resetState: false)
        XCTAssertTrue(newZone.staticTexts["home.greeting"].waitForExistence(timeout: 30), "Home did not appear after the launch in London")
        let afterNewZone = try UITestBackendLog.requests(method: "PATCH", path: "/profile", after: newZoneMark, testRun: testRun)
        XCTAssertEqual(afterNewZone.count, 1, "a launch in a new zone must send it exactly once")
        XCTAssertEqual(try accountProfile(account)["timezone"] as? String, "Europe/London")
    }

    // MARK: - Wave 1: screenshots in the simulator's current settings

    /// Every new Account screen, dialog and sheet in the simulator's current
    /// appearance and contrast (`xcrun simctl ui <sim> appearance …`,
    /// `increase_contrast …`), and at TEST_RUNNER_MH_ACCOUNT_CONTENT_SIZE when
    /// set. A throwaway account shows the clear Delete account screen, both
    /// step-up sheets and the deactivated Welcome; the demo account (read
    /// only) shows the blocked Delete account screen and the send warning.
    @MainActor
    func testAccountWaveScreensInCurrentSettings() throws {
        let password = try UITestAccount.demoPassword()
        let account = try accountRun { try await AuthTestAPI.registerVerifiedAccount() }
        let size = ProcessInfo.processInfo.environment["MH_ACCOUNT_CONTENT_SIZE"].flatMap { $0.isEmpty ? nil : $0 }
        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state", "-mh-hold-toasts"]
        app.launch()
        accountSignIn(app, email: account.email, password: account.password)
        if let size {
            app.terminate()
            app.launchArguments = ["-mh-hold-toasts", "-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored at \(size)")
        }
        accountOpenTab(app)
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W01 Account top", to: self)
        let signOut = app.buttons["account.signOut"]
        accountScrollTo(signOut, in: app)
        app.swipeUp()
        app.attachScreenshot(named: "W02 Account bottom", to: self)

        // Deactivate: dialog, then the step-up sheet (closed again).
        accountOpenDeactivateDialog(app)
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W03 Deactivate dialog", to: self)
        accountConfirmDialog(app, label: "Deactivate account", excluding: ["account.deactivate"])
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Enter your password to continue."].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W04 Step-up deactivate", to: self)
        app.buttons["account.stepUp.close"].tap()
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForNonExistence(timeout: 10))

        // Delete account, clear: the dialog and the step-up with a refusal.
        accountOpenDeleteAccount(app)
        let start = app.buttons["account.delete.start"]
        XCTAssertTrue(accountWaitEnabled(start, timeout: 20))
        app.attachScreenshot(named: "W05 Delete account clear", to: self)
        accountScrollTo(start, in: app)
        start.tap()
        XCTAssertTrue(app.staticTexts["Delete your account?"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W06 Delete confirmation", to: self)
        accountConfirmDialog(app, label: "Delete account", excluding: ["account.delete.start", "account.row.deleteAccount"])
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10))
        let submit = app.buttons["account.stepUp.submit"]
        accountType(account.password + "-wrong", into: app.secureTextFields["Password"])
        XCTAssertTrue(accountWaitEnabled(submit, timeout: 10))
        submit.tap()
        let fieldError = app.staticTexts["account.stepUp.fieldError"]
        XCTAssertTrue(fieldError.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        // With the keyboard up the bar rides on it; the refusal must still
        // show above the bar, at every size (A8.30).
        XCTAssertLessThanOrEqual(fieldError.frame.maxY, submit.frame.minY, "the refusal must sit above the pinned bar")
        app.attachScreenshot(named: "W07a Step-up delete wrong password, keyboard up", to: self)
        // Return closes the keyboard, which Password holds again (at AX5 a
        // swipe down only scrolled the form back to its top).
        app.secureTextFields["Password"].typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "Return did not close the keyboard")
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W07 Step-up delete wrong password", to: self)
        app.buttons["account.stepUp.close"].tap()
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForNonExistence(timeout: 10))
        accountBack(app, from: "Delete account", to: "Account")

        // Deactivate for real: Welcome with the toast (held for the shot).
        accountOpenDeactivateDialog(app)
        accountConfirmDialog(app, label: "Deactivate account", excluding: ["account.deactivate"])
        XCTAssertTrue(app.staticTexts["Confirm it's you"].waitForExistence(timeout: 10))
        accountType(account.password, into: app.secureTextFields["Password"])
        XCTAssertTrue(accountWaitEnabled(submit, timeout: 10))
        submit.tap()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 20))
        XCTAssertTrue(accountWaitForLabel("Account deactivated.", in: app, timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W08 Welcome deactivated toast", to: self)

        // The demo account: blocked Delete account and the send warning. A
        // relaunch drops the held toast (the reason never survives one). It
        // signs in at the default size and then relaunches at `size`, as the
        // other AX5 tests do: at AX5 Sign in's Password field rests under its
        // bar while the email keyboard is up, and a tap there never reached it.
        app.terminate()
        app.launchArguments = []
        app.launch()
        accountSignIn(app, password: password)
        if let size {
            app.terminate()
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", size]
            app.launch()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "session was not restored at \(size)")
        }
        accountOpenTab(app)
        accountOpenDeleteAccount(app)
        let balance = app.descendants(matching: .any)["account.delete.blocker.balance"]
        XCTAssertTrue(balance.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W09 Delete account blocked", to: self)
        if accountScrollWhole(balance, in: app) {
            app.attachScreenshot(named: "W09b Delete account blocked balance", to: self)
        }
        let blockedStart = app.buttons["account.delete.start"]
        if !blockedStart.isHittable {
            accountScrollTo(blockedStart, in: app)
            app.swipeUp()
            app.attachScreenshot(named: "W10 Delete account blocked lower", to: self)
        }
        accountBack(app, from: "Delete account", to: "Account")

        let technical = app.buttons["account.row.technicalDetails"]
        accountReveal(technical, in: app)
        technical.tap()
        let toggle = app.switches["account.technical.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        accountFlipForShots(toggle, to: "1")
        let warning = app.descendants(matching: .any)["account.technical.sendWarning"]
        XCTAssertTrue(warning.waitForExistence(timeout: 15))
        app.swipeUp()
        Thread.sleep(forTimeInterval: 1)
        app.attachScreenshot(named: "W11 Technical details send warning", to: self)
        if !warning.isHittable {
            app.swipeUp()
            app.attachScreenshot(named: "W12 Technical details send warning lower", to: self)
        }
        accountReveal(toggle, in: app)
        accountFlipForShots(toggle, to: "0")
    }

    // MARK: - Private helpers

    /// Signs in through the real Sign in screen (same steps as the shared
    /// `signIn`, but each field is typed into only once it has keyboard
    /// focus: this Mac is shared and slow), then answers "not now" to what can
    /// cover the app right after: iOS's own "Save Password?" sheet and the
    /// one-time app lock offer (only when the simulator reports Face ID).
    /// Neither belongs to this feature.
    @MainActor
    private func accountSignIn(
        _ app: XCUIApplication,
        email: String = UITestAccount.demoEmail,
        password: String,
        twoFactorSecret: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let welcomeSignIn = app.buttons["Sign in"]
        XCTAssertTrue(welcomeSignIn.waitForExistence(timeout: 20), "Welcome did not appear", file: file, line: line)
        welcomeSignIn.tap()
        let emailField = app.textFields["Email"]
        // On this shared, busy Mac a cold launch can take 10 s, and a tap that
        // lands while the launch view cross-fades into Welcome was once lost
        // (the app stayed on Welcome). Tap once more only if Welcome is
        // still showing ("Create account" exists only there), so the Sign in
        // screen's own "Sign in" button is never tapped by mistake.
        if !emailField.waitForExistence(timeout: 8), app.buttons["Create account"].exists, welcomeSignIn.isHittable {
            welcomeSignIn.tap()
        }
        XCTAssertTrue(emailField.waitForExistence(timeout: 10), "Sign in screen did not appear", file: file, line: line)
        accountType(email, into: emailField)
        accountType(password, into: app.secureTextFields["Password"])
        let submit = app.buttons["auth.signIn.submit"]
        if submit.exists {
            submit.tap()
        } else {
            app.buttons.matching(identifier: "Sign in").allElementsBoundByIndex.last?.tap()
        }
        if let twoFactorSecret {
            // A throwaway with two-factor on: answer the challenge.
            let code = app.textFields["Authenticator code"]
            XCTAssertTrue(code.waitForExistence(timeout: 20), "Two-factor did not open", file: file, line: line)
            accountType(AuthTOTP.code(secret: twoFactorSecret, at: Date()), into: code)
            let verify = app.buttons["auth.twoFactor.submit"]
            XCTAssertTrue(accountWaitEnabled(verify, timeout: 10), file: file, line: line)
            verify.tap()
        }
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "Tab bar did not appear after sign in", file: file, line: line)

        // iOS's "Save Password?" sheet can arrive several seconds after the
        // tab bar on a busy Mac, on top of the app lock offer: keep answering
        // "not now" until the Account tab is reachable and nothing new has
        // appeared for a few seconds.
        let accountTab = app.tabBars.buttons["Account"]
        let deadline = Date().addingTimeInterval(45)
        var quietSince = Date()
        var hittable = false
        while Date() < deadline {
            if accountDismissOnePrompt(app) {
                quietSince = Date()
                continue
            }
            hittable = accountTab.exists && accountTab.isHittable
            if hittable, Date().timeIntervalSince(quietSince) >= 6 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        if !hittable {
            app.attachScreenshot(named: "Sign in: tab bar covered", to: self)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "Sign in: hierarchy"
            tree.lifetime = .keepAlways
            add(tree)
        }
        XCTAssertTrue(hittable, "something still covers the tab bar after sign in", file: file, line: line)
    }

    /// Taps "Not Now" / "Not now" on any prompt until none has shown up for
    /// `quiet` seconds (the prompts can follow one another).
    @MainActor
    private func accountDismissSystemPrompts(_ app: XCUIApplication, quietFor quiet: TimeInterval = 4) {
        var quietSince = Date()
        while Date().timeIntervalSince(quietSince) < quiet {
            if accountDismissOnePrompt(app) {
                quietSince = Date()
            } else {
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    /// Taps "Not Now" on iOS's "Save Password?" sheet (in the app's own
    /// hierarchy, or SpringBoard's on some iOS versions) or "Not now" on the
    /// app lock offer. Returns whether it tapped one. The system sheet goes
    /// first because it sits on top of the offer.
    @MainActor
    private func accountDismissOnePrompt(_ app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let prompts = [app.buttons["Not Now"], springboard.buttons["Not Now"], app.buttons["Not now"]]
        guard let prompt = prompts.first(where: { $0.exists && $0.isHittable }) else { return false }
        prompt.tap()
        Thread.sleep(forTimeInterval: 0.5)
        return true
    }

    /// Runs a dev-API call (test setup or cleanup) to completion. The tests
    /// themselves stay synchronous so `continueAfterFailure = false` stops
    /// them at the first failure.
    @MainActor
    private func accountRun<T: Sendable>(
        timeout: TimeInterval = 90,
        _ work: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let box = AccountResultBox<T>()
        let done = XCTestExpectation(description: "dev API call")
        Task.detached {
            do {
                box.set(.success(try await work()))
            } catch {
                box.set(.failure(error))
            }
            done.fulfill()
        }
        _ = XCTWaiter().wait(for: [done], timeout: timeout)
        guard let result = box.get() else { throw AccountTestError("dev API call did not finish in \(Int(timeout)) s") }
        return try result.get()
    }

    /// `GET /profile` for a throwaway account, read with the test's own API
    /// session (never the app's).
    @MainActor
    private func accountProfile(_ account: AuthTestAccount) throws -> [String: Any] {
        let data = try accountRun { try await UITestAPI.profile(email: account.email, password: account.password) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any], "GET /profile is not an object")
    }

    /// Reads `GET /profile` until its `timezone` is `zone` (at most 15 s).
    @MainActor
    private func accountWaitForProfileTimeZone(_ zone: String, of account: AuthTestAccount) -> Bool {
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if (try? accountProfile(account))?["timezone"] as? String == zone { return true }
            Thread.sleep(forTimeInterval: 1)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func accountOpenTab(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Account"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "Account tab missing")
        tab.tap()
        XCTAssertTrue(app.buttons["account.row.profile"].waitForExistence(timeout: 10), "Account screen did not appear")
    }

    @MainActor
    private func accountOpenNotifications(_ app: XCUIApplication) {
        accountOpenTab(app)
        app.buttons["account.row.notifications"].tap()
        XCTAssertTrue(app.buttons["account.notifications.option.everything"].waitForExistence(timeout: 10), "Notifications did not load")
    }

    @MainActor
    private func accountGoBack(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back button")
        back.tap()
    }

    @MainActor
    private func accountWaitForHome(_ app: XCUIApplication) {
        // Home is another feature; give its first load a moment to settle.
        let loaded = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "balance", "Good to see you")).firstMatch
        _ = loaded.waitForExistence(timeout: 10)
        Thread.sleep(forTimeInterval: 2)
    }

    /// DESIGN.md §9.3: none of these on default screens. The balance
    /// disclosure ("Held as USDC · …") is the one allowed exception on Home.
    @MainActor
    private func accountAssertNoCryptoWords(_ app: XCUIApplication, screen: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let substrings = ["usdc", "0x", "wallet", "blockchain", "privy", "transaction", "monad", "address"]
        let words = ["gas", "hash", "base"]
        // One snapshot of the whole tree, so rows that re-render mid-scan
        // can't make the query go stale.
        let labels = try accountTextAndButtonLabels(in: app.snapshot())
            .filter { !$0.isEmpty && !$0.hasPrefix("Held as USDC") }
        XCTAssertFalse(labels.isEmpty, "\(screen): nothing on screen", file: file, line: line)
        for label in labels {
            let lower = label.lowercased()
            for term in substrings where lower.contains(term) {
                XCTFail("\(screen) shows '\(term)' in: \(label)", file: file, line: line)
            }
            for term in words where lower.range(of: "\\b\(term)\\b", options: .regularExpression) != nil {
                XCTFail("\(screen) shows '\(term)' in: \(label)", file: file, line: line)
            }
        }
    }

    @MainActor
    private func accountTextAndButtonLabels(in snapshot: any XCUIElementSnapshot) -> [String] {
        var labels: [String] = []
        if snapshot.elementType == .staticText || snapshot.elementType == .button {
            labels.append(snapshot.label)
        }
        for child in snapshot.children {
            labels += accountTextAndButtonLabels(in: child)
        }
        return labels
    }

    /// Taps the dialog's own "Sign out" (not the row underneath it, which has
    /// the same label). On iOS 26 the dialog is a popover anchored to the row.
    @MainActor
    private func accountConfirmSignOut(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let confirm = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "Sign out", "account.signOut"
        )).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "dialog Sign out button missing", file: file, line: line)
        confirm.tap()
    }

    /// Cancels the sign-out dialog: its "Cancel" button when iOS shows one
    /// (action sheet), else a tap outside the popover (iOS 26 drops Cancel
    /// from popovers).
    @MainActor
    private func accountCancelDialog(_ app: XCUIApplication) {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists, cancel.isHittable {
            cancel.tap()
            return
        }
        let dismissRegion = app.descendants(matching: .any)["PopoverDismissRegion"]
        if dismissRegion.exists {
            dismissRegion.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
    }

    @MainActor
    private func accountScrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        var tries = 0
        while !element.isHittable && tries < 6 {
            app.swipeUp()
            tries += 1
        }
    }

    /// Drags the content up in short, slow steps until `element` shows whole
    /// between the navigation bar and the tab bar, for a screenshot of it;
    /// false when it already did (nothing to shoot again).
    @MainActor
    @discardableResult
    private func accountScrollWhole(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let top = app.navigationBars.firstMatch.frame.maxY
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY : app.windows.firstMatch.frame.maxY
        func isWhole() -> Bool { element.frame.minY >= top && element.frame.maxY <= bottom }
        guard !isWhole() else { return false }
        var tries = 0
        while !isWhole() && tries < 8 {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.3)
            tries += 1
        }
        Thread.sleep(forTimeInterval: 0.5)
        return true
    }

    /// Flips a switch for the screenshot pass and waits for `value`. On this
    /// shared, busy Mac a synthesized tap was once lost in a dark pass (the
    /// switch never received it), so this pass taps once more if the switch
    /// still shows the old value after 8 seconds. The value is read again
    /// before that second tap: while Technical details' skeleton pulses the
    /// app never idles, so the 8 second wait can run out long after the first
    /// tap landed (seen in a light pass, where a blind second tap turned the
    /// switch back off). The switches' behaviour itself is asserted, with a
    /// single tap, by the other tests.
    @MainActor
    private func accountFlipForShots(_ toggle: XCUIElement, to value: String, file: StaticString = #filePath, line: UInt = #line) {
        accountFlip(toggle)
        if !accountWait(for: toggle, value: value, timeout: 8), (toggle.value as? String) != value {
            accountFlip(toggle)
        }
        XCTAssertTrue(accountWait(for: toggle, value: value), "switch did not reach \(value)", file: file, line: line)
    }

    /// Goes back from the pushed screen titled `from` and waits for the bar
    /// titled `to`. On this shared, busy Mac a synthesized tap on Back was
    /// once lost (the screen never popped), so this screenshot pass taps once
    /// more, only while the `from` screen is still showing. The other tests
    /// go back with a single tap (`accountGoBack`).
    @MainActor
    private func accountBack(_ app: XCUIApplication, from: String, to: String, file: StaticString = #filePath, line: UInt = #line) {
        let current = app.navigationBars[from]
        let target = app.navigationBars[to]
        accountGoBack(app)
        if !target.waitForExistence(timeout: 8), current.exists {
            current.buttons.element(boundBy: 0).tap()
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "did not go back from \(from) to \(to)", file: file, line: line)
    }

    /// At large text sizes a screen runs past the display: scroll once and
    /// keep that view too (nothing when `element` is already on screen).
    @MainActor
    private func accountShootLower(_ app: XCUIApplication, past element: XCUIElement, named name: String) {
        guard element.exists, !element.isHittable else { return }
        app.swipeUp()
        app.attachScreenshot(named: name, to: self)
    }

    /// Asks the host helper (see `testAppLockToggleWithFaceID`) to post a
    /// simulated face once the system prompt is up, and waits until it has.
    @MainActor
    private func accountAnswerFaceID(_ kind: String, dir: String) throws {
        // Give the system prompt time to come up before the face arrives.
        Thread.sleep(forTimeInterval: 2.5)
        let request = URL(fileURLWithPath: dir).appendingPathComponent("request")
        try Data(kind.utf8).write(to: request)
        let deadline = Date().addingTimeInterval(20)
        while FileManager.default.fileExists(atPath: request.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.3)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "the host helper did not answer the Face ID request")
    }

    /// Taps Cancel on the system's "Face Not Recognized" prompt. On iOS 26.5
    /// it belongs to neither the app's nor SpringBoard's accessibility tree,
    /// so after looking for a real button (CoreAuthUI, SpringBoard, the app)
    /// it taps the screen where that prompt draws Cancel (centered, 59% down
    /// on iPhone 17 Pro, seen in the "Face ID prompt after no match"
    /// screenshot). Returns whether it tapped. The caller proves the prompt
    /// ended by waiting for the toggle to become enabled again.
    @MainActor
    private func accountCancelFaceIDPrompt(_ app: XCUIApplication) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let coreAuth = XCUIApplication(bundleIdentifier: "com.apple.CoreAuthUI")
        let deadline = Date().addingTimeInterval(6)
        while Date() < deadline {
            for cancel in [coreAuth.buttons["Cancel"], springboard.alerts.buttons["Cancel"], app.alerts.buttons["Cancel"]]
            where cancel.exists && cancel.isHittable {
                cancel.tap()
                return true
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        app.attachScreenshot(named: "Face ID prompt after no match", to: self)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.588)).tap()
        return true
    }

    /// Scrolls either way until `element` can be tapped.
    @MainActor
    private func accountReveal(_ element: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 10), "missing: \(element)", file: file, line: line)
        var tries = 0
        while !element.isHittable && tries < 6 {
            app.swipeDown()
            tries += 1
        }
        tries = 0
        while !element.isHittable && tries < 8 {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(element.isHittable, "can't reach \(element)", file: file, line: line)
    }

    /// Flips a SwiftUI `Toggle`: taps the switch itself (its trailing edge),
    /// since tapping a toggle's label does nothing.
    @MainActor
    private func accountFlip(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        if inner.exists, inner.frame.width < toggle.frame.width {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    /// Taps `field` until it really has keyboard focus (on a busy Mac the
    /// first tap can land before the field is ready, and typing then fails
    /// with "Neither element nor any descendant has keyboard focus").
    @MainActor
    private func accountFocus(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 15), "field missing: \(field)", file: file, line: line)
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<4 {
            if field.isHittable { field.tap() }
            if XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: focused, object: field)], timeout: 4) == .completed {
                return
            }
        }
        XCTFail("field never got keyboard focus: \(field)", file: file, line: line)
    }

    @MainActor
    private func accountType(_ text: String, into field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        accountFocus(field, file: file, line: line)
        field.typeText(text)
    }

    /// Focuses the field, moves the caret to the end, deletes what's there
    /// and types `text`.
    @MainActor
    private func accountReplaceText(in field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        let current = field.value as? String ?? ""
        accountFocus(field, file: file, line: line)
        // Caret to the end: tap just past the text's leading part (the
        // trailing edge holds the username status label).
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        if !text.isEmpty { field.typeText(text) }
    }

    /// Secure fields don't expose their text; clear generously and retype.
    @MainActor
    private func accountReplaceSecureText(in field: XCUIElement, with text: String, file: StaticString = #filePath, line: UInt = #line) {
        accountFocus(field, file: file, line: line)
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)).tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        field.typeText(text)
    }

    @MainActor
    private func accountDismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let nav = app.navigationBars.firstMatch
        if nav.exists {
            nav.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        if app.keyboards.firstMatch.exists {
            app.swipeDown()
        }
    }

    @MainActor
    private func accountWait(for element: XCUIElement, labelContains text: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func accountWait(for element: XCUIElement, value: String, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND value == %@", value)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func accountWait(selected element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND isSelected == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func accountWaitEnabled(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND isEnabled == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func accountWaitDisabled(_ element: XCUIElement, timeout: TimeInterval = 20) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND isEnabled == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func accountWaitForKeyboardFocus(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hasKeyboardFocus == true")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func accountWaitForLabel(_ label: String, in app: XCUIApplication, timeout: TimeInterval = 15) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", label)).firstMatch.waitForExistence(timeout: timeout)
    }

    // MARK: Wave 1 helpers

    /// Scrolls to "Deactivate account", taps it and waits for the dialog.
    @MainActor
    private func accountOpenDeactivateDialog(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["account.deactivate"]
        accountReveal(row, in: app, file: file, line: line)
        row.tap()
        XCTAssertTrue(app.staticTexts["Deactivate your account?"].waitForExistence(timeout: 5), "the Deactivate dialog did not open", file: file, line: line)
    }

    /// Scrolls to "Delete account", taps it and waits for the screen.
    @MainActor
    private func accountOpenDeleteAccount(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let row = app.buttons["account.row.deleteAccount"]
        accountReveal(row, in: app, file: file, line: line)
        row.tap()
        XCTAssertTrue(app.navigationBars["Delete account"].waitForExistence(timeout: 10), "Delete account did not open", file: file, line: line)
        XCTAssertTrue(app.staticTexts["account.delete.intro"].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// Taps a dialog's own button (B5.14, B5.17): the one labelled `label`
    /// whose identifier is none of the controls with the same words.
    @MainActor
    private func accountConfirmDialog(
        _ app: XCUIApplication, label: String, excluding identifiers: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let button = app.buttons.matching(NSPredicate(
            format: "label == %@ AND NOT (identifier IN %@)", label, identifiers
        )).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "dialog \(label) button missing", file: file, line: line)
        button.tap()
    }

    /// Every label and value in the tree (combined rows speak their sub-line
    /// in their value).
    @MainActor
    private func accountLabelsAndValues(in snapshot: any XCUIElementSnapshot) -> [String] {
        var texts = [snapshot.label]
        if let value = snapshot.value as? String { texts.append(value) }
        for child in snapshot.children {
            texts += accountLabelsAndValues(in: child)
        }
        return texts.filter { !$0.isEmpty }
    }

    /// The system accessibility audit; every issue fails the test. A run that
    /// times out on a busy Mac is repeated, up to three runs.
    @MainActor
    private func accountAudit(_ app: XCUIApplication, screen: String) throws {
        var attempt = 0
        while true {
            attempt += 1
            var issues: [String] = []
            do {
                try app.performAccessibilityAudit { issue in
                    let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' frame=\($0.frame)" } ?? "none"
                    issues.append("\(issue.compactDescription) (\(issue.detailedDescription)) | element: \(element)")
                    return true
                }
                XCTAssertTrue(issues.isEmpty, "\(screen) audit found \(issues.count) issue(s):\n" + issues.joined(separator: "\n"))
                return
            } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 && attempt < 3 {
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    /// "3,030.12 US dollars" as `Money.accessibilityText()` speaks it.
    private static func dollarsInWords(_ cents: Int) -> String {
        (Decimal(cents) / 100).formatted(
            .currency(code: "USD").locale(Locale(identifier: "en_US")).precision(.fractionLength(2)).presentation(.fullName)
        )
    }
}

/// Direct calls to the dev API for test setup and cleanup (never through the
/// app under test). Bodies are built here; nothing is logged.
private enum AccountTestAPI {
    static let baseURL = URL(string: "http://localhost:8787/api")!

    struct FreshAccount: Sendable {
        let name: String
        let email: String
        let username: String
        let password: String
    }

    private struct SessionResponse: Decodable {
        let sessionToken: String?
    }

    private struct PreferencesResponse: Decodable {
        let preference: String
    }

    /// Registers "QA Xena Account" with an "x…@moolahub.test" email and
    /// verifies it with the code from the backend log.
    static func registerFreshAccount() async throws -> FreshAccount {
        let stamp = Int(Date().timeIntervalSince1970)
        let suffix = Int.random(in: 100...999)
        let handle = "x\(stamp)\(suffix)"
        let account = FreshAccount(
            name: "QA Xena Account",
            email: "\(handle)@moolahub.test",
            username: handle,
            password: "QaPw-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        )
        let mark = try UITestBackendLog.mark()
        let register = try JSONSerialization.data(withJSONObject: [
            "name": account.name, "username": account.username, "email": account.email,
            "password": account.password, "dateOfBirth": "1990-01-15", "rememberMe": true,
        ])
        let (registerStatus, _) = try await send("POST", "/auth/register", body: register)
        guard registerStatus == 201 || registerStatus == 200 else {
            throw AccountTestError("register returned \(registerStatus)")
        }
        let code = try UITestBackendLog.code(.verification, emailInitial: "x", after: mark)
        let verify = try JSONSerialization.data(withJSONObject: ["email": account.email, "code": code, "rememberMe": true])
        let (verifyStatus, data) = try await send("POST", "/auth/verify-email", body: verify)
        guard verifyStatus == 200, let token = try JSONDecoder().decode(SessionResponse.self, from: data).sessionToken else {
            throw AccountTestError("verify-email returned \(verifyStatus)")
        }
        _ = try? await send("POST", "/auth/logout", body: Data("{}".utf8), token: token)
        return account
    }

    /// Sets demo@'s notification preference back to "Everything".
    static func resetDemoNotifications(password: String) async throws {
        try await withDemoSession(password: password) { token in
            let body = Data(#"{"preference":"everything"}"#.utf8)
            let (status, _) = try await send("PATCH", "/notifications/preferences", body: body, token: token)
            guard status == 200 else { throw AccountTestError("reset preferences returned \(status)") }
        }
    }

    static func demoNotificationPreference(password: String) async throws -> String {
        var preference = ""
        try await withDemoSession(password: password) { token in
            let (status, data) = try await send("GET", "/notifications/preferences", body: nil, token: token)
            guard status == 200 else { throw AccountTestError("preferences returned \(status)") }
            preference = try JSONDecoder().decode(PreferencesResponse.self, from: data).preference
        }
        return preference
    }

    /// What Delete account checks, read straight from the API for the demo
    /// account (read only): the total, whether it was readable, the forming
    /// or active groups and the active goals.
    struct DeletionFacts: Sendable {
        let totalCents: Int
        let balanceUnavailable: Bool
        let openGroups: Int
        let goals: Int
    }

    private struct SummaryResponse: Decodable {
        let totalCents: Int
        let balanceUnavailable: Bool?
    }

    private struct CircleResponse: Decodable {
        let status: String
    }

    private struct IDResponse: Decodable {
        let id: String
    }

    private struct WalletResponse: Decodable {
        let syncEnabled: Bool
    }

    private struct StreakResponse: Decodable {
        let frequency: String
    }

    static func demoDeletionFacts(password: String) async throws -> DeletionFacts {
        var facts: DeletionFacts?
        try await withDemoSession(password: password) { token in
            let summary = try JSONDecoder().decode(SummaryResponse.self, from: try await read("/dashboard/summary", token: token))
            let circles = try JSONDecoder().decode([CircleResponse].self, from: try await read("/circles", token: token))
            let goals = try JSONDecoder().decode([IDResponse].self, from: try await read("/goals", token: token))
            facts = DeletionFacts(
                totalCents: summary.totalCents,
                balanceUnavailable: summary.balanceUnavailable ?? false,
                openGroups: circles.filter { ["forming", "active"].contains($0.status) }.count,
                goals: goals.count
            )
        }
        guard let facts else { throw AccountTestError("no deletion facts") }
        return facts
    }

    /// `GET /wallet`'s `syncEnabled` for the demo account (read only).
    static func demoWalletSyncEnabled(password: String) async throws -> Bool {
        var enabled = false
        try await withDemoSession(password: password) { token in
            enabled = try JSONDecoder().decode(WalletResponse.self, from: try await read("/wallet", token: token)).syncEnabled
        }
        return enabled
    }

    /// The demo account's streak frequency as the Account row names it
    /// ("Daily", "Weekly", "Monthly"), or nil for any other value.
    static func demoStreakFrequencyWord() async throws -> String? {
        let raw = try JSONDecoder().decode(StreakResponse.self, from: try await UITestAPI.streaks()).frequency
        return ["daily": "Daily", "weekly": "Weekly", "monthly": "Monthly"][raw]
    }

    private static func read(_ path: String, token: String) async throws -> Data {
        let (status, data) = try await send("GET", path, body: nil, token: token)
        guard status == 200 else { throw AccountTestError("GET \(path) returned \(status)") }
        return data
    }

    private static func withDemoSession(password: String, _ work: (String) async throws -> Void) async throws {
        let login = try JSONSerialization.data(withJSONObject: [
            "email": UITestAccount.demoEmail, "password": password, "rememberMe": true,
        ])
        let (status, data) = try await send("POST", "/auth/login", body: login)
        guard status == 200, let token = try JSONDecoder().decode(SessionResponse.self, from: data).sessionToken else {
            throw AccountTestError("demo login returned \(status)")
        }
        do {
            try await work(token)
        } catch {
            _ = try? await send("POST", "/auth/logout", body: Data("{}".utf8), token: token)
            throw error
        }
        _ = try? await send("POST", "/auth/logout", body: Data("{}".utf8), token: token)
    }

    private static func send(_ method: String, _ path: String, body: Data?, token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        if let token {
            request.setValue(token, forHTTPHeaderField: "x-session-token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

private struct AccountTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Hands a detached task's result back to the synchronous test.
private final class AccountResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, any Error>?

    func set(_ value: Result<T, any Error>) {
        lock.withLock { result = value }
    }

    func get() -> Result<T, any Error>? {
        lock.withLock { result }
    }
}
