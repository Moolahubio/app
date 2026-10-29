import XCTest

/// Smoke test: a clean launch lands on Welcome with both entry buttons, and
/// the screen passes the system accessibility audit.
final class LaunchSmokeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testCleanLaunchShowsWelcome() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state"]
        app.launch()

        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Sign in"].exists)
        let headline = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Reach it together.")).firstMatch
        XCTAssertTrue(headline.exists)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Welcome"
        shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor
    func testSignInScreenOpens() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state"]
        app.launch()

        let signIn = app.buttons["Sign in"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 15))
        signIn.tap()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Email"].exists)
        XCTAssertTrue(app.secureTextFields["Password"].exists)
    }

    @MainActor
    func testDemoSignInShowsTabs() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        app.signIn(password: password)
        for tab in ["Home", "Savings", "Groups", "Activity", "Account"] {
            XCTAssertTrue(app.tabBars.buttons[tab].exists, "missing tab \(tab)")
        }
        app.attachScreenshot(named: "Home after sign in", to: self)
    }

    @MainActor
    func testWelcomeAccessibilityAudit() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state"]
        app.launch()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 15))
        // Report each issue with its element so a failure says what to fix.
        try app.performAccessibilityAudit { issue in
            let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label.replacingOccurrences(of: "\n", with: "⏎"))' frame=\($0.frame)" } ?? "none"
            print("AUDIT ISSUE: \(issue.auditType) \(issue.compactDescription) | \(issue.detailedDescription) | element: \(element)")
            return false
        }
    }
}
