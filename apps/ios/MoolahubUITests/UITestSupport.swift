import CryptoKit
import XCTest

/// Shared helpers for UI tests that run against the local dev backend
/// (`scripts/dev-ios-backend.sh`). Run them through `apps/ios/scripts/ui-test.sh`,
/// which passes the seeded demo password in as `MH_DEMO_PASSWORD`; the password
/// itself lives only in `artifacts/api-server/scripts/seed-ios-dev.ts`.
enum UITestAccount {
    static let demoEmail = "demo@moolahub.test"

    static func demoPassword() throws -> String {
        guard let password = ProcessInfo.processInfo.environment["MH_DEMO_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("MH_DEMO_PASSWORD is not set: run UI tests with apps/ios/scripts/ui-test.sh")
        }
        return password
    }
}

extension XCUIApplication {
    /// Launches from a clean state (no session, cache or device settings).
    static func launchedClean() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mh-reset-state"]
        app.launch()
        return app
    }

    /// Launches for a test that counts its own requests in the backend log
    /// (D-36): `MH_TEST_RUN_ID` makes the Debug app send `X-MH-Test-Run:
    /// <testRun>` on every request (1 to 64 letters, digits and hyphens, such
    /// as a fresh `UUID().uuidString`). `timeZone`, an IANA identifier, sets
    /// both `TZ` and the app's `MH_TIME_ZONE` (SPEC §4.5). `resetState` starts
    /// from a clean state, as `launchedClean()` does.
    static func launchedForCounting(testRun: String, timeZone: String? = nil, resetState: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MH_TEST_RUN_ID"] = testRun
        if let timeZone {
            app.launchEnvironment["TZ"] = timeZone
            app.launchEnvironment["MH_TIME_ZONE"] = timeZone
        }
        if resetState {
            app.launchArguments = ["-mh-reset-state"]
        }
        app.launch()
        return app
    }

    /// Signs in through the real Sign in screen, waits for the tab bar, then
    /// answers what iOS and the app can show over Home right after a first
    /// sign-in: iOS's "Save Password?" ("Not Now") and the one-time app lock
    /// offer ("Not now"). Both can arrive seconds after the tabs, and "Save
    /// Password?" can cover the offer, so it keeps answering until nothing new
    /// has shown for 6 seconds.
    func signIn(email: String = UITestAccount.demoEmail, password: String, file: StaticString = #filePath, line: UInt = #line) {
        let welcomeSignIn = buttons["Sign in"]
        XCTAssertTrue(welcomeSignIn.waitForExistence(timeout: 30), "Welcome did not appear", file: file, line: line)
        let emailField = textFields["Email"]
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

        let passwordField = secureTextFields["Password"]
        // Strict on purpose: a person taps the Password field, so the test
        // does too. While Email has focus, Sign in scrolls Password into view
        // above the pinned bar (`AuthScreen`'s next field), on a 375 × 667
        // iPhone too; if the bar ever covers it again, this tap fails.
        let barButton = buttons["auth.signIn.submit"]
        if barButton.exists {
            let deadline = Date().addingTimeInterval(3)
            while passwordField.frame.maxY > barButton.frame.minY && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
            XCTAssertLessThanOrEqual(passwordField.frame.maxY, barButton.frame.minY + 0.5,
                                     "the pinned bar covers the Password field while Email has focus", file: file, line: line)
        }
        passwordField.tap()
        passwordField.typeText(password)

        let submit = buttons["auth.signIn.submit"]
        if submit.exists {
            submit.tap()
        } else {
            buttons.matching(identifier: "Sign in").allElementsBoundByIndex.last?.tap()
        }
        XCTAssertTrue(tabBars.firstMatch.waitForExistence(timeout: 30), "Tab bar did not appear after sign in", file: file, line: line)
        dismissSignInPrompts(file: file, line: line)
    }

    /// Answers "Save Password?" and the app lock offer until neither has shown
    /// for 6 seconds (at most 40 seconds).
    func dismissSignInPrompts(file: StaticString = #filePath, line: UInt = #line) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let savePassword = [buttons["Not Now"], springboard.buttons["Not Now"]]
        let lockOffer = buttons["Not now"]
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

    /// Switches to the tab named `name` and waits until it is selected. On
    /// the iOS 26 tab bar a synthesized tap can lift the selection lens
    /// without switching tabs (seen in a recording of a failed run on a busy
    /// Mac), so this taps again, up to three times, while the tab still isn't
    /// selected. Don't use it to re-tap the selected tab: that pops to root.
    @discardableResult
    func selectTab(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let tab = tabBars.buttons[name]
        guard tab.waitForExistence(timeout: 10) else {
            XCTFail("\(name) tab missing", file: file, line: line)
            return false
        }
        for _ in 0..<3 where !tab.isSelected {
            tab.tap()
            let deadline = Date().addingTimeInterval(3)
            while tab.exists && !tab.isSelected && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            }
        }
        XCTAssertTrue(tab.exists && tab.isSelected, "\(name) tab did not open", file: file, line: line)
        return tab.isSelected
    }

    /// Adds a screenshot that is kept in the result bundle.
    func attachScreenshot(named name: String, to testCase: XCTestCase) {
        let shot = XCTAttachment(screenshot: screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        testCase.add(shot)
    }
}

/// No crypto words anywhere in the visible hierarchy, except the balance
/// disclosure ("Held as USDC · …"), which DESIGN.md §9.3 allows.
@MainActor
func assertNoCryptoWords(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
    var texts: [String] = []
    func walk(_ node: any XCUIElementSnapshot) {
        texts.append(node.label)
        if let value = node.value as? String { texts.append(value) }
        for child in node.children { walk(child) }
    }
    walk(try app.snapshot())
    let banned = try NSRegularExpression(pattern: "(?i)\\b(usdc|wallet|blockchain|privy|transaction|transactions|gas|hash|monad)\\b|\\bBase\\b|0x[0-9a-fA-F]")
    let offenders = texts.filter { text in
        guard !text.contains("Held as USDC") else { return false }
        return banned.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    XCTAssertEqual(offenders, [], "crypto words in default views", file: file, line: line)
}

/// Reads the emailed codes the dev backend writes to its log
/// (`[DEV ONLY] <kind> code for u***@m***.test: 123456`). `ui-test.sh` passes the
/// log path in as `MH_BACKEND_LOG` when `MH_BACKEND_LOG` is set in its environment.
/// The log masks emails to their first letter, so give each feature's test
/// accounts their own first letter (see the team brief).
enum UITestBackendLog {
    enum Kind: String {
        case verification
        case passwordReset = "password reset"
        case confirmation
    }

    private static func url() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["MH_BACKEND_LOG"], !path.isEmpty else {
            throw XCTSkip("MH_BACKEND_LOG is not set: run with MH_BACKEND_LOG=<backend log> apps/ios/scripts/ui-test.sh …")
        }
        return URL(fileURLWithPath: path)
    }

    /// The current end of the log. Pass it to `code(_:emailInitial:after:)` so only
    /// codes written after this point count.
    static func mark() throws -> Int {
        try Data(contentsOf: url()).count
    }

    /// Waits for the first `kind` code written after `mark` for an email starting with `emailInitial`.
    static func code(_ kind: Kind, emailInitial: Character, after mark: Int, timeout: TimeInterval = 20) throws -> String {
        let prefix = "[DEV ONLY] \(kind.rawValue) code for \(emailInitial)***@"
        let deadline = Date().addingTimeInterval(timeout)
        let ansi = try NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
        repeat {
            let data = try Data(contentsOf: url())
            if data.count > mark, let text = String(data: data.suffix(from: mark), encoding: .utf8) {
                for rawLine in text.split(separator: "\n") {
                    let line = String(rawLine)
                    let plain = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "")
                    guard let start = plain.range(of: prefix) else { continue }
                    let rest = plain[start.upperBound...]
                    if let colon = rest.range(of: ": ") {
                        let code = rest[colon.upperBound...].prefix(6)
                        if code.count == 6, code.allSatisfy(\.isNumber) { return String(code) }
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        XCTFail("no \(kind.rawValue) code for \(emailInitial)***@ appeared in the backend log")
        return ""
    }

    /// One request the dev backend logged for a test run (D-36).
    struct LoggedRequest: Equatable, Sendable {
        let method: String
        /// Without "/api" ("/wallet"), as passed to `requests`.
        let path: String
        /// The query string without "?"; nil when the request had none.
        let query: String?
    }

    /// The requests the dev backend logged after `mark` with the header
    /// `X-MH-Test-Run: <testRun>` (an app launched by `launchedForCounting`),
    /// `method` and `path`, given without "/api" ("/wallet") (SPEC §8.2,
    /// D-36); empty when the app sent none. Waits `settle` seconds first:
    /// pino-http writes a request's record when its response finishes. Skips
    /// the test when `MH_BACKEND_LOG` is unset, and when no record anywhere in
    /// the log carries this `testRun` (a backend from before lane B step 1b,
    /// SPEC §1.11), so a window that rightly holds no request counts 0.
    static func requests(method: String, path: String, after mark: Int, testRun: String, settle: TimeInterval = 3) throws -> [LoggedRequest] {
        let file = try url()
        Thread.sleep(forTimeInterval: settle)
        let data = try Data(contentsOf: file)
        let start = min(max(mark, 0), data.count)
        let after = try loggedRequests(in: data.suffix(from: start))
        var logsThisRun = after.contains { $0["testRun"] == testRun }
        if !logsThisRun {
            logsThisRun = try loggedRequests(in: data.prefix(start)).contains { $0["testRun"] == testRun }
        }
        guard logsThisRun else {
            throw XCTSkip("the dev backend does not log X-MH-Test-Run: restart it after lane B step 1b")
        }
        return after.compactMap { fields in
            guard fields["testRun"] == testRun, fields["method"] == method, fields["url"] == "/api" + path else { return nil }
            return LoggedRequest(method: method, path: path, query: fields["query"].flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// The `method`, `url`, `testRun` and `query` of each "request completed"
    /// or "request errored" record in `data`, a slice of the log.
    private static func loggedRequests(in data: Data) throws -> [[String: String]] {
        let text = String(decoding: data, as: UTF8.self)
        let ansi = try NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
        let plain = ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        // pino-pretty's record header, then the record's indented lines.
        let header = try NSRegularExpression(pattern: #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\] "#)
        let field = try NSRegularExpression(pattern: #"^\s*"(method|url|testRun|query)": "([^"]*)""#)
        var records: [[String]] = []
        for line in plain.components(separatedBy: "\n") {
            if header.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                records.append([line])
            } else if !records.isEmpty {
                records[records.count - 1].append(line)
            }
        }
        return records.compactMap { record in
            let head = record[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard head.hasSuffix("request completed") || head.hasSuffix("request errored") else { return nil }
            var fields: [String: String] = [:]
            for line in record.dropFirst() {
                guard let match = field.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let name = Range(match.range(at: 1), in: line),
                      let value = Range(match.range(at: 2), in: line)
                else { continue }
                // The first of each is the request's.
                if fields[String(line[name])] == nil { fields[String(line[name])] = String(line[value]) }
            }
            return fields
        }
    }
}

/// Reads the dev backend for UI tests with the test's own API session, never
/// through the app: `POST /auth/login` (`X-Client: ios`), one read, then
/// `POST /auth/logout`. Each returns the read's JSON body for the test to
/// decode; a status other than 200 throws.
enum UITestAPI {
    /// `GET /streaks` for the demo account.
    static func streaks() async throws -> Data {
        try await read("/streaks", email: UITestAccount.demoEmail, password: UITestAccount.demoPassword())
    }

    /// `GET /learn/lessons` for the demo account.
    static func lessons() async throws -> Data {
        try await read("/learn/lessons", email: UITestAccount.demoEmail, password: UITestAccount.demoPassword())
    }

    /// `GET /profile` for an account without two-factor (a throwaway from
    /// `AuthTestAPI.registerVerifiedAccount()`).
    static func profile(email: String, password: String) async throws -> Data {
        try await read("/profile", email: email, password: password)
    }

    private struct SessionResponse: Decodable {
        let sessionToken: String?
    }

    private static func read(_ path: String, email: String, password: String) async throws -> Data {
        let (loginStatus, loginData) = try await AuthTestAPI.send("POST", "/auth/login", json: [
            "email": email, "password": password, "rememberMe": true,
        ])
        guard loginStatus == 200, let token = try JSONDecoder().decode(SessionResponse.self, from: loginData).sessionToken else {
            throw AuthTestError("login returned \(loginStatus) without a session")
        }
        let response: Result<(Int, Data), any Error>
        do {
            response = .success(try await get(path, token: token))
        } catch {
            response = .failure(error)
        }
        _ = try? await AuthTestAPI.send("POST", "/auth/logout", json: [:], token: token)
        let (status, data) = try response.get()
        guard status == 200 else { throw AuthTestError("GET \(path) returned \(status)") }
        return data
    }

    /// A GET with no body: `AuthTestAPI.send` always sends a JSON body, and
    /// a GET must not carry one.
    private static func get(_ path: String, token: String) async throws -> (Int, Data) {
        var request = URLRequest(url: AuthTestAPI.baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = "GET"
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue(token, forHTTPHeaderField: "x-session-token")
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Simulated Face ID for UI tests. `apps/ios/scripts/ui-test.sh` enrolls Face
/// ID on the simulator for the run and starts a host helper that watches
/// `MH_FACEID_DIR`: each time a `request` file appears it posts one simulated
/// face (`match` or `nomatch`, the file's contents) and deletes the file.
///
/// Why: the iOS 26.5 simulator reports a passcode
/// (`canEvaluatePolicy(.deviceOwnerAuthentication)` is true even right after
/// `simctl erase`), so every money-move confirm and the app lock open the
/// system prompt. Without Face ID enrolled that is the passcode screen, which a
/// test can't answer. One face per prompt, never on a timer: a match that
/// arrives with no prompt up can leave the simulator on its Lock Screen.
enum UITestFaceID {
    /// The helper's directory, or nil when the run has no helper.
    static var directory: String? {
        guard let dir = ProcessInfo.processInfo.environment["MH_FACEID_DIR"], !dir.isEmpty else { return nil }
        return dir
    }

    /// Answers the prompt the last tap raised: allows "Allow MoolaHub to use
    /// Face ID?" if iOS asks (first use after enrollment), waits for the
    /// prompt to come up, then has the host post one `kind` face and waits
    /// until it was posted. Fails the test when the run has no helper.
    @MainActor
    static func answer(_ kind: String = "match", app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard let directory else {
            XCTFail("this simulator asks for Face ID: run the tests through apps/ios/scripts/ui-test.sh (it sets MH_FACEID_DIR)", file: file, line: line)
            return
        }
        allowFaceIDIfAsked(app)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        let request = URL(fileURLWithPath: directory).appendingPathComponent("request")
        do {
            try Data(kind.utf8).write(to: request)
        } catch {
            XCTFail("could not write the Face ID request to \(directory): \(error)", file: file, line: line)
            return
        }
        let deadline = Date().addingTimeInterval(20)
        while FileManager.default.fileExists(atPath: request.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: request.path), "the host helper did not answer the Face ID request", file: file, line: line)
    }

    /// Taps "OK" / "Allow" on the one-time Face ID permission alert if it
    /// shows within 4 seconds; otherwise does nothing.
    @MainActor
    static func allowFaceIDIfAsked(_ app: XCUIApplication) {
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
}

// MARK: - Test accounts and direct API calls (setup only, never through the app)

/// A fresh "QA Auth …" account: email and username start with "u".
struct AuthTestAccount: Sendable {
    let name: String
    let email: String
    let username: String
    let password: String
    var totpSecret: String?
    var backupCodes: [String] = []

    static func fresh() -> AuthTestAccount {
        let handle = "u\(Int(Date().timeIntervalSince1970))\(Int.random(in: 100...999))"
        return AuthTestAccount(
            name: "QA Auth User", email: "\(handle)@moolahub.test", username: handle, password: makePassword()
        )
    }

    static func makePassword() -> String {
        "QaAuth-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    }
}

enum AuthTestAPI {
    static let baseURL = URL(string: "http://localhost:8787/api")!

    private struct SessionResponse: Decodable {
        let sessionToken: String?
        let challengeId: String?
    }

    private struct SetupResponse: Decodable {
        let secret: String
    }

    private struct EnableResponse: Decodable {
        let backupCodes: [String]
    }

    /// Registers a fresh account, verifies it with the emailed code from the
    /// backend log and (optionally) turns on two-factor with a TOTP code
    /// computed here. The API session is signed out afterwards.
    static func registerVerifiedAccount(enableTwoFactor: Bool = false) async throws -> AuthTestAccount {
        var account = AuthTestAccount.fresh()
        let mark = try UITestBackendLog.mark()
        let (registerStatus, _) = try await send("POST", "/auth/register", json: [
            "name": account.name, "username": account.username, "email": account.email,
            "password": account.password, "dateOfBirth": "1990-01-15", "rememberMe": true,
        ])
        guard registerStatus == 200 || registerStatus == 201 else { throw AuthTestError("register returned \(registerStatus)") }
        let code = try UITestBackendLog.code(.verification, emailInitial: "u", after: mark)
        let (verifyStatus, verifyData) = try await send("POST", "/auth/verify-email", json: [
            "email": account.email, "code": code, "rememberMe": true,
        ])
        guard verifyStatus == 200, let token = try JSONDecoder().decode(SessionResponse.self, from: verifyData).sessionToken else {
            throw AuthTestError("verify-email returned \(verifyStatus)")
        }
        if enableTwoFactor {
            let (setupStatus, setupData) = try await send("POST", "/security/2fa/setup", json: ["currentPassword": account.password], token: token)
            guard setupStatus == 200 else { throw AuthTestError("2fa setup returned \(setupStatus)") }
            let secret = try JSONDecoder().decode(SetupResponse.self, from: setupData).secret
            let (enableStatus, enableData) = try await send("POST", "/security/2fa/enable", json: [
                "code": AuthTOTP.code(secret: secret, at: Date()), "currentPassword": account.password,
            ], token: token)
            guard enableStatus == 200 else { throw AuthTestError("2fa enable returned \(enableStatus)") }
            account.totpSecret = secret
            account.backupCodes = try JSONDecoder().decode(EnableResponse.self, from: enableData).backupCodes
        }
        _ = try? await send("POST", "/auth/logout", json: [:], token: token)
        return account
    }

    /// The HTTP status of `POST /auth/login` (a 200 session is signed out again).
    static func loginStatus(email: String, password: String) async throws -> Int {
        let (status, data) = try await send("POST", "/auth/login", json: ["email": email, "password": password, "rememberMe": true])
        if status == 200, let token = try? JSONDecoder().decode(SessionResponse.self, from: data).sessionToken {
            _ = try? await send("POST", "/auth/logout", json: [:], token: token)
        }
        return status
    }

    /// Signs in with the password, then answers the two-factor challenge with
    /// `code`; returns the status of `POST /auth/2fa/login`.
    static func twoFactorLoginStatus(email: String, password: String, code: String) async throws -> Int {
        let (status, data) = try await send("POST", "/auth/login", json: ["email": email, "password": password, "rememberMe": true])
        guard status == 200, let challenge = try JSONDecoder().decode(SessionResponse.self, from: data).challengeId else {
            throw AuthTestError("login returned \(status) without a two-factor challenge")
        }
        let (twoFactorStatus, twoFactorData) = try await send("POST", "/auth/2fa/login", json: ["challengeId": challenge, "code": code])
        if twoFactorStatus == 200, let token = try? JSONDecoder().decode(SessionResponse.self, from: twoFactorData).sessionToken {
            _ = try? await send("POST", "/auth/logout", json: [:], token: token)
        }
        return twoFactorStatus
    }

    static func send(_ method: String, _ path: String, json: [String: any Sendable], token: String? = nil) async throws -> (Int, Data) {
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        if let token {
            request.setValue(token, forHTTPHeaderField: "x-session-token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

struct AuthTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// RFC 6238 TOTP (SHA-1, 6 digits, 30-second steps), the server's otplib
/// defaults, so tests can answer a two-factor challenge.
enum AuthTOTP {
    static func code(secret: String, at date: Date) -> String {
        let key = SymmetricKey(data: base32Decode(secret))
        var counter = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let value = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        return String(format: "%06u", value % 1_000_000)
    }

    /// Codes the server accepts around now (it allows one step either side),
    /// plus the next step in case the clock turns while typing.
    static func acceptedCodes(secret: String) -> [String] {
        let now = Date()
        return [-30.0, 0, 30, 60].map { code(secret: secret, at: now.addingTimeInterval($0)) }
    }

    private static func base32Decode(_ string: String) -> Data {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0
        var bits = 0
        var bytes: [UInt8] = []
        for character in string.uppercased() where character != "=" {
            guard let index = alphabet.firstIndex(of: character) else { continue }
            buffer = (buffer << 5) | UInt32(index)
            bits += 5
            if bits >= 8 {
                bits -= 8
                bytes.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return Data(bytes)
    }
}
