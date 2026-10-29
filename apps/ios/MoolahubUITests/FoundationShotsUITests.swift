import XCTest

/// Screenshots of the v2 foundation for review (DESIGN.md v2 U1 steps 1 to 4):
/// the Debug-only design specimen (Developer settings → Design specimen) in
/// light, dark and at the largest accessibility size, and the app lock offer.
/// Read-only on the demo account: nothing is created, moved or changed.
/// Helpers are `private` and prefixed `foundation`.
final class FoundationShotsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDesignSpecimenInLightDarkAndLargestText() throws {
        let password = try UITestAccount.demoPassword()
        XCUIDevice.shared.appearance = .light
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)

        foundationOpenSpecimen(app)
        foundationShootPages(app, prefix: "S-light")

        XCUIDevice.shared.appearance = .dark
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        foundationScrollToTop(app)
        foundationShootPages(app, prefix: "S-dark")
        XCUIDevice.shared.appearance = .light

        // The largest accessibility size, session kept.
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "relaunch at AX5 did not restore the session")
        app.attachScreenshot(named: "S-AX5 00 Home", to: self)
        foundationOpenSpecimen(app)
        foundationShootPages(app, prefix: "S-AX5", maxPages: 40)
    }

    /// The specimen in whatever the simulator is set to (run it with
    /// `simctl ui … increase_contrast enabled` for the Increase Contrast pass).
    @MainActor
    func testDesignSpecimenInCurrentSettings() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        app.attachScreenshot(named: "C 00 Home", to: self)
        foundationOpenSpecimen(app)
        foundationShootPages(app, prefix: "C")
    }

    /// The one-time app lock offer after a first sign-in (B1.4), light then dark.
    @MainActor
    func testAppLockOfferInLightAndDark() throws {
        let password = try UITestAccount.demoPassword()
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
            let app = XCUIApplication.launchedClean()
            let name = appearance == .dark ? "dark" : "light"
            app.attachScreenshot(named: "O-\(name) 00 Welcome", to: self)
            XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 30))
            app.buttons["Sign in"].tap()
            let email = app.textFields["Email"]
            XCTAssertTrue(email.waitForExistence(timeout: 15))
            email.tap()
            email.typeText(UITestAccount.demoEmail)
            app.secureTextFields["Password"].tap()
            app.secureTextFields["Password"].typeText(password)
            app.buttons["auth.signIn.submit"].tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
            if foundationWaitForLockOffer(app) {
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                app.attachScreenshot(named: "O-\(name) 01 App lock offer", to: self)
            }
            app.dismissSignInPrompts()
            app.attachScreenshot(named: "O-\(name) 02 Home", to: self)
            XCTAssertTrue(app.selectTab("Savings"))
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            app.attachScreenshot(named: "O-\(name) 03 Savings", to: self)
            XCTAssertTrue(app.selectTab("Account"))
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            app.attachScreenshot(named: "O-\(name) 04 Account", to: self)
            app.terminate()
        }
    }

    /// The lock screen itself (B1.3), after the automatic Face ID prompt is
    /// refused and cancelled, in light, dark and at the largest text size. App
    /// lock is turned on from the sign-in offer and off again at the end.
    @MainActor
    func testLockScreenInLightDarkAndLargestText() throws {
        guard UITestFaceID.directory != nil else {
            throw XCTSkip("needs Face ID: run through apps/ios/scripts/ui-test.sh")
        }
        let password = try UITestAccount.demoPassword()
        XCUIDevice.shared.appearance = .light
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication.launchedClean()
        XCTAssertTrue(app.buttons["Sign in"].waitForExistence(timeout: 30))
        app.buttons["Sign in"].tap()
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap()
        email.typeText(UITestAccount.demoEmail)
        app.secureTextFields["Password"].tap()
        app.secureTextFields["Password"].typeText(password)
        app.buttons["auth.signIn.submit"].tap()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30))
        XCTAssertTrue(foundationWaitForLockOffer(app), "no app lock offer")
        app.buttons["Turn on Face ID"].tap()
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(app.buttons["Turn on Face ID"].waitForNonExistence(timeout: 20))
        app.dismissSignInPrompts()

        let locked = app.staticTexts["MoolaHub is locked"]
        // Locked on launch; the automatic prompt is refused and cancelled.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "not locked on launch")
        foundationRefuseFaceID(app)
        app.attachScreenshot(named: "K-light 01 Lock screen", to: self)
        XCUIDevice.shared.appearance = .dark
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        app.attachScreenshot(named: "K-dark 01 Lock screen", to: self)
        XCUIDevice.shared.appearance = .light

        // The largest accessibility size.
        app.terminate()
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(locked.waitForExistence(timeout: 20), "not locked on launch at AX5")
        foundationRefuseFaceID(app)
        app.attachScreenshot(named: "K-AX5 01 Lock screen", to: self)

        // Unlock, then turn app lock off again.
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(locked.waitForExistence(timeout: 20))
        UITestFaceID.answer("match", app: app)
        XCTAssertTrue(locked.waitForNonExistence(timeout: 20), "Face ID did not unlock")
        XCTAssertTrue(app.selectTab("Account"))
        app.buttons["account.row.security"].tap()
        let toggle = app.switches["account.security.appLock"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        if toggle.value as? String == "1" {
            let inner = toggle.switches.firstMatch
            if inner.exists, inner.frame.width < toggle.frame.width {
                inner.tap()
            } else {
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
        }
        let deadline = Date().addingTimeInterval(10)
        while toggle.value as? String != "0", Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertEqual(toggle.value as? String, "0", "app lock did not turn off")
    }

    /// The Activity receipt (B2.7, U7's suggested test) opened through the
    /// app-level sheet path (`AppSheet.activityReceipt`) from the demo
    /// account's newest real move, listed live in the Debug specimen: the sheet
    /// carries `activity.receipt`, a Status row and, when the move has an
    /// amount, `activity.receipt.amount` read in full words; "Done" closes it.
    /// Light, then dark. Read-only: nothing is created or moved.
    @MainActor
    func testActivityReceiptFromNewestMove() throws {
        let password = try UITestAccount.demoPassword()
        XCUIDevice.shared.appearance = .light
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        foundationOpenSpecimen(app)

        let newest = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "specimen.receipt.")).firstMatch
        for _ in 0..<40 where !(newest.exists && newest.isHittable) {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(newest.waitForExistence(timeout: 10), "no live activity row in the specimen")
        let rowLabel = newest.label
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let name = appearance == .dark ? "dark" : "light"
            newest.tap()
            let receipt = app.descendants(matching: .any)["activity.receipt"]
            XCTAssertTrue(receipt.waitForExistence(timeout: 10), "the Activity receipt did not open")
            let status = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Status")).firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 5), "no Status row")
            XCTAssertTrue(["Done", "Processing", "Didn't go through"].contains { status.label.contains($0) }, "Status row reads \(status.label)")
            let amount = app.descendants(matching: .any)["activity.receipt.amount"]
            if rowLabel.contains("US dollars") {
                XCTAssertTrue(amount.waitForExistence(timeout: 5), "no receipt amount")
                XCTAssertTrue(amount.label.hasSuffix("US dollars"), "amount reads \(amount.label)")
                XCTAssertTrue(amount.label.hasPrefix("plus ") || amount.label.hasPrefix("minus "), "the Activity receipt's amount is signed: \(amount.label)")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            app.attachScreenshot(named: "R-\(name) Activity receipt", to: self)
            app.buttons["Done"].tap()
            XCTAssertTrue(receipt.waitForNonExistence(timeout: 10), "Done did not close the receipt")
        }
    }

    /// The root-gate screens (Launch, Privacy cover, Restore failed, Not
    /// configured), pushed from the Debug specimen, in light and dark.
    @MainActor
    func testShellScreensInLightAndDark() throws {
        let password = try UITestAccount.demoPassword()
        XCUIDevice.shared.appearance = .light
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        foundationOpenSpecimen(app)
        for appearance in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = appearance
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            let name = appearance == .dark ? "dark" : "light"
            for (id, title) in [("launch", "Launch"), ("privacy", "Privacy cover"), ("restoreFailed", "Restore failed"), ("notConfigured", "Not configured")] {
                let link = app.buttons["specimen.shell.\(id)"]
                XCTAssertTrue(link.waitForExistence(timeout: 10), "no \(title) link")
                link.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                app.attachScreenshot(named: "H-\(name) \(title)", to: self)
                app.navigationBars.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(link.waitForExistence(timeout: 10), "did not come back from \(title)")
            }
        }
    }

    // MARK: - Helpers

    /// Refuses the automatic Face ID prompt and cancels it, leaving the lock
    /// screen with its button enabled.
    @MainActor
    private func foundationRefuseFaceID(_ app: XCUIApplication) {
        UITestFaceID.answer("nomatch", app: app)
        // The "Face Not Recognized" alert belongs to CoreAuthUI on iOS 26; cancel
        // it there (or wherever it shows), else tap where its Cancel sits.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let coreAuth = XCUIApplication(bundleIdentifier: "com.apple.CoreAuthUI")
        var cancelled = false
        let deadline = Date().addingTimeInterval(8)
        while !cancelled, Date() < deadline {
            for cancel in [coreAuth.buttons["Cancel"], springboard.alerts.buttons["Cancel"], app.alerts.buttons["Cancel"]]
            where cancel.exists && cancel.isHittable {
                cancel.tap()
                cancelled = true
                break
            }
            if !cancelled { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        }
        if !cancelled {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.588)).tap()
        }
        XCTAssertTrue(app.buttons["Unlock with Face ID"].waitForExistence(timeout: 10), "no unlock button after cancelling Face ID")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
    }

    @MainActor
    private func foundationOpenSpecimen(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.selectTab("Account"), file: file, line: line)
        let developer = app.buttons["account.row.developerSettings"]
        for _ in 0..<6 where !developer.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(developer.waitForExistence(timeout: 10), "no Developer settings row", file: file, line: line)
        developer.tap()
        XCTAssertTrue(app.navigationBars["Developer settings"].waitForExistence(timeout: 10), file: file, line: line)
        let specimen = app.buttons["developer.designSpecimen"]
        for _ in 0..<8 where !specimen.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(specimen.waitForExistence(timeout: 10), "no Design specimen row", file: file, line: line)
        specimen.tap()
        XCTAssertTrue(app.descendants(matching: .any)["specimen.scroll"].waitForExistence(timeout: 10), "specimen did not open", file: file, line: line)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    @MainActor
    private func foundationShootPages(_ app: XCUIApplication, prefix: String, maxPages: Int = 30) {
        let end = app.staticTexts["specimen.end"]
        for page in 0..<maxPages {
            RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            app.attachScreenshot(named: String(format: "%@ %02d", prefix, page), to: self)
            if end.exists && end.isHittable { break }
            app.swipeUp(velocity: .slow)
        }
    }

    @MainActor
    private func foundationScrollToTop(_ app: XCUIApplication) {
        let scroll = app.scrollViews["specimen.scroll"]
        for _ in 0..<12 {
            if scroll.exists { scroll.swipeDown(velocity: .fast) } else { app.swipeDown(velocity: .fast) }
        }
    }

    @MainActor
    private func foundationWaitForLockOffer(_ app: XCUIApplication) -> Bool {
        let offer = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", "Use ", " to open MoolaHub")).firstMatch
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let savePassword = [app.buttons["Not Now"], springboard.buttons["Not Now"]]
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let button = savePassword.first(where: { $0.exists && $0.isHittable }) {
                button.tap()
            } else if offer.exists && app.buttons["Not now"].isHittable {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        return false
    }
}
