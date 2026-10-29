import Domain
import Foundation

/// The one HTTP client for the Moolahub API.
///
/// Contract with the server (BRIEF "Backend contract for the iOS client"):
/// - every request: `X-Client: ios`, `Accept: application/json`,
///   `X-App-Version`, `X-Build`; never an `Origin` header; no cookies
///   (cookie storage is off, so `x-session-token` is the only credential);
/// - Debug builds in a UI test run only: `X-MH-Test-Run` (`ClientInfo.testRunID`);
/// - mutations (POST/PATCH/DELETE): `Content-Type: application/json` and a JSON
///   body, `{}` when there is nothing to send;
/// - authenticated endpoints: `x-session-token: <token>`;
/// - 401 `{"error":"Unauthorized"}` on an authenticated endpoint clears the
///   token and calls the session-expired handler;
/// - nothing is logged: no bodies, no tokens, no amounts.
///
/// Money requests are never retried by this client. Callers must not retry
/// them either (DESIGN.md §11.6).
public actor APIClient {
    public struct ClientInfo: Sendable, Hashable {
        public let appVersion: String
        public let build: String
        /// A UI test run's id (Debug launches with `MH_TEST_RUN_ID`). When set,
        /// a Debug build sends it as `X-MH-Test-Run` on every request so the dev
        /// backend's log attributes the run's requests; Release never sends it.
        public let testRunID: String?

        public init(appVersion: String, build: String, testRunID: String? = nil) {
            self.appVersion = appVersion
            self.build = build
            self.testRunID = testRunID
        }

        /// Reads `CFBundleShortVersionString` / `CFBundleVersion` from the app.
        public static func fromMainBundle() -> ClientInfo {
            let info = Bundle.main.infoDictionary ?? [:]
            return ClientInfo(
                appVersion: info["CFBundleShortVersionString"] as? String ?? "0",
                build: info["CFBundleVersion"] as? String ?? "0"
            )
        }
    }

    private var baseURL: URL
    private var token: SessionToken?
    private var sessionExpiredHandler: (@Sendable () async -> Void)?
    private let session: URLSession
    private let clientInfo: ClientInfo

    /// - Parameter configuration: a base configuration; the client applies its
    ///   own cookie, cache and timeout policy on top (tests pass one with a stub
    ///   `URLProtocol`).
    public init(
        baseURL: URL,
        clientInfo: ClientInfo,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = baseURL
        self.clientInfo = clientInfo
        self.session = URLSession(configuration: Self.makeSessionConfiguration(configuration))
    }

    /// The network policy every Moolahub request uses.
    public static func makeSessionConfiguration(_ base: URLSessionConfiguration) -> URLSessionConfiguration {
        let configuration = base
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = APIRequestDefaults.timeout
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    // MARK: Configuration

    public var currentBaseURL: URL { baseURL }

    public func setBaseURL(_ url: URL) {
        baseURL = url
    }

    public func setSessionToken(_ token: SessionToken?) {
        self.token = token
    }

    public var hasSessionToken: Bool { token != nil }

    /// Called (once per expiry) after a 401 `{"error":"Unauthorized"}` on an
    /// authenticated request, after the in-memory token has been cleared.
    public func setSessionExpiredHandler(_ handler: @escaping @Sendable () async -> Void) {
        sessionExpiredHandler = handler
    }

    // MARK: Sending

    public func send<E: Endpoint>(_ endpoint: E) async throws(APIError) -> E.Response {
        guard ServerEnvironment.isAllowed(baseURL) else { throw .misconfigured }
        if Task.isCancelled { throw .cancelled }

        let tokenUsed = endpoint.authentication == .required ? token : nil
        guard let request = makeRequest(endpoint, token: tokenUsed) else { throw .misconfigured }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw Self.classify(error)
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .noResponse
        }

        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        let status = http.statusCode

        switch status {
        case 200..<300:
            if E.Response.self == NoContent.self, let empty = NoContent() as? E.Response {
                return empty
            }
            do {
                return try APICoding.makeDecoder().decode(E.Response.self, from: data)
            } catch {
                throw .invalidResponse
            }
        case 401:
            let message = Self.errorMessage(in: data)
            if endpoint.authentication == .required, message == "Unauthorized" {
                if tokenUsed != nil, tokenUsed == token {
                    token = nil
                    if let handler = sessionExpiredHandler {
                        await handler()
                    }
                }
                throw .sessionExpired
            }
            throw .rejected(status: status, message: message)
        case 429:
            throw .rateLimited(message: Self.errorMessage(in: data))
        case 400..<500:
            throw .rejected(status: status, message: Self.errorMessage(in: data))
        case 500..<600:
            // The API answers its own failures with its JSON envelope
            // (`{"error": …}`): the request was handled and rolled back. A 5xx
            // without it (a gateway's 502, 503 or 504 page) came from in front
            // of the API, which may have handled the request after all; for a
            // mutation (a money move above all) that is an unknown outcome,
            // like a dropped connection: never "nothing moved", never a retry
            // (J0.7, J0.8).
            let fromTheAPI = Self.errorMessage(in: data) != nil && ![502, 503, 504].contains(status)
            if endpoint.method != .get && !fromTheAPI {
                throw .noResponse
            }
            throw .server(status: status)
        default:
            throw .invalidResponse
        }
    }

    /// Builds the URLRequest; nil when the URL can't be formed.
    func makeRequest<E: Endpoint>(_ endpoint: E, token: SessionToken?) -> URLRequest? {
        guard var components = URLComponents(string: baseURL.absoluteString + endpoint.path) else { return nil }
        if !endpoint.query.isEmpty {
            components.percentEncodedQueryItems = endpoint.query.map { item in
                URLQueryItem(name: Self.encodeQuery(item.name), value: item.value.map(Self.encodeQuery))
            }
        }
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: endpoint.timeout)
        request.httpMethod = endpoint.method.rawValue
        request.httpShouldHandleCookies = false
        request.setValue("ios", forHTTPHeaderField: "X-Client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(clientInfo.appVersion, forHTTPHeaderField: "X-App-Version")
        request.setValue(clientInfo.build, forHTTPHeaderField: "X-Build")
        #if DEBUG
        if let testRunID = clientInfo.testRunID {
            request.setValue(testRunID, forHTTPHeaderField: "X-MH-Test-Run")
        }
        #endif
        if let token {
            request.setValue(token.rawValue, forHTTPHeaderField: "x-session-token")
        }
        if endpoint.method != .get {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: any Encodable & Sendable = endpoint.body ?? EmptyBody()
            guard let data = try? APICoding.makeEncoder().encode(body) else { return nil }
            request.httpBody = data
        }
        return request
    }

    private static func encodeQuery(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// The `error` string from an API error envelope, trimmed and capped.
    static func errorMessage(in data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(APIErrorBody.self, from: data) else { return nil }
        let message = body.error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return nil }
        return message.count > 300 ? String(message.prefix(300)) : message
    }

    /// Splits transport errors into "never sent" and "outcome unknown".
    static func classify(_ error: URLError) -> APIError {
        switch error.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .callIsActive,
             .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
             .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .clientCertificateRejected, .unsupportedURL, .badURL:
            return .notConnected
        default:
            return .noResponse
        }
    }
}

extension APIClient {
    /// `GET /wallet` read as the maximum of a money move (DESIGN.md v2 J0.8,
    /// B3.19, B4.25). When the server can't read the balance it answers with
    /// `availableCents: 0` and `balanceUnavailable: true` (conservative
    /// placeholders, not the person's money), so that answer counts as a
    /// failed read: the step shows its "couldn't load your balance" error with
    /// "Try again" and never treats the balance as $0.00. `.server` because
    /// the server answered but could not give the figure ("Something went
    /// wrong. Please try again.").
    public func walletForMoneyMove() async throws(APIError) -> WalletInfo {
        let wallet = try await send(API.Wallet.info())
        if wallet.balanceUnavailable == true { throw .server(status: 503) }
        return wallet
    }
}
