import Domain
import Foundation
import os
import Testing
@testable import APIClient

private func makeClient(_ server: StubServer, token: String? = nil) async -> APIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = APIClient(
        baseURL: server.baseURL,
        clientInfo: .init(appVersion: "1.2.3", build: "45"),
        configuration: configuration
    )
    if let token { await client.setSessionToken(SessionToken(token)) }
    return client
}

private let meJSON = #"{"id":"u1","name":"Ama Owusu","email":"demo@moolahub.test","username":"ama","hasWallet":true}"#

@Suite("APIClient request contract")
struct APIClientRequestTests {
    @Test func getSendsNativeHeadersAndTokenButNoBodyOrOrigin() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: meJSON))
        let client = await makeClient(server, token: "tok-123")

        let user = try await client.send(API.Auth.me())
        #expect(user.username == "ama")

        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "\(server.baseURL.absoluteString)/auth/me")
        #expect(request.header("X-Client") == "ios")
        #expect(request.header("Accept") == "application/json")
        #expect(request.header("x-session-token") == "tok-123")
        #expect(request.header("X-App-Version") == "1.2.3")
        #expect(request.header("X-Build") == "45")
        #expect(request.header("Origin") == nil)
        #expect(request.header("Cookie") == nil)
        #expect(request.header("Content-Type") == nil)
        #expect(request.body == nil || request.body?.isEmpty == true)
    }

    @Test func mutationWithoutBodySendsEmptyJSONObject() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"ok":true}"#))
        let client = await makeClient(server, token: "t")

        let result = try await client.send(API.Groups.contribute(groupID: "c1"))
        #expect(result.ok)

        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/circles/c1/contribute")
        #expect(request.header("Content-Type") == "application/json")
        #expect(request.body.map { String(decoding: $0, as: UTF8.self) } == "{}")
    }

    @Test func mutationBodyIsJSON() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"ok":true}"#))
        let client = await makeClient(server, token: "t")

        _ = try await client.send(API.Wallet.addTestMoney(Money(cents: 5_000)))
        let body = try #require(server.requests.first?.body)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        #expect(json?["amountCents"] as? Int == 5_000)
    }

    @Test func publicEndpointsDoNotSendTheToken() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"twoFactorRequired":true,"challengeId":"c"}"#))
        let client = await makeClient(server, token: "old-token")
        _ = try await client.send(API.Auth.login(LoginInput(email: "a@b.co", password: "x")))
        #expect(server.requests.first?.header("x-session-token") == nil)
    }

    @Test func pathSegmentsAndQueriesAreEncoded() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"available":true}"#))
        let client = await makeClient(server)
        _ = try await client.send(API.Auth.usernameAvailable("a+b&c"))
        let url = try #require(server.requests.first?.url)
        #expect(url.query == "username=a%2Bb%26c")
        #expect("../x".pathSegment == "..%2Fx")
    }

    @Test func cookiesAreNeverStoredOrSent() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: meJSON, headers: ["Set-Cookie": "moolahub_session=secret; Path=/; HttpOnly"]))
        server.enqueue(.http(status: 200, json: meJSON))
        let client = await makeClient(server, token: "t")
        _ = try await client.send(API.Auth.me())
        _ = try await client.send(API.Auth.me())
        #expect(server.requests.count == 2)
        #expect(server.requests[1].header("Cookie") == nil)
    }
}

@Suite("APIClient error mapping")
struct APIClientErrorTests {
    @Test func unauthorizedExpiresTheSessionOnce() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 401, json: #"{"error":"Unauthorized"}"#))
        let client = await makeClient(server, token: "expired")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await client.setSessionExpiredHandler { calls.withLock { $0 += 1 } }

        await #expect(throws: APIError.sessionExpired) { try await client.send(API.Dashboard.summary()) }
        #expect(await client.hasSessionToken == false)
        #expect(calls.withLock { $0 } == 1)

        // Later requests go out without a token and don't call the handler again.
        await #expect(throws: APIError.sessionExpired) { try await client.send(API.Dashboard.summary()) }
        #expect(server.requests.last?.header("x-session-token") == nil)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func wrongPasswordOnStepUpDoesNotSignOut() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 401, json: #"{"error":"Your password is incorrect."}"#))
        let client = await makeClient(server, token: "good")
        let calls = OSAllocatedUnfairLock(initialState: 0)
        await client.setSessionExpiredHandler { calls.withLock { $0 += 1 } }

        do throws(APIError) {
            _ = try await client.send(API.Goals.release(goalID: "g", amount: Money(cents: 100), proof: StepUpProof(currentPassword: "nope")))
            Issue.record("expected an error")
        } catch {
            #expect(error == .rejected(status: 401, message: "Your password is incorrect."))
            #expect(error.message(for: .moneyMove) == "Your password is incorrect.")
        }
        #expect(await client.hasSessionToken)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func wrongLoginIsInlineNotExpiry() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 401, json: #"{"error":"Unauthorized"}"#))
        let client = await makeClient(server)
        do throws(APIError) {
            _ = try await client.send(API.Auth.login(LoginInput(email: "a@b.co", password: "x")))
            Issue.record("expected an error")
        } catch {
            #expect(error == .rejected(status: 401, message: "Unauthorized"))
        }
    }

    @Test func serverErrorsNeverLeakServerText() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 500, json: #"{"error":"relation \"users\" does not exist"}"#))
        let client = await makeClient(server, token: "t")
        do throws(APIError) {
            _ = try await client.send(API.Goals.list())
            Issue.record("expected an error")
        } catch {
            #expect(error == .server(status: 500))
            #expect(!error.message(for: .screen).contains("relation"))
            #expect(error.message(for: .moneyMove) == "Something went wrong on our side. Your money hasn't moved. Please try again in a minute.")
        }
    }

    /// QA-5: a gateway's 504 page after the deposit landed is an unknown
    /// outcome, not "Your money hasn't moved" (J0.7).
    @Test func gatewayErrorsOnAMutationAreAnUnknownOutcome() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 504, json: "<html><body><h1>504 Gateway Time-out</h1></body></html>"))
        server.enqueue(.http(status: 502, json: #"{"error":"Bad gateway"}"#))
        server.enqueue(.http(status: 500, json: "<html>upstream error</html>"))
        let client = await makeClient(server, token: "t")
        for _ in 0..<3 {
            do throws(APIError) {
                _ = try await client.send(API.Wallet.addTestMoney(Money(cents: 700)))
                Issue.record("expected an error")
            } catch {
                #expect(error == .noResponse)
                #expect(error.message(for: .moneyMove) == "We couldn't confirm this move. Check Activity before you try again.")
            }
        }
    }

    /// The API's own 500 (its JSON envelope) on a mutation is still a server
    /// error; a gateway 5xx on a read is still a server error.
    @Test func serverErrorsKeepTheirMeaningWhereTheOutcomeIsKnown() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 500, json: #"{"error":"Internal server error"}"#))
        server.enqueue(.http(status: 504, json: "<html>504</html>"))
        let client = await makeClient(server, token: "t")
        do throws(APIError) {
            _ = try await client.send(API.Groups.contribute(groupID: "c1"))
            Issue.record("expected an error")
        } catch {
            #expect(error == .server(status: 500))
        }
        do throws(APIError) {
            _ = try await client.send(API.Goals.list())
            Issue.record("expected an error")
        } catch {
            #expect(error == .server(status: 504))
        }
    }

    @Test func invalidRequestMapsToGenericCopy() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 400, json: #"{"error":"Invalid request"}"#))
        let client = await makeClient(server, token: "t")
        do throws(APIError) {
            _ = try await client.send(API.Goals.create(GoalInput(name: "", icon: .goal, target: .zero, deadline: "x", frequency: .weekly)))
            Issue.record("expected an error")
        } catch {
            #expect(error.message(for: .action) == "Something went wrong. Please try again.")
        }
    }

    @Test func serverMessagesForRefusalsAreShownVerbatim() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 400, json: #"{"error":"You don't have enough available for that."}"#))
        let client = await makeClient(server, token: "t")
        do throws(APIError) {
            _ = try await client.send(API.Goals.allocate(goalID: "g", amount: Money(cents: 100)))
            Issue.record("expected an error")
        } catch {
            #expect(error.message(for: .moneyMove) == "You don't have enough available for that.")
        }
    }

    @Test func rateLimitUsesServerMessageOrDefault() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 429, json: #"{"error":"Too many failed attempts. Please try again later."}"#))
        server.enqueue(.http(status: 429, json: "not json"))
        let client = await makeClient(server)
        do throws(APIError) { _ = try await client.send(API.Health.check()) } catch {
            #expect(error.message(for: .action) == "Too many failed attempts. Please try again later.")
        }
        do throws(APIError) { _ = try await client.send(API.Health.check()) } catch {
            #expect(error.message(for: .action) == "Too many tries. Please wait a moment and try again.")
        }
    }

    @Test func transportErrorsSplitIntoNotSentAndUnknown() async throws {
        let server = StubServer()
        server.enqueue(.failure(.cannotConnectToHost))
        server.enqueue(.failure(.timedOut))
        let client = await makeClient(server, token: "t")

        await #expect(throws: APIError.notConnected) { try await client.send(API.Goals.list()) }
        do throws(APIError) {
            _ = try await client.send(API.Wallet.addTestMoney(Money(cents: 100)))
            Issue.record("expected an error")
        } catch {
            #expect(error == .noResponse)
            #expect(error.isUncertainOutcome)
            #expect(error.message(for: .moneyMove) == "We couldn't confirm this move. Check Activity before you try again.")
        }
        // Nothing is retried: exactly one attempt per call.
        #expect(server.requests.count == 2)
    }

    @Test func malformedSuccessIsInvalidResponse() async throws {
        let server = StubServer()
        server.enqueue(.http(status: 200, json: #"{"unexpected":true}"#))
        let client = await makeClient(server, token: "t")
        await #expect(throws: APIError.invalidResponse) { try await client.send(API.Dashboard.summary()) }
    }
}

@Suite("Server environment")
struct ServerEnvironmentTests {
    @Test func developerSettingsValidation() {
        #if DEBUG
        #expect((try? ServerEnvironment.validate("http://localhost:8787/api").get())?.absoluteString == "http://localhost:8787/api")
        #expect((try? ServerEnvironment.validate(" https://api.example.com/api ").get()) != nil)
        #expect((try? ServerEnvironment.validate("http://localhost:8787/api/").get()) == nil)
        #expect((try? ServerEnvironment.validate("localhost:8787/api").get()) == nil)
        #expect((try? ServerEnvironment.validate("ftp://x/api").get()) == nil)
        #expect((try? ServerEnvironment.validate("http://").get()) == nil)
        #expect(ServerEnvironment.displayHost(URL(string: "http://my-mac.local:8787/api")!) == "my-mac.local:8787")
        #endif
    }

    @Test func localNetworkHostFromBuildSetting() {
        #if DEBUG
        #expect(ServerEnvironment.localNetworkURL(host: "my-mac.local").absoluteString == "http://my-mac.local:8787/api")
        #expect(ServerEnvironment.localNetworkURL(host: " my-mac.local ").absoluteString == "http://my-mac.local:8787/api")
        #expect(ServerEnvironment.localNetworkURL(host: nil) == ServerEnvironment.localNetworkPlaceholder)
        #expect(ServerEnvironment.localNetworkURL(host: "") == ServerEnvironment.localNetworkPlaceholder)
        #expect(ServerEnvironment.localNetworkURL(host: "$(DEV_MAC_HOST)") == ServerEnvironment.localNetworkPlaceholder)
        #expect(ServerEnvironment.localNetworkURL(host: "example.com/x?y") == ServerEnvironment.localNetworkPlaceholder)
        #expect(ServerEnvironment.localNetworkURL(host: "user@example.com") == ServerEnvironment.localNetworkPlaceholder)
        #expect(ServerEnvironment.localNetworkURL(host: "192.168.1.20").absoluteString == "http://192.168.1.20:8787/api")
        for malformed in [".", "a..b", "-mac.local", "mac-.local", "my-mac.local.", "mac.local:9000", "fe80::1", "[fe80::1]"] {
            #expect(ServerEnvironment.localNetworkURL(host: malformed) == ServerEnvironment.localNetworkPlaceholder, "\(malformed)")
        }
        #endif
    }

    @Test func debugDefaultsAndPolicy() {
        #if DEBUG
        #if targetEnvironment(simulator)
        #expect(ServerEnvironment.defaultBaseURL == ServerEnvironment.simulatorDefault)
        #endif
        #expect(ServerEnvironment.isAllowed(URL(string: "http://localhost:8787/api")!))
        #endif
        #expect(!ServerEnvironment.isAllowed(URL(string: "file:///etc/passwd")!))
    }

    @Test func overrideRoundTrip() throws {
        #if DEBUG
        let defaults = try #require(UserDefaults(suiteName: "server-env-\(UUID().uuidString)"))
        #expect(ServerEnvironment.currentBaseURL(defaults: defaults) == ServerEnvironment.defaultBaseURL)
        let custom = URL(string: "http://192.168.1.20:8787/api")!
        ServerEnvironment.saveOverride(custom, defaults: defaults)
        #expect(ServerEnvironment.currentBaseURL(defaults: defaults) == custom)
        ServerEnvironment.clearOverride(defaults: defaults)
        #expect(ServerEnvironment.currentBaseURL(defaults: defaults) == ServerEnvironment.defaultBaseURL)
        #endif
    }
}
