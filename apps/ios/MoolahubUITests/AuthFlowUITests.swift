import CryptoKit
import XCTest

/// End-to-end UI tests for the Auth feature (DESIGN.md §8.1–8.6), run against
/// the local dev backend through `apps/ios/scripts/ui-test.sh` with
/// `MH_BACKEND_LOG` set (emailed codes are read from the backend log).
/// Owned by the Auth engineer. Keep helpers `private` so they never collide
/// with another feature's test file.
///
/// Data etiquette: the demo account is only signed in to. Every account these
/// tests create is a fresh "QA Auth …" account whose email and username start
/// with "u" (the letter reserved for Auth), so `UITestBackendLog` finds only
/// our codes. Wrong-password and two-factor checks run on those accounts, never
/// on demo@ or the friends.
///
/// The forgot-password endpoint allows 6 requests per IP per 15 minutes for the
/// whole team; the forgot test spends 2 of them, so don't loop it.
final class AuthFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: - Backend log

    /// The test runner can read the backend log the emailed codes are written to.
    func testBackendLogIsReadable() throws {
        let mark = try UITestBackendLog.mark()
        XCTAssertGreaterThan(mark, 0, "backend log is empty or unreadable")
    }

    // MARK: - Sign up → Verify email → signed in

    @MainActor
    func testSignUpEndToEndWithFieldErrorsTakenUsernameWrongCodeAndResend() throws {
        let account = AuthTestAccount.fresh()
        let app = XCUIApplication.launchedClean()

        let createAccount = app.buttons["Create account"]
        XCTAssertTrue(createAccount.waitForExistence(timeout: 15), "Welcome did not appear")
        XCTAssertTrue(authLabelExists("Reach it together.", in: app))
        authShot(app, "01 Welcome")
        createAccount.tap()

        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5), "Sign up did not open")
        XCTAssertTrue(app.staticTexts["It takes about a minute."].exists)
        let submit = app.buttons["auth.signUp.submit"]
        XCTAssertTrue(submit.exists)
        XCTAssertFalse(submit.isEnabled, "Create account must be disabled while the form is empty")
        authShot(app, "02 Sign up")

        let name = app.textFields["Legal name \u{00B7} private"]
        let username = app.textFields["Username \u{00B7} public"]
        let email = app.textFields["Email"]
        let password = authSecureField("Password", in: app)

        // The return key moves to the next field (name → username).
        authType(account.name + "\n", into: name)

        // @ama is taken: the live check says so and the form can't be sent.
        authType("ama", into: username)
        XCTAssertTrue(authWaitForElement(labelled: "Taken", in: app, timeout: 10), "the live check never said Taken for @ama")
        XCTAssertFalse(submit.isEnabled)
        authShot(app, "03 Sign up username taken")
        authReplaceText(in: username, with: account.username)
        XCTAssertTrue(authWaitForElement(labelled: "Available", in: app, timeout: 10), "the live check never said Available")

        // Field rules (Validation) show on blur.
        authType("qa-not-an-email", into: email)
        authTap(password)
        XCTAssertTrue(app.staticTexts["Please enter a valid email address."].waitForExistence(timeout: 3), "no email error on blur")
        password.typeText("short")
        authTap(name)
        XCTAssertTrue(app.staticTexts["Password must be at least 8 characters."].waitForExistence(timeout: 3), "no password error on blur")
        XCTAssertFalse(submit.isEnabled)
        authDismissKeyboard(app)
        authShot(app, "04 Sign up field errors")

        // Fix them; return on the password field reveals the one problem left.
        authReplaceText(in: email, with: account.email)
        authReplaceSecureText(in: password, with: account.password)
        password.typeText("\n")
        XCTAssertTrue(app.staticTexts["Please enter your date of birth."].waitForExistence(timeout: 3), "no date of birth error on submit")
        XCTAssertFalse(app.staticTexts["Please enter a valid email address."].exists)
        XCTAssertFalse(app.staticTexts["Password must be at least 8 characters."].exists)
        XCTAssertFalse(submit.isEnabled)

        authDismissKeyboard(app)
        authShot(app, "05 Sign up date of birth missing")
        try authPickDateOfBirth(in: app)
        XCTAssertFalse(app.staticTexts["Please enter your date of birth."].exists)
        XCTAssertTrue(authWaitEnabled(submit), "Create account stayed disabled with a valid form")
        authShot(app, "05b Sign up filled")

        let registerMark = try UITestBackendLog.mark()
        submit.tap()

        // Verify email.
        XCTAssertTrue(app.staticTexts["Verify your email"].waitForExistence(timeout: 15), "Verify email did not open")
        XCTAssertTrue(authLabelExists(account.email, in: app), "the code screen doesn't name the email")
        let firstCode = try UITestBackendLog.code(.verification, emailInitial: "u", after: registerMark)
        let resend = app.buttons["auth.resendCode"]
        XCTAssertTrue(resend.waitForExistence(timeout: 5))
        XCTAssertTrue(resend.label.hasPrefix("Resend in "), "resend label: \(resend.label)")
        XCTAssertFalse(resend.isEnabled, "Resend code must be disabled during the cooldown")
        XCTAssertFalse(app.buttons["auth.verify.submit"].isEnabled)
        authShot(app, "06 Verify email")

        // A wrong code shows the server's message under the field and clears it.
        let codeField = app.textFields["auth.verify.code"]
        authTap(codeField)
        codeField.typeText(authWrongCode(avoiding: [firstCode]))
        let codeError = app.staticTexts["auth.verify.code.error"]
        XCTAssertTrue(codeError.waitForExistence(timeout: 10), "no inline error for a wrong code")
        XCTAssertEqual(codeError.label, "That code is invalid or has expired.")
        XCTAssertTrue(authWait(for: codeField, value: "6-digit code"), "the code field was not cleared")
        authShot(app, "07 Verify email wrong code")

        // After the 30s cooldown, Resend code sends a new code (the old one is replaced).
        XCTAssertTrue(authWait(for: resend, label: "Resend code", timeout: 40), "the cooldown never ended: \(resend.label)")
        XCTAssertTrue(resend.isEnabled)
        let resendMark = try UITestBackendLog.mark()
        resend.tap()
        XCTAssertTrue(app.staticTexts["auth.resendCode.sent"].waitForExistence(timeout: 10), "no confirmation after resend")
        XCTAssertEqual(app.staticTexts["auth.resendCode.sent"].label, "A new code is on its way.")
        XCTAssertTrue(authWait(for: resend, labelHasPrefix: "Resend in ", timeout: 5), "the cooldown didn't restart: \(resend.label)")
        XCTAssertFalse(codeError.exists, "the old code's error must clear once a new code is sent")
        let secondCode = try UITestBackendLog.code(.verification, emailInitial: "u", after: resendMark)
        authShot(app, "08 Verify email code resent")

        authTap(codeField)
        codeField.typeText(secondCode)
        authWaitForSignedIn(app)
        authShot(app, "09 Signed in after sign up")
    }

    // MARK: - Sign in

    @MainActor
    func testSignInWithTheDemoAccountAfterFieldValidationAndFooterLinks() throws {
        let password = try UITestAccount.demoPassword()
        let app = XCUIApplication.launchedClean()
        authOpenSignIn(app)
        XCTAssertTrue(app.staticTexts["Sign in to keep your savings on track."].exists)
        XCTAssertTrue(app.buttons["auth.signIn.forgotPassword"].exists)
        let submit = app.buttons["auth.signIn.submit"]
        XCTAssertFalse(submit.isEnabled, "Sign in must be disabled while the form is empty")
        authShot(app, "10 Sign in")

        // Footer links go between Sign in and Create account.
        app.buttons["auth.signIn.createAccount"].tap()
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5))
        app.buttons["auth.signUp.signIn"].tap()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))

        // An email without a domain dot fails Validation on blur; the button stays off.
        let email = app.textFields["Email"]
        let passwordField = authSecureField("Password", in: app)
        authType("demo@moolahub", into: email)
        authTap(passwordField)
        XCTAssertTrue(app.staticTexts["Please enter a valid email address."].waitForExistence(timeout: 3), "no email error on blur")
        passwordField.typeText(password)
        XCTAssertFalse(submit.isEnabled)
        authShot(app, "11 Sign in invalid email")

        authReplaceText(in: email, with: UITestAccount.demoEmail)
        XCTAssertFalse(app.staticTexts["Please enter a valid email address."].exists)
        XCTAssertTrue(authWaitEnabled(submit))
        submit.tap()
        authWaitForSignedIn(app)
        XCTAssertTrue(app.tabBars.buttons["Home"].exists)
        authShot(app, "12 Signed in as demo")
    }

    @MainActor
    func testWrongPasswordShowsTheServerMessageKeepsTheEmailAndClearsThePassword() async throws {
        let account = try await AuthTestAPI.registerVerifiedAccount()
        let app = XCUIApplication.launchedClean()
        authOpenSignIn(app)

        let email = app.textFields["Email"]
        let password = authSecureField("Password", in: app)
        let submit = app.buttons["auth.signIn.submit"]
        authType(account.email, into: email)
        authType(account.password + "-wrong", into: password)
        submit.tap()

        let banner = app.descendants(matching: .any)["auth.signIn.error"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "no error banner for a wrong password")
        XCTAssertEqual(banner.label, "Invalid email or password.")
        XCTAssertEqual(email.value as? String, account.email, "the email must stay")
        XCTAssertFalse((password.value as? String ?? "").contains("\u{2022}"), "the password must clear")
        XCTAssertFalse(submit.isEnabled)
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        authShot(app, "13 Sign in wrong password")

        authType(account.password, into: password)
        XCTAssertTrue(authWaitEnabled(submit))
        submit.tap()
        authWaitForSignedIn(app)
    }

    // MARK: - Forgot password → Reset password → Sign in

    @MainActor
    func testForgotPasswordWithTheEmailedCodeThenSignInWithTheNewPassword() async throws {
        let account = try await AuthTestAPI.registerVerifiedAccount()
        let newPassword = AuthTestAccount.makePassword()
        let app = XCUIApplication.launchedClean()
        authOpenSignIn(app)

        app.buttons["auth.signIn.forgotPassword"].tap()
        XCTAssertTrue(app.staticTexts["Forgot your password?"].waitForExistence(timeout: 5), "Forgot password did not open")
        XCTAssertTrue(app.staticTexts["Enter your email and we'll send you a reset code."].exists)
        let send = app.buttons["auth.forgot.submit"]
        XCTAssertFalse(send.isEnabled)
        authShot(app, "20 Forgot password")

        // Validation: return with a malformed email shows the field error, no request.
        let email = app.textFields["Email"]
        authType("qa-not-an-email", into: email)
        email.typeText("\n")
        XCTAssertTrue(app.staticTexts["Please enter a valid email address."].waitForExistence(timeout: 3), "no email error on submit")
        XCTAssertFalse(send.isEnabled)

        // An unknown email: the server's 404 message, verbatim.
        authReplaceText(in: email, with: "\(account.username)nobody@moolahub.test")
        XCTAssertTrue(authWaitEnabled(send))
        send.tap()
        let banner = app.descendants(matching: .any)["auth.forgot.error"]
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "no error banner for an unknown email")
        XCTAssertEqual(banner.label, "We couldn't find an account with that email address.")
        authShot(app, "21 Forgot password unknown email")

        // The real email: a reset code goes out and step 2 opens.
        authReplaceText(in: email, with: account.email)
        let mark = try UITestBackendLog.mark()
        send.tap()
        XCTAssertTrue(app.staticTexts["Reset your password"].waitForExistence(timeout: 10), "Reset password did not open")
        XCTAssertTrue(authLabelExists(account.email, in: app), "step 2 doesn't name the email")
        let resetCode = try UITestBackendLog.code(.passwordReset, emailInitial: "u", after: mark)
        let resend = app.buttons["auth.resendCode"]
        XCTAssertTrue(resend.label.hasPrefix("Resend in "), "resend label: \(resend.label)")
        XCTAssertFalse(resend.isEnabled)
        let reset = app.buttons["auth.reset.submit"]
        XCTAssertFalse(reset.isEnabled)
        authShot(app, "22 Reset password")

        // Passwords that don't match.
        let codeField = app.textFields["Reset code"]
        let newField = authSecureField("New password", in: app)
        let confirmField = authSecureField("Confirm new password", in: app)
        authType(newPassword, into: newField)
        authType(newPassword + "x", into: confirmField)
        authTap(codeField)
        XCTAssertTrue(app.staticTexts["Passwords don't match."].waitForExistence(timeout: 3), "no mismatch error")
        XCTAssertFalse(reset.isEnabled)
        authShot(app, "23 Reset password mismatch")

        // A wrong code: the server's message under the code field; everything clears.
        codeField.typeText(authWrongCode(avoiding: [resetCode]))
        authReplaceSecureText(in: confirmField, with: newPassword)
        XCTAssertTrue(authWaitEnabled(reset))
        reset.tap()
        XCTAssertTrue(app.staticTexts["That code is invalid or has expired."].waitForExistence(timeout: 10), "no inline error for a wrong code")
        XCTAssertTrue(authWait(for: codeField, value: "6-digit code"), "the code field was not cleared")
        authShot(app, "24 Reset password wrong code")

        // The emailed code and a new password.
        authType(resetCode, into: codeField)
        authType(newPassword, into: newField)
        authType(newPassword, into: confirmField)
        XCTAssertTrue(authWaitEnabled(reset))
        reset.tap()

        let resetBanner = app.descendants(matching: .any)["auth.signIn.resetBanner"]
        XCTAssertTrue(resetBanner.waitForExistence(timeout: 15), "Sign in with the reset banner did not appear")
        XCTAssertEqual(resetBanner.label, "Your password has been reset. Sign in with your new password.")
        authShot(app, "25 Sign in after reset")

        let oldPasswordStatus = try await AuthTestAPI.loginStatus(email: account.email, password: account.password)
        XCTAssertEqual(oldPasswordStatus, 401, "the old password still works")
        authType(account.email, into: app.textFields["Email"])
        authType(newPassword, into: authSecureField("Password", in: app))
        app.buttons["auth.signIn.submit"].tap()
        authWaitForSignedIn(app)
    }

    // MARK: - Two-factor

    @MainActor
    func testTwoFactorWithAnAuthenticatorCodeAfterAWrongCode() async throws {
        let account = try await AuthTestAPI.registerVerifiedAccount(enableTwoFactor: true)
        let secret = try XCTUnwrap(account.totpSecret)
        let app = XCUIApplication.launchedClean()
        authSignInToTwoFactor(app, account: account)

        let field = app.textFields["Authenticator code"]
        let submit = app.buttons["auth.twoFactor.submit"]
        XCTAssertTrue(field.exists)
        XCTAssertFalse(submit.isEnabled)
        authShot(app, "30 Two-factor")

        // Five digits can't be sent; a sixth that doesn't match shows the 401 inline.
        authTap(field)
        field.typeText("12345")
        XCTAssertFalse(submit.isEnabled, "five digits must not be sendable")
        authReplaceText(in: field, with: authWrongCode(avoiding: AuthTOTP.acceptedCodes(secret: secret)))
        XCTAssertTrue(authWaitEnabled(submit))
        submit.tap()
        XCTAssertTrue(
            app.staticTexts["That code didn't match. Try a current code or a backup code."].waitForExistence(timeout: 10),
            "no inline error for a wrong authenticator code"
        )
        XCTAssertTrue(authWait(for: field, value: "6-digit code"), "the code field was not cleared")
        XCTAssertFalse(app.tabBars.firstMatch.exists)
        authShot(app, "31 Two-factor wrong code")

        // Backup-code mode and back.
        let toggle = app.buttons["auth.twoFactor.toggleMode"]
        XCTAssertEqual(toggle.label, "Use a backup code")
        toggle.tap()
        XCTAssertTrue(app.textFields["Backup code"].waitForExistence(timeout: 3))
        XCTAssertTrue(
            authWait(app.textFields["Backup code"], NSPredicate(format: "hasKeyboardFocus == true"), timeout: 15),
            "the backup code field did not take focus after switching modes"
        )
        XCTAssertEqual(toggle.label, "Use an authenticator code")
        XCTAssertFalse(app.staticTexts["That code didn't match. Try a current code or a backup code."].exists)
        authShot(app, "32 Two-factor backup code mode")
        toggle.tap()
        XCTAssertTrue(app.textFields["Authenticator code"].waitForExistence(timeout: 3))

        authType(AuthTOTP.code(secret: secret, at: Date()), into: app.textFields["Authenticator code"])
        XCTAssertTrue(authWaitEnabled(submit))
        submit.tap()
        authWaitForSignedIn(app)
    }

    @MainActor
    func testTwoFactorWithABackupCodeWhichThenStopsWorking() async throws {
        let account = try await AuthTestAPI.registerVerifiedAccount(enableTwoFactor: true)
        let backupCode = try XCTUnwrap(account.backupCodes.first)
        let app = XCUIApplication.launchedClean()
        authSignInToTwoFactor(app, account: account)

        app.buttons["auth.twoFactor.toggleMode"].tap()
        let field = app.textFields["Backup code"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        authType(backupCode, into: field)
        let submit = app.buttons["auth.twoFactor.submit"]
        XCTAssertTrue(authWaitEnabled(submit))
        submit.tap()
        authWaitForSignedIn(app)

        // Backup codes are single use.
        let status = try await AuthTestAPI.twoFactorLoginStatus(email: account.email, password: account.password, code: backupCode)
        XCTAssertEqual(status, 401, "a used backup code still works")
    }

    // MARK: - Wave 1: "How did you hear about MoolaHub?" (account.md §17 test 11)

    /// AC-21's UI half and AC-23: the optional menu starts on "Choose one",
    /// Create account enables with the five required fields alone, the menu
    /// holds the seven names and "Prefer not to say", "Telegram" becomes the
    /// value, and the server takes the key (an unknown key would be a 400).
    @MainActor
    func testSignUpReferralSourceMenu() throws {
        let account = AuthTestAccount.fresh()
        let app = XCUIApplication.launchedClean()
        let createAccount = app.buttons["Create account"]
        XCTAssertTrue(createAccount.waitForExistence(timeout: 15), "Welcome did not appear")
        createAccount.tap()
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5), "Sign up did not open")

        let submit = app.buttons["auth.signUp.submit"]
        XCTAssertFalse(submit.isEnabled)
        XCTAssertTrue(authLabelExists("Fill in every required field to continue.", in: app), "the reason must name required fields")
        let referral = app.buttons["auth.signUp.referralSource"]
        XCTAssertTrue(referral.waitForExistence(timeout: 5), "the referral menu is missing")
        XCTAssertEqual(referral.label, "How did you hear about MoolaHub? \u{00B7} optional")
        XCTAssertEqual(referral.value as? String, "Choose one")

        // The five required fields alone enable Create account (AC-23).
        authType(account.name, into: app.textFields["Legal name \u{00B7} private"])
        authType(account.username, into: app.textFields["Username \u{00B7} public"])
        XCTAssertTrue(authWaitForElement(labelled: "Available", in: app, timeout: 10), "the live check never said Available")
        authType(account.email, into: app.textFields["Email"])
        authTypeNewPassword(account.password, into: authSecureField("Password", in: app), in: app)
        authDismissKeyboard(app)
        try authPickDateOfBirth(in: app)
        XCTAssertTrue(authWaitEnabled(submit), "Create account must enable without the optional field")
        XCTAssertEqual(referral.value as? String, "Choose one")

        // The menu: the server's seven in its order, then Prefer not to say.
        authTap(referral)
        let names = ["X (Twitter)", "Telegram", "WhatsApp", "Discord", "LinkedIn", "Friends or family", "Somewhere else", "Prefer not to say"]
        let items = names.map { authMenuItem($0, in: app) }
        XCTAssertTrue(items[0].waitForExistence(timeout: 5), "the menu did not open")
        for (name, item) in zip(names, items) {
            XCTAssertTrue(item.exists, "menu item \(name) missing")
        }
        for (upper, lower) in zip(items, items.dropFirst()) {
            XCTAssertLessThan(upper.frame.minY, lower.frame.minY, "menu order: \(upper.label) before \(lower.label)")
        }
        // The separator before "Prefer not to say" (B1.14 amended): a wider
        // gap than between the server's seven.
        let gaps = zip(items, items.dropFirst()).map { $1.frame.minY - $0.frame.maxY }
        let gapList = XCTAttachment(string: zip(names.dropFirst(), gaps).map { "before \($0): \($1)" }.joined(separator: "\n"))
        gapList.name = "Gaps between menu items"
        gapList.lifetime = .keepAlways
        add(gapList)
        XCTAssertGreaterThan(gaps[6], (gaps.dropLast().max() ?? 0) + 2, "no separator before Prefer not to say")
        authShot(app, "60 Sign up referral menu")
        // A choice after the separator sets the same value.
        items[7].tap()
        XCTAssertTrue(authWait(for: referral, value: "Prefer not to say"), "value after choosing: \(String(describing: referral.value))")
        XCTAssertTrue(submit.isEnabled)
        authShot(app, "60b Sign up referral Prefer not to say")
        authTap(referral)
        XCTAssertTrue(items[1].waitForExistence(timeout: 5), "the menu did not open again")
        items[1].tap()
        XCTAssertTrue(authWait(for: referral, value: "Telegram"), "value after choosing: \(String(describing: referral.value))")
        XCTAssertTrue(submit.isEnabled)
        authShot(app, "61 Sign up referral Telegram")

        let mark = try UITestBackendLog.mark()
        submit.tap()
        XCTAssertTrue(app.staticTexts["Verify your email"].waitForExistence(timeout: 15), "the server refused the referral key")
        _ = try UITestBackendLog.code(.verification, emailInitial: "u", after: mark)
    }

    // MARK: - Wave 1: Forgot password pre-fill (test 12)

    /// AC-19: a valid Sign in email arrives on Forgot password, and Send reset
    /// code is enabled at once. Nothing is sent.
    @MainActor
    func testForgotPasswordPrefillsAValidSignInEmail() throws {
        let app = XCUIApplication.launchedClean()
        authOpenSignIn(app)
        authType(UITestAccount.demoEmail, into: app.textFields["Email"])
        authTap(app.buttons["auth.signIn.forgotPassword"])
        XCTAssertTrue(app.staticTexts["Forgot your password?"].waitForExistence(timeout: 5), "Forgot password did not open")
        let email = app.textFields["Email"]
        XCTAssertTrue(authWait(for: email, value: UITestAccount.demoEmail), "email: \(String(describing: email.value))")
        XCTAssertTrue(app.buttons["auth.forgot.submit"].isEnabled, "Send reset code must be enabled at once")
        XCTAssertFalse(app.staticTexts["Please enter a valid email address."].exists)
        authDismissKeyboard(app)
        authShot(app, "62 Forgot password pre-filled")

        // Back on Sign in, its email is as it was.
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Email"].value as? String, UITestAccount.demoEmail)
    }

    /// AC-20: an invalid Sign in email is not carried over: an empty field, a
    /// disabled button and no error.
    @MainActor
    func testForgotPasswordIgnoresAnInvalidSignInEmail() throws {
        let app = XCUIApplication.launchedClean()
        authOpenSignIn(app)
        authType("qa-not-an-email", into: app.textFields["Email"])
        authTap(app.buttons["auth.signIn.forgotPassword"])
        XCTAssertTrue(app.staticTexts["Forgot your password?"].waitForExistence(timeout: 5), "Forgot password did not open")
        let email = app.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        XCTAssertEqual(email.value as? String ?? "", "", "an invalid email must not be pre-filled")
        XCTAssertFalse(app.buttons["auth.forgot.submit"].isEnabled)
        XCTAssertFalse(app.staticTexts["Please enter a valid email address."].exists, "no error on arrival")
    }

    // MARK: - Dark mode, largest text, accessibility audit

    @MainActor
    func testAuthScreensInDarkModeAndAtTheLargestTextSize() throws {
        addTeardownBlock { @MainActor in XCUIDevice.shared.appearance = .light }
        XCUIDevice.shared.appearance = .dark
        let app = XCUIApplication.launchedClean()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1)
        authShot(app, "40 Welcome dark")

        authOpenSignIn(app)
        authType("demo@moolahub", into: app.textFields["Email"])
        authTap(authSecureField("Password", in: app))
        XCTAssertTrue(app.staticTexts["Please enter a valid email address."].waitForExistence(timeout: 3))
        authDismissKeyboard(app)
        authShot(app, "41 Sign in dark")

        authTap(app.buttons["auth.signIn.createAccount"])
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5))
        authType("ama", into: app.textFields["Username \u{00B7} public"])
        XCTAssertTrue(authWaitForElement(labelled: "Taken", in: app, timeout: 10))
        authDismissKeyboard(app)
        authShot(app, "42 Sign up dark")

        app.buttons["auth.signUp.signIn"].tap()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        app.buttons["auth.signIn.forgotPassword"].tap()
        XCTAssertTrue(app.staticTexts["Forgot your password?"].waitForExistence(timeout: 5))
        authDismissKeyboard(app)
        authShot(app, "43 Forgot password dark")
        app.terminate()

        // Largest accessibility text size (AX5), light.
        XCUIDevice.shared.appearance = .light
        let large = XCUIApplication()
        large.launchArguments = ["-mh-reset-state", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        large.launch()
        XCTAssertTrue(large.buttons["Create account"].waitForExistence(timeout: 15))
        authShot(large, "50 Welcome AX5")
        authScrollUp(large)
        authShot(large, "51 Welcome AX5 scrolled")

        authOpenSignIn(large)
        authDismissKeyboard(large)
        authShot(large, "52 Sign in AX5")
        // The footer prompt scrolls with the form at accessibility sizes.
        let createAccount = large.buttons["auth.signIn.createAccount"]
        authReveal(createAccount)
        XCTAssertTrue(createAccount.isHittable, "Create an account must be reachable at AX5")
        authShot(large, "53 Sign in AX5 scrolled")

        createAccount.tap()
        XCTAssertTrue(large.staticTexts["Create your account"].waitForExistence(timeout: 5))
        // Fields grow with the text size (the default field is 52pt tall) and
        // keep their placeholder: what the audit's text-field warning is about.
        let nameField = large.textFields["Legal name \u{00B7} private"]
        authReveal(nameField)
        XCTAssertGreaterThan(nameField.frame.height, 70, "the name field did not grow at AX5")
        XCTAssertEqual(nameField.value as? String, "e.g. Ama Mensah")
        authShot(large, "54 Sign up AX5")
        for index in 1...3 {
            authScrollUp(large)
            authShot(large, "5\(4 + index) Sign up AX5 scrolled \(index)")
        }
        // "How did you hear about MoolaHub?" at AX5: the label wraps and the
        // control grows with its value (account.md B1.14 amended).
        let referral = large.buttons["auth.signUp.referralSource"]
        authReveal(referral)
        XCTAssertTrue(referral.isHittable, "the referral menu must be reachable at AX5")
        XCTAssertGreaterThan(referral.frame.height, 52, "the referral menu did not grow at AX5")
        authShot(large, "58 Sign up AX5 referral")
        // The open menu at AX5, with the separator before its last choice.
        // The menu scrolls there (three pages), so its end is swiped to.
        authTap(referral)
        XCTAssertTrue(authMenuItem("X (Twitter)", in: large).waitForExistence(timeout: 5), "the referral menu did not open at AX5")
        authShot(large, "58b Sign up AX5 referral menu")
        let menu = large.collectionViews.firstMatch
        let preferNotToSay = authMenuItem("Prefer not to say", in: large)
        var swipes = 0
        while !preferNotToSay.isHittable && swipes < 6 {
            menu.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(preferNotToSay.isHittable, "Prefer not to say must be reachable in the menu at AX5")
        authShot(large, "58c Sign up AX5 referral menu end")
        preferNotToSay.tap()
        XCTAssertTrue(authWait(for: referral, value: "Prefer not to say"), "value after choosing: \(String(describing: referral.value))")
        let signIn = large.buttons["auth.signUp.signIn"]
        authReveal(signIn)
        XCTAssertTrue(signIn.isHittable, "Sign in must be reachable at AX5")
    }

    @MainActor
    func testSignInAndSignUpPassTheAccessibilityAudit() throws {
        let app = XCUIApplication.launchedClean()
        authOpenSignIn(app)
        authDismissKeyboard(app)
        try authAudit(app, screen: "Sign in")

        app.buttons["auth.signIn.createAccount"].tap()
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5))
        // The audit runs with the optional referral menu on the form (test 13).
        // At rest the menu sits under the pinned bar's reason line and footer
        // (account.md B1.14 amended), where the audit measures the bar's
        // pixels; it is audited again below, scrolled out from under the bar.
        let referral = app.buttons["auth.signUp.referralSource"]
        XCTAssertTrue(referral.exists, "the referral menu is missing")
        authDismissKeyboard(app)
        try authAudit(app, screen: "Sign up", coveredUnplacedSource: referral)

        // At rest the date of birth control sits under the pinned bar (DESIGN.md
        // B1.14), which is why the audit above skips it. Scrolled to the end it
        // shows whole, above the bar (B1.0.2: the content ends 24 pt above it).
        // It isn't audited there: the audit first scrolls the title back into
        // view, which puts the control's lower edge under the bar's edge effect
        // again (measured 2026-10-26: 630–682 before the audit, 660–712 in it).
        let dateOfBirth = app.buttons["auth.signUp.dateOfBirth"]
        let submit = app.buttons["auth.signUp.submit"]
        for _ in 0..<2 { authScrollUp(app) }
        XCTAssertTrue(authWaitUntilSettled([dateOfBirth, referral, submit]), "the form did not settle after scrolling to the end")
        authShot(app, "Sign up scrolled to the end")
        XCTAssertTrue(dateOfBirth.isHittable, "the date of birth control did not scroll out from under the bar")
        // The bar starts 12 pt above its button (B1.0.3).
        XCTAssertLessThanOrEqual(
            dateOfBirth.frame.maxY, submit.frame.minY - 12,
            "at the end of the form the date of birth control must sit above the pinned bar"
        )
        // The referral menu, last on the form, shows whole above the bar here
        // and is audited where it can be seen, with nothing tolerated.
        XCTAssertTrue(referral.isHittable, "the referral menu did not scroll out from under the bar")
        XCTAssertLessThanOrEqual(
            referral.frame.maxY, submit.frame.minY - 12,
            "at the end of the form the referral menu must sit above the pinned bar"
        )
        // Contrast is audited alone on this settled state, before any audit
        // type can resize text, then the other types. In one audit of every
        // type, the Dynamic Type pass grew the text and gave it back, leaving
        // the form 33 pt lower (2026-10-28: date 527 to 560, referral 630 to
        // 663, its lower edge under the bar), and the contrast pass then
        // failed both placeholders in 6 of 6 runs, though they measure 5.04:1
        // (#666666 on #F0F0F0) on the shot taken before the audit.
        try authAudit(app, screen: "Sign up, end of the form (contrast)", types: .contrast)
        try authAudit(app, screen: "Sign up, end of the form", types: XCUIAccessibilityAuditType.all.subtracting(.contrast))
    }

    // MARK: - Review shots in the simulator's current settings

    /// Screenshots of the signed-out screens reachable without creating an
    /// account, in whatever appearance, contrast and text size the simulator
    /// has (`xcrun simctl ui <sim> appearance dark`, `increase_contrast
    /// enabled`, `content_size …`). Requests: one failed sign-in with a fresh
    /// address that has no account, and username availability checks.
    @MainActor
    func testSignedOutScreensInCurrentSettings() throws {
        let app = XCUIApplication.launchedClean()
        XCTAssertTrue(app.buttons["Create account"].waitForExistence(timeout: 15), "Welcome did not appear")
        authShot(app, "R01 Welcome")

        authOpenSignIn(app)
        authShot(app, "R02 Sign in")

        // A wrong password: the error banner, the email kept, the password cleared.
        let email = app.textFields["Email"]
        let password = authSecureField("Password", in: app)
        let submit = app.buttons["auth.signIn.submit"]
        authType("\(AuthTestAccount.fresh().username)-nobody@moolahub.test", into: email)
        authType(AuthTestAccount.makePassword(), into: password)
        XCTAssertTrue(authWaitEnabled(submit))
        submit.tap()
        let banner = app.descendants(matching: .any)["auth.signIn.error"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "no error banner for a wrong password")
        XCTAssertEqual(banner.label, "Invalid email or password.")
        authDismissKeyboard(app)
        authShot(app, "R03 Sign in error")

        // A malformed email: the field error on blur.
        authReplaceText(in: email, with: "demo@moolahub")
        authTap(password)
        XCTAssertTrue(app.staticTexts["Please enter a valid email address."].waitForExistence(timeout: 3), "no email error on blur")
        authDismissKeyboard(app)
        authShot(app, "R04 Sign in field error")

        authTap(app.buttons["auth.signIn.createAccount"])
        XCTAssertTrue(app.staticTexts["Create your account"].waitForExistence(timeout: 5), "Sign up did not open")
        authShot(app, "R05 Sign up")

        // @ama is taken; a malformed email and a short password show their errors.
        authType("QA Auth User", into: app.textFields["Legal name \u{00B7} private"])
        authType("ama", into: app.textFields["Username \u{00B7} public"])
        XCTAssertTrue(authWaitForElement(labelled: "Taken", in: app, timeout: 10), "the live check never said Taken for @ama")
        authType("qa-not-an-email", into: app.textFields["Email"])
        let signUpPassword = authSecureField("Password", in: app)
        authTap(signUpPassword)
        XCTAssertTrue(app.staticTexts["Please enter a valid email address."].waitForExistence(timeout: 3), "no email error on blur")
        signUpPassword.typeText("short")
        authTap(app.textFields["Legal name \u{00B7} private"])
        XCTAssertTrue(app.staticTexts["Password must be at least 8 characters."].waitForExistence(timeout: 3), "no password error on blur")
        authDismissKeyboard(app)
        authShot(app, "R06 Sign up errors")

        // The date of birth popover.
        let dateOfBirth = app.buttons["auth.signUp.dateOfBirth"]
        XCTAssertEqual(dateOfBirth.value as? String, "Choose a date")
        authTap(dateOfBirth)
        let dayPredicate = NSPredicate(format: "label BEGINSWITH 'Monday' OR label BEGINSWITH 'Tuesday' OR label BEGINSWITH 'Wednesday' OR label BEGINSWITH 'Thursday' OR label BEGINSWITH 'Friday' OR label BEGINSWITH 'Saturday' OR label BEGINSWITH 'Sunday'")
        XCTAssertTrue(app.buttons.matching(dayPredicate).firstMatch.waitForExistence(timeout: 5), "the calendar did not open")
        authShot(app, "R07 Sign up date of birth")
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.waitForExistence(timeout: 2) { dismiss.tap() }
        XCTAssertTrue(app.buttons.matching(dayPredicate).firstMatch.waitForNonExistence(timeout: 3), "the calendar did not close")

        // "How did you hear about MoolaHub?": at the end of the form, open,
        // then with a choice (nothing is submitted).
        let referral = app.buttons["auth.signUp.referralSource"]
        authReveal(referral)
        authShot(app, "R08 Sign up referral field")
        authTap(referral)
        let telegram = authMenuItem("Telegram", in: app)
        XCTAssertTrue(telegram.waitForExistence(timeout: 5), "the referral menu did not open")
        authShot(app, "R09 Sign up referral menu")
        telegram.tap()
        XCTAssertTrue(authWait(for: referral, value: "Telegram"))
        authShot(app, "R10 Sign up referral chosen")

        // Forgot password with Sign in's valid email carried over.
        authTap(app.buttons["auth.signUp.signIn"])
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5))
        authReplaceText(in: app.textFields["Email"], with: UITestAccount.demoEmail)
        authTap(app.buttons["auth.signIn.forgotPassword"])
        XCTAssertTrue(app.staticTexts["Forgot your password?"].waitForExistence(timeout: 5))
        authDismissKeyboard(app)
        authShot(app, "R11 Forgot password pre-filled")
    }

    // MARK: - Helpers (private)

    @MainActor
    private func authOpenSignIn(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let entry = app.buttons["Sign in"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "Welcome did not appear", file: file, line: line)
        entry.tap()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 5), "Sign in did not open", file: file, line: line)
    }

    @MainActor
    private func authSignInToTwoFactor(_ app: XCUIApplication, account: AuthTestAccount, file: StaticString = #filePath, line: UInt = #line) {
        authOpenSignIn(app, file: file, line: line)
        authType(account.email, into: app.textFields["Email"])
        authType(account.password, into: authSecureField("Password", in: app))
        app.buttons["auth.signIn.submit"].tap()
        XCTAssertTrue(app.staticTexts["Two-factor authentication"].waitForExistence(timeout: 15), "Two-factor did not open", file: file, line: line)
        XCTAssertTrue(
            app.staticTexts["Enter the 6-digit code from your authenticator app, or a backup code."].exists,
            file: file, line: line
        )
    }

    /// Waits for the tabs (closing the one-time app lock offer if the
    /// simulator has a passcode and it appears).
    @MainActor
    private func authWaitForSignedIn(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 25), "the tabs did not appear", file: file, line: line)
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 1) { notNow.tap() }
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5), file: file, line: line)
    }

    /// Opens the date-of-birth calendar, picks the first day of the month it
    /// shows (always in the past: the latest allowed day is yesterday) and
    /// closes the popover.
    @MainActor
    private func authPickDateOfBirth(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let field = app.buttons["auth.signUp.dateOfBirth"]
        XCTAssertEqual(field.value as? String, "Choose a date", file: file, line: line)
        authTap(field)
        let dayPredicate = NSPredicate(format: "label BEGINSWITH 'Monday' OR label BEGINSWITH 'Tuesday' OR label BEGINSWITH 'Wednesday' OR label BEGINSWITH 'Thursday' OR label BEGINSWITH 'Friday' OR label BEGINSWITH 'Saturday' OR label BEGINSWITH 'Sunday'")
        let days = app.buttons.matching(dayPredicate)
        guard days.firstMatch.waitForExistence(timeout: 5) else {
            XCTFail("the calendar did not open: \(app.debugDescription)", file: file, line: line)
            return
        }
        authShot(app, "05a Sign up date of birth calendar")
        days.element(boundBy: 0).tap()
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.waitForExistence(timeout: 2) {
            dismiss.tap()
        }
        XCTAssertTrue(days.firstMatch.waitForNonExistence(timeout: 3), "the calendar did not close", file: file, line: line)
        let value = field.value as? String ?? ""
        XCTAssertNotEqual(value, "Choose a date", "picking a day didn't set the date", file: file, line: line)
    }

    /// Moves `element` out from under the pinned bottom bar (main button and
    /// footer prompt, above the keyboard when it's up) or the navigation bar,
    /// then taps it. XCUITest doesn't see that overlap and would tap the bar.
    /// Taps `element` after moving it out from under the pinned bar. For a
    /// text field, waits until it has keyboard focus and taps again if the
    /// tap was lost (the shared Mac is often slow to bring the keyboard up).
    @MainActor
    private func authTap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        authReveal(element)
        // Read the type before tapping: a tapped button may navigate away.
        let isTextInput = [.textField, .secureTextField].contains(element.elementType)
        element.tap()
        guard isTextInput else { return }
        authEnsureFocus(element, file: file, line: line) { element.tap() }
    }

    /// Waits for `field` to have keyboard focus, calling `retap` (after
    /// revealing the field again) up to three times if it doesn't.
    @MainActor
    private func authEnsureFocus(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line, retap: () -> Void) {
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        for _ in 0..<3 {
            if authWait(field, focused, timeout: 15) { return }
            authReveal(field)
            retap()
        }
        XCTAssertTrue(authWait(field, focused, timeout: 15), "the field never took keyboard focus", file: file, line: line)
    }

    /// A screenshot once keyboard and navigation animations have settled
    /// (they lag on a busy Mac).
    @MainActor
    private func authShot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1.5)
        app.attachScreenshot(named: name, to: self)
    }

    /// Scrolls the screen's content up by dragging in the left gutter, above
    /// the pinned bottom bar (a swipe on the scroll view's center can land on
    /// the bar's buttons at large text sizes).
    @MainActor
    private func authScrollUp(_ app: XCUIApplication) {
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.45))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.12)))
    }

    /// Waits until `elements`' frames read the same three times in a row,
    /// 0.25 s apart (a scroll's deceleration, the bar's settling), at most
    /// `timeout` seconds. Returns whether they settled.
    @MainActor
    private func authWaitUntilSettled(_ elements: [XCUIElement], timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var last = elements.map(\.frame)
        var steady = 1
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            let frames = elements.map(\.frame)
            steady = frames == last ? steady + 1 : 1
            if steady >= 3 { return true }
            last = frames
        }
        return false
    }

    @MainActor
    private func authReveal(_ element: XCUIElement) {
        let app = XCUIApplication()
        let mainButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'auth.' AND identifier ENDSWITH '.submit'")).firstMatch
        let navigationBar = app.navigationBars.firstMatch
        // Drag in the left gutter of the screen's scroll view (no fields there).
        // Not `app.scrollViews.firstMatch`: with the keyboard up that can be
        // the keyboard's suggestion bar.
        let window = app.windows.firstMatch
        for _ in 0..<8 {
            guard element.exists else { return }
            let bottomLimit = mainButton.exists ? mainButton.frame.minY - 24 : app.frame.maxY
            let topLimit = navigationBar.exists ? navigationBar.frame.maxY + 8 : app.frame.minY + 60
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.35))
            if element.frame.maxY > bottomLimit {
                let distance = min(element.frame.maxY - bottomLimit + 40, 240)
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -distance)))
            } else if element.frame.minY < topLimit {
                let distance = min(topLimit - element.frame.minY + 40, 240)
                start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: distance)))
            } else {
                return
            }
        }
    }

    @MainActor
    private func authType(_ text: String, into field: XCUIElement) {
        authTap(field)
        field.typeText(text)
    }

    @MainActor
    private func authReplaceText(in field: XCUIElement, with text: String) {
        let current = field.value as? String ?? ""
        authReveal(field)
        // Tap past the end of the text so the cursor lands at the end. A
        // trailing status label (username) focuses the field the same way.
        let end = field.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5))
        end.tap()
        authEnsureFocus(field) { end.tap() }
        if !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 2))
        }
        if !text.isEmpty { field.typeText(text) }
    }

    /// Types a new password into Sign up's password field (`.newPassword`).
    /// With a valid email above it, iOS can cover the keyboard with its own
    /// "Use Strong Password?" sheet as the field takes focus, which swallows
    /// the typing: close it (its "Close" button), make sure the field has the
    /// keyboard, then type, and check every character arrived.
    @MainActor
    private func authTypeNewPassword(_ text: String, into field: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let suggestion = app.buttons["GenerateStrongPasswordButton"]
        let close = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label == %@", "xmark", "Close")).firstMatch
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        authTap(field)
        for _ in 0..<3 {
            if suggestion.waitForExistence(timeout: 3), close.exists {
                close.tap()
                _ = suggestion.waitForNonExistence(timeout: 5)
            }
            if authWait(field, focused, timeout: 3), !suggestion.exists { break }
            authTap(field)
        }
        app.typeText(text)
        let typed = (field.value as? String ?? "").count
        XCTAssertEqual(typed, text.count, "the password was not typed in full", file: file, line: line)
    }

    /// A choice in an open system menu (`PickerMenuField`): iOS exposes its
    /// rows as buttons or menu items, depending on the version.
    @MainActor
    private func authMenuItem(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let types = [XCUIElement.ElementType.button, .menuItem, .cell].map { NSNumber(value: $0.rawValue) }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@ AND identifier != %@", label, types, "auth.signUp.referralSource"))
            .firstMatch
    }

    /// A password field by its label. Once a filled secure field takes focus
    /// again, iOS 26 reports it as a plain text field (showing the last
    /// character), so match either type.
    @MainActor
    private func authSecureField(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let types = [XCUIElement.ElementType.secureTextField, .textField].map { NSNumber(value: $0.rawValue) }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ AND elementType IN %@", label, types)).firstMatch
    }

    /// Secure fields don't expose their text; clear generously and retype
    /// (typing into a refocused secure field replaces its contents anyway).
    @MainActor
    private func authReplaceSecureText(in field: XCUIElement, with text: String) {
        authReveal(field)
        // The middle, away from the show/hide button on the right.
        let middle = field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        middle.tap()
        authEnsureFocus(field) { middle.tap() }
        let app = XCUIApplication()
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40))
        app.typeText(text)
    }

    @MainActor
    private func authDismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        // Drag down through the keyboard (`.scrollDismissesKeyboard(.interactively)`).
        let window = app.windows.firstMatch
        let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.3))
        start.press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.025, dy: 0.98)))
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func authLabelExists(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 3) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    @MainActor
    private func authWaitForElement(labelled label: String, in app: XCUIApplication, timeout: TimeInterval) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
            .waitForExistence(timeout: timeout)
    }

    @MainActor
    private func authWaitEnabled(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        authWait(element, NSPredicate(format: "exists == true AND isEnabled == true"), timeout: timeout)
    }

    @MainActor
    private func authWait(for element: XCUIElement, value: String, timeout: TimeInterval = 5) -> Bool {
        authWait(element, NSPredicate(format: "exists == true AND value == %@", value), timeout: timeout)
    }

    @MainActor
    private func authWait(for element: XCUIElement, label: String, timeout: TimeInterval = 5) -> Bool {
        authWait(element, NSPredicate(format: "exists == true AND label == %@", label), timeout: timeout)
    }

    @MainActor
    private func authWait(for element: XCUIElement, labelHasPrefix prefix: String, timeout: TimeInterval = 5) -> Bool {
        authWait(element, NSPredicate(format: "exists == true AND label BEGINSWITH %@", prefix), timeout: timeout)
    }

    @MainActor
    private func authWait(_ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    /// A 6-digit code that is none of `codes`.
    private func authWrongCode(avoiding codes: [String]) -> String {
        var candidate = 0
        while codes.contains(String(format: "%06d", candidate)) { candidate += 111_111 }
        return String(format: "%06d", candidate)
    }

    /// The system accessibility audit of `types` (every type by default);
    /// every issue fails the test. A run that times out ("Audit failed to
    /// complete in time", which happens on a busy Mac) is repeated, up to
    /// three runs.
    ///
    /// `coveredUnplacedSource`: a control the pinned bar covers at rest. The
    /// audit can report a contrast issue for a node it cannot name (no
    /// element) inside such a control (measured 2026-10-28 for Sign up's
    /// referral menu under the reason line and footer: one issue on its
    /// "Choose one" text, one with no element). Some runs attach that same
    /// issue ("Contrast failed for SwiftUI.AccessibilityNode") to the bar's
    /// own element that lies over the control instead (the footer's "Sign in",
    /// 796–840 pt over the menu's 815–867 pt, in every verifier run on
    /// 2026-10-28), where the audit measures the covered control showing
    /// through the bar's soft edge. While that control is covered, that one
    /// contrast issue, with no element or on such a bar element, is logged and
    /// attached instead of failing; a second such issue fails, since the
    /// covered control accounts for one only. The caller audits the control,
    /// and the bar over it, again where the control can be seen, with nothing
    /// tolerated.
    @MainActor
    private func authAudit(
        _ app: XCUIApplication,
        screen: String,
        types: XCUIAccessibilityAuditType = .all,
        coveredUnplacedSource: XCUIElement? = nil
    ) throws {
        var attempt = 0
        while true {
            attempt += 1
            var issues: [String] = []
            var unplaced: [String] = []
            do {
                try app.performAccessibilityAudit(for: types) { issue in
                    // SwiftUI text fields scale with Dynamic Type themselves, so
                    // UIKit's adjustsFontForContentSizeCategory stays off and the
                    // audit warns that a field's text "may be clipped at larger
                    // Dynamic Type sizes". DESIGN.md v2 A11.2 item 12 hoped SF Pro
                    // would make this unnecessary; it does not: a run without this
                    // tolerance on 2026-10-26 (iOS 26.5, SF Pro text-style fonts)
                    // still reported it for the Sign up field that shows a
                    // placeholder ("Legal name · private"). The AX5 test checks the
                    // real thing (the fields grow and show their text), so that
                    // warning, and only that one, is not a failure here.
                    if issue.auditType == .textClipped, issue.element?.elementType == .textField,
                       issue.detailedDescription.contains("larger Dynamic Type sizes") {
                        // Logged, so every run shows whether it is still needed.
                        print("AUDIT TOLERATED, text field Dynamic Type warning: \(issue.compactDescription) | '\(issue.element?.label ?? "")' frame=\(issue.element?.frame ?? .zero)")
                        return true
                    }
                    // An element that the pinned bar or the navigation bar covers
                    // can't be seen or touched where it is, and the audit measures
                    // the bar's pixels for it: on 2026-10-26 it reported "Contrast
                    // nearly passed" for Sign up's date of birth placeholder, which
                    // at rest sits under the disabled "Create account" button
                    // (#707070 on #DEDEDE, exempt as a disabled control). Such an
                    // element is skipped here (and logged) and audited where it can
                    // be seen: the Sign up audit runs again scrolled to the end.
                    if let element = issue.element, self.authIsCoveredByBars(element, in: app) {
                        print("AUDIT SKIPPED, covered by a bar: \(issue.compactDescription) | \(element.elementType.rawValue) '\(element.label)' frame=\(element.frame)")
                        return true
                    }
                    if issue.auditType == .contrast, let source = coveredUnplacedSource,
                       source.exists, self.authIsCoveredByBars(source, in: app) {
                        // nil when the issue has no element.
                        let onBarOverSource = issue.element.map { element in
                            issue.detailedDescription.contains("SwiftUI.AccessibilityNode")
                                && self.authIsBarElement(element, over: source, in: app)
                        }
                        if onBarOverSource ?? true {
                            let place = issue.element.map { "on bar element \($0.elementType.rawValue) '\($0.label)' frame=\($0.frame)" } ?? "with no element"
                            print("AUDIT SKIPPED, \(place) while '\(source.identifier)' rests under the bar: \(issue.compactDescription)")
                            unplaced.append("\(issue.compactDescription) (\(issue.detailedDescription)) \(place)")
                            return true
                        }
                    }
                    let element = issue.element.map { "\($0.elementType.rawValue) '\($0.label)' value='\($0.value ?? "")' frame=\($0.frame)" } ?? "none"
                    issues.append("\(issue.compactDescription) (\(issue.detailedDescription)) | element: \(element)")
                    return true
                }
                if !unplaced.isEmpty {
                    let note = XCTAttachment(string: unplaced.joined(separator: "\n"))
                    note.name = "\(screen) audit: tolerated over the covered control"
                    note.lifetime = .keepAlways
                    add(note)
                }
                XCTAssertLessThanOrEqual(
                    unplaced.count, 1,
                    "\(screen) audit: more contrast issues with no element or on the bar than the covered control accounts for:\n"
                        + unplaced.joined(separator: "\n")
                )
                // Every issue in one failure, so one run shows all of them.
                XCTAssertTrue(issues.isEmpty, "\(screen) audit found \(issues.count) issue(s):\n" + issues.joined(separator: "\n"))
                return
            } catch let error as NSError where error.domain == "com.apple.xcode.xctest.accessibilityAudit" && error.code == -56 && attempt < 3 {
                Thread.sleep(forTimeInterval: 3)
            }
        }
    }

    /// True when a bar covers `element`, so a person can't see it where it
    /// is: its middle lies in the band of the pinned bar that holds the main
    /// button (from the bar's top, 12 pt above the button, B1.0.3, to the
    /// button's bottom) and it isn't the main button itself; or its middle lies
    /// below the button, under the bar's reason line and footer, and it belongs
    /// to the screen's scrolling content (Sign up's referral menu at rest); or
    /// it is a static text whose middle lies under the navigation bar (content
    /// scrolled under it). The bars' own elements (the main button, the reason
    /// line and the footer under it, the back button) are never skipped.
    @MainActor
    private func authIsCoveredByBars(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let frame = element.frame
        guard !frame.isEmpty else { return false }
        let mainButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'auth.' AND identifier ENDSWITH '.submit'")).firstMatch
        if mainButton.exists {
            let button = mainButton.frame
            if frame != button, frame.midY >= button.minY - 12, frame.midY <= button.maxY { return true }
            if frame.midY > button.maxY, authIsScrollingContent(element, in: app) { return true }
        }
        let navigationBar = app.navigationBars.firstMatch
        if navigationBar.exists, element.elementType == .staticText, frame.midY < navigationBar.frame.maxY { return true }
        return false
    }

    /// True when `element` is one of the pinned bar's own elements under its
    /// main button (the reason line or the footer, never scrolling content)
    /// and its frame overlaps `covered`'s, the control resting under it.
    @MainActor
    private func authIsBarElement(_ element: XCUIElement, over covered: XCUIElement, in app: XCUIApplication) -> Bool {
        let frame = element.frame
        guard !frame.isEmpty, frame.intersects(covered.frame) else { return false }
        let mainButton = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'auth.' AND identifier ENDSWITH '.submit'")).firstMatch
        guard mainButton.exists, frame.midY > mainButton.frame.maxY else { return false }
        return !authIsScrollingContent(element, in: app)
    }

    /// True when `element` (or an element of its type, label and frame) lies
    /// inside the screen's scroll view: the pinned bar is outside it, so its
    /// reason line and footer never count.
    @MainActor
    private func authIsScrollingContent(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        let scrollView = app.scrollViews.firstMatch
        guard scrollView.exists else { return false }
        let frame = element.frame
        return scrollView.descendants(matching: element.elementType)
            .matching(NSPredicate(format: "label == %@", element.label))
            .allElementsBoundByIndex
            .contains { $0.frame == frame }
    }
}
