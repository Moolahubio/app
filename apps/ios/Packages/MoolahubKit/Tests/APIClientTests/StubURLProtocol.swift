import Foundation
import os

/// What the stub server saw.
struct RecordedRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// What the stub server answers: an HTTP response or a transport error.
enum StubReply: Sendable {
    case http(status: Int, json: String, headers: [String: String] = [:])
    case failure(URLError.Code)
}

/// Routes requests by host, so parallel tests each get their own fake server.
final class StubServer: Sendable {
    let host: String
    private let state = OSAllocatedUnfairLock(initialState: (replies: [StubReply](), requests: [RecordedRequest]()))

    init() {
        host = "stub-\(UUID().uuidString.lowercased()).test"
        StubURLProtocol.register(self)
    }

    var baseURL: URL { URL(string: "http://\(host)/api")! }

    /// Replies are used in order; the last one repeats.
    func enqueue(_ reply: StubReply) {
        state.withLock { $0.replies.append(reply) }
    }

    var requests: [RecordedRequest] {
        state.withLock { $0.requests }
    }

    fileprivate func handle(_ request: RecordedRequest) -> StubReply {
        state.withLock { state in
            state.requests.append(request)
            if state.replies.count > 1 { return state.replies.removeFirst() }
            return state.replies.first ?? .http(status: 500, json: "{}")
        }
    }
}

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = OSAllocatedUnfairLock(initialState: [String: StubServer]())

    static func register(_ server: StubServer) {
        servers.withLock { $0[server.host] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let server = Self.servers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.readStream(request.httpBodyStream)
        )
        switch server.handle(recorded) {
        case let .http(status, json, headers):
            var allHeaders = ["Content-Type": "application/json; charset=utf-8"]
            allHeaders.merge(headers) { _, new in new }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: allHeaders)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    private static func readStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
