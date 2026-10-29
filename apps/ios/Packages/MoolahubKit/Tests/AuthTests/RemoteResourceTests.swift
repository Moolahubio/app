import APIClient
import Auth
import Domain
import Foundation
import Persistence
import Testing

// `RemoteResource` (SPEC §1.9, D-24): one request at a time, a caller that
// goes away cancels the request only when it was the last one waiting, a
// caller already cancelled sends nothing, and a generation token that drops
// answers arriving after `reset()` or `replace(with:)`.

@MainActor
@Suite("RemoteResource coalescing and generations", .timeLimit(.minutes(1)))
struct RemoteResourceTests {
    @Test func aRefreshWhileOneIsInFlightAwaitsItAndSendsNothing() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        let first = Task { await resource.refresh() }
        let second = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        await settle()
        // Both callers are waiting, on one request.
        #expect(await gate.callCount == 1)
        #expect(resource.isLoading)
        await gate.answer(call: 1, with: "fresh")
        await first.value
        await second.value

        #expect(await gate.callCount == 1)
        #expect(resource.value == "fresh")
        #expect(!resource.isLoading)
        #expect(resource.error == nil)

        // Once it has landed, the next refresh sends a new request.
        let third = Task { await resource.refresh() }
        await gate.waitForCalls(2)
        await gate.answer(call: 2, with: "again")
        await third.value
        #expect(await gate.callCount == 2)
        #expect(resource.value == "again")
    }

    @Test func aCallerThatGoesAwayReturnsAndOnlyTheLastOneCancelsTheFetch() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        // Two callers: the one that goes away returns, the other keeps the fetch.
        let leaving = Task { await resource.refresh() }
        let staying = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        leaving.cancel()
        await leaving.value
        #expect(resource.isLoading)
        await gate.answer(call: 1, with: "kept")
        await staying.value
        #expect(resource.value == "kept")

        // The only caller goes away (its view's task is cancelled): the fetch
        // is dropped, as a lone caller's request always was.
        let alone = Task { await resource.refresh() }
        await gate.waitForCalls(2)
        alone.cancel()
        await alone.value
        #expect(!resource.isLoading)
        await gate.answer(call: 2, with: "dropped")
        await settle()
        #expect(resource.value == "kept")
        #expect(resource.error == nil)

        // The next refresh is a new request.
        let next = Task { await resource.refresh() }
        await gate.waitForCalls(3)
        await gate.answer(call: 3, with: "new")
        await next.value
        #expect(resource.value == "new")
        #expect(await gate.callCount == 3)
    }

    @Test func aCallerAlreadyCancelledSendsNothing() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        // Each task is cancelled before it runs, as a view's `.task` is when
        // the view goes away first.
        let refresh = Task { await resource.refresh() }
        refresh.cancel()
        await refresh.value
        let load = Task { await resource.load() }
        load.cancel()
        await load.value
        await settle()
        #expect(await gate.callCount == 0)
        #expect(!resource.isLoading)
        #expect(resource.value == nil)

        // The next caller still gets a request.
        let next = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        await gate.answer(call: 1, with: "fresh")
        await next.value
        #expect(resource.value == "fresh")
    }

    @Test func resetDropsTheAnswerOfAFetchStartedBeforeIt() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        let waiting = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        resource.reset()
        // Whoever awaited the dropped fetch returns now, before it answers.
        await waiting.value
        #expect(!resource.isLoading)

        await gate.answer(call: 1, with: "stale")
        await settle()
        #expect(resource.value == nil)
        #expect(resource.updatedAt == nil)
        #expect(resource.phase == .loading)

        // The next refresh is a new request, and its answer lands.
        let next = Task { await resource.refresh() }
        await gate.waitForCalls(2)
        await gate.answer(call: 2, with: "new")
        await next.value
        #expect(resource.value == "new")
    }

    @Test func aFailureFromAnOlderGenerationIsDroppedToo() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        let waiting = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        resource.reset()
        await waiting.value
        await gate.fail(call: 1, with: .noResponse)
        await settle()
        #expect(resource.error == nil)
        #expect(resource.phase == .loading)
    }

    @Test func resetClearsTheValueItsAgeAndTheError() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        let load = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        await gate.answer(call: 1, with: "value")
        await load.value
        let failing = Task { await resource.refresh() }
        await gate.waitForCalls(2)
        await gate.fail(call: 2, with: .noResponse)
        await failing.value
        #expect(resource.value == "value")
        #expect(resource.error == .noResponse)

        resource.reset()
        #expect(resource.value == nil)
        #expect(resource.updatedAt == nil)
        #expect(resource.error == nil)
        #expect(!resource.isShowingCachedValue)
        #expect(!resource.isLoading)
        #expect(resource.phase == .loading)
    }

    @Test func replaceDropsAnOlderFetchStillInFlight() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        let waiting = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        resource.replace(with: "from the write")
        await waiting.value
        await gate.answer(call: 1, with: "older")
        await settle()
        #expect(resource.value == "from the write")
        #expect(!resource.isLoading)
    }

    @Test func loadShowsTheSnapshotThenTheLiveValueAndSavesIt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuthTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = SnapshotCache(rootDirectory: root)
        await cache.setUser("user-a")
        await cache.save("cached", for: .streaks)
        let gate = FetchGate<String>()
        let resource = RemoteResource<String>(cacheKey: .streaks, cache: cache) { try await gate.fetch() }

        let load = Task { await resource.load() }
        await gate.waitForCalls(1)
        #expect(resource.value == "cached")
        #expect(resource.isShowingCachedValue)
        #expect(resource.updatedText() != nil)

        await gate.answer(call: 1, with: "live")
        await load.value
        #expect(resource.value == "live")
        #expect(!resource.isShowingCachedValue)
        #expect(resource.updatedText() == nil)
        #expect(await cache.load(String.self, for: .streaks)?.value == "live")
    }

    @Test func aFailedRefreshKeepsWhatIsShown() async {
        let gate = FetchGate<String>()
        let resource = RemoteResource<String> { try await gate.fetch() }

        let load = Task { await resource.refresh() }
        await gate.waitForCalls(1)
        await gate.answer(call: 1, with: "shown")
        await load.value
        let failing = Task { await resource.refresh() }
        await gate.waitForCalls(2)
        await gate.fail(call: 2, with: .noResponse)
        await failing.value

        #expect(resource.value == "shown")
        #expect(resource.error == .noResponse)
        #expect(resource.phase == .loaded)
    }
}
