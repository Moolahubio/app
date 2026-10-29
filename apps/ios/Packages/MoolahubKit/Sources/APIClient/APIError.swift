import Foundation

/// Every failure `APIClient.send` can produce, already classified for the UI.
/// Raw server text is only ever surfaced for 4xx messages (which the server
/// writes for users); 5xx bodies are never shown.
public enum APIError: Error, Hashable, Sendable {
    /// The request never reached the server (offline, host not found,
    /// connection refused, local network blocked). Nothing happened.
    case notConnected
    /// The request may have reached the server but no response came back
    /// (timeout, connection dropped). For money moves the outcome is unknown:
    /// never retry automatically, send the user to Activity.
    case noResponse
    /// 401 `{"error":"Unauthorized"}` on an authenticated endpoint. The client
    /// has already cleared the session and called the expiry handler.
    case sessionExpired
    /// A 4xx refusal with the server's message (nil when it sent none).
    case rejected(status: Int, message: String?)
    /// 429. The server's message when present.
    case rateLimited(message: String?)
    /// 5xx. Server text is deliberately not kept.
    case server(status: Int)
    /// A response that isn't what the contract says (bad JSON, not HTTP).
    case invalidResponse
    /// The base URL is missing or not allowed in this build (Release
    /// placeholder, plain HTTP in Release).
    case misconfigured
    /// The task was cancelled (view went away). Don't show anything.
    case cancelled

    /// Where the error is shown; picks the copy (DESIGN.md §9.4).
    public enum Context: Sendable {
        /// A screen or section failed to load.
        case screen
        /// A non-money action (save profile, send invite, sign in).
        case action
        /// A money move (add test money, move to goal or balance, delete goal,
        /// pay in).
        case moneyMove
    }

    /// The HTTP status, when there was a response.
    public var status: Int? {
        switch self {
        case .rejected(let status, _): status
        case .rateLimited: 429
        case .server(let status): status
        case .sessionExpired: 401
        default: nil
        }
    }

    /// True when a money move may or may not have happened.
    public var isUncertainOutcome: Bool { self == .noResponse }

    /// The server's own words for a 4xx refusal, when it sent any.
    public var serverMessage: String? {
        switch self {
        case .rejected(_, let message), .rateLimited(let message): message
        default: nil
        }
    }

    /// User-facing copy for this error in `context` (DESIGN.md §9.4).
    public func message(for context: Context) -> String {
        switch self {
        case .notConnected:
            return Copy.notConnected
        case .noResponse:
            switch context {
            case .moneyMove: return Copy.uncertainMoneyMove
            case .screen: return Copy.screenFailed
            case .action: return Copy.notConnected
            }
        case .sessionExpired:
            return Copy.sessionExpired
        case .rejected(_, let message):
            guard let message, !message.isEmpty, message != "Invalid request" else { return Copy.generic }
            return message
        case .rateLimited(let message):
            if let message, !message.isEmpty { return message }
            return Copy.tooManyTries
        case .server:
            return context == .moneyMove ? Copy.serverErrorMoneyMove : Copy.generic
        case .invalidResponse:
            return context == .screen ? Copy.screenFailed : Copy.generic
        case .misconfigured:
            return Copy.misconfigured
        case .cancelled:
            return ""
        }
    }

    /// Final copy from DESIGN.md §9.4.
    public enum Copy {
        public static let notConnected = "We couldn't reach MoolaHub. Check your connection and try again."
        public static let uncertainMoneyMove = "We couldn't confirm this move. Check Activity before you try again."
        public static let moneyMoveRefusedTitle = "Didn't go through. Nothing was taken."
        public static let serverErrorMoneyMove = "Something went wrong on our side. Your money hasn't moved. Please try again in a minute."
        public static let generic = "Something went wrong. Please try again."
        public static let tooManyTries = "Too many tries. Please wait a moment and try again."
        public static let sessionExpired = "You've been signed out. Please sign in again."
        public static let screenFailed = "We couldn't load this. Check your connection and try again."
        public static let misconfigured = "This build isn't set up to connect to MoolaHub."
    }
}
