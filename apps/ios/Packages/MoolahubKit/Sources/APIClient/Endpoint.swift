import Domain
import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
    case delete = "DELETE"
}

/// Whether an endpoint runs inside a signed-in session.
public enum EndpointAuthentication: Sendable {
    /// Needs the session. A 401 `{"error":"Unauthorized"}` means the session
    /// expired: the client clears it and signs the user out.
    case required
    /// Sign-in, sign-up, password reset, health. A 401 here is a wrong
    /// password or code and is shown inline; it never signs anyone out.
    case none
}

/// One API call. Features declare their own endpoints by building
/// `APIRequest` values (or conforming their own types); the shared catalog is
/// `API` in Endpoints.swift.
public protocol Endpoint: Sendable {
    associatedtype Response: Decodable & Sendable
    var method: HTTPMethod { get }
    /// Path below the base URL, starting with "/" (`"/goals/\(id.pathSegment)"`).
    var path: String { get }
    var query: [URLQueryItem] { get }
    /// JSON body. Mutations without one send `{}`.
    var body: (any Encodable & Sendable)? { get }
    var authentication: EndpointAuthentication { get }
    /// Seconds before the request times out.
    var timeout: TimeInterval { get }
}

extension Endpoint {
    public var query: [URLQueryItem] { [] }
    public var body: (any Encodable & Sendable)? { nil }
    public var authentication: EndpointAuthentication { .required }
    public var timeout: TimeInterval { APIRequestDefaults.timeout }
}

public enum APIRequestDefaults {
    /// Per-request timeout. Long enough for a phone on hotel Wi-Fi, short
    /// enough that a dead server shows an error instead of a spinner forever.
    public static let timeout: TimeInterval = 20
}

/// A response whose body is ignored (any 2xx is success).
public struct NoContent: Decodable, Sendable, Hashable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
}

/// The general-purpose endpoint value.
///
///     extension API.Goals {
///         static func get(_ id: String) -> APIRequest<Goal> { .get("/goals/\(id.pathSegment)") }
///     }
public struct APIRequest<Response: Decodable & Sendable>: Endpoint {
    public var method: HTTPMethod
    public var path: String
    public var query: [URLQueryItem]
    public var body: (any Encodable & Sendable)?
    public var authentication: EndpointAuthentication
    public var timeout: TimeInterval

    public init(
        method: HTTPMethod,
        path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        authentication: EndpointAuthentication = .required,
        timeout: TimeInterval = APIRequestDefaults.timeout
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.authentication = authentication
        self.timeout = timeout
    }

    public static func get(_ path: String, query: [URLQueryItem] = [], authentication: EndpointAuthentication = .required) -> Self {
        Self(method: .get, path: path, query: query, authentication: authentication)
    }

    public static func post(_ path: String, body: (any Encodable & Sendable)? = nil, authentication: EndpointAuthentication = .required) -> Self {
        Self(method: .post, path: path, body: body, authentication: authentication)
    }

    public static func patch(_ path: String, body: (any Encodable & Sendable)? = nil, authentication: EndpointAuthentication = .required) -> Self {
        Self(method: .patch, path: path, body: body, authentication: authentication)
    }

    public static func delete(_ path: String, body: (any Encodable & Sendable)? = nil, authentication: EndpointAuthentication = .required) -> Self {
        Self(method: .delete, path: path, body: body, authentication: authentication)
    }
}

extension String {
    /// Percent-encodes an id for use as one path segment ("/" included).
    public var pathSegment: String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
