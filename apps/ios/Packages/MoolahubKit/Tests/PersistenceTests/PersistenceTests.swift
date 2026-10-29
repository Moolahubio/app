import Foundation
import Security
import Testing
@testable import Persistence

private struct Sample: Codable, Equatable, Sendable {
    let name: String
    let cents: Int64
    let at: Date
}

@Suite("Snapshot cache")
struct SnapshotCacheTests {
    private func makeCache(now: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> (SnapshotCache, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapshotCacheTests-\(UUID().uuidString)", isDirectory: true)
        return (SnapshotCache(rootDirectory: root, now: { now }), root)
    }

    @Test func roundTripsPerUser() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = Sample(name: "Emergency fund", cents: 125_000, at: Date(timeIntervalSince1970: 1_790_000_000.123))

        await cache.setUser("user-a")
        await cache.save(sample, for: .goals)
        let loaded = try #require(await cache.load(Sample.self, for: .goals))
        #expect(loaded.value == sample)
        #expect(loaded.savedAt == Date(timeIntervalSince1970: 1_800_000_000))

        // Another user never sees user A's data.
        await cache.setUser("user-b")
        #expect(await cache.load(Sample.self, for: .goals) == nil)

        await cache.setUser("user-a")
        #expect(await cache.load(Sample.self, for: .goals) != nil)
    }

    @Test func nothingIsReadOrWrittenWithoutAUser() async {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        await cache.save(Sample(name: "x", cents: 1, at: Date()), for: .dashboard)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await cache.load(Sample.self, for: .dashboard) == nil)
    }

    @Test func clearAllRemovesEverythingAndUnscopes() async {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        await cache.setUser("user-a")
        await cache.save(Sample(name: "x", cents: 1, at: Date()), for: .dashboard)
        #expect(FileManager.default.fileExists(atPath: root.path))
        await cache.clearAll()
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(await cache.hasUser == false)
        await cache.setUser("user-a")
        #expect(await cache.load(Sample.self, for: .dashboard) == nil)
    }

    @Test func rootIsExcludedFromBackupAndUserDirectoryIsHashed() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        await cache.setUser("user@example.com")
        await cache.save(Sample(name: "x", cents: 1, at: Date()), for: .goal("abc/../def"))
        let values = try root.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        let children = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(children.count == 1)
        #expect(!children[0].contains("user"))
        #expect(children[0].count == 64)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(children[0]).path)
        #expect(files.count == 1)
        #expect(!files[0].contains("/"))
        #expect(!files[0].contains(".."))
    }

    @Test func corruptFilesReadAsMissing() async throws {
        let (cache, root) = makeCache()
        defer { try? FileManager.default.removeItem(at: root) }
        await cache.setUser("u")
        await cache.save(Sample(name: "x", cents: 1, at: Date()), for: .wallet)
        let userDir = try FileManager.default.contentsOfDirectory(atPath: root.path)[0]
        try Data("{not json".utf8).write(to: root.appendingPathComponent(userDir).appendingPathComponent("wallet.json"))
        #expect(await cache.load(Sample.self, for: .wallet) == nil)
    }

    @Test func updatedText() {
        let saved = Date(timeIntervalSince1970: 1_000_000)
        #expect(SnapshotAge.text(savedAt: saved, now: saved.addingTimeInterval(30)) == "Updated just now")
        #expect(SnapshotAge.text(savedAt: saved, now: saved.addingTimeInterval(60)) == "Updated 1 min ago")
        #expect(SnapshotAge.text(savedAt: saved, now: saved.addingTimeInterval(59 * 60)) == "Updated 59 min ago")
        #expect(SnapshotAge.text(savedAt: saved, now: saved.addingTimeInterval(2 * 3600)) == "Updated 2 hr ago")
        #expect(SnapshotAge.text(savedAt: saved, now: saved.addingTimeInterval(26 * 3600)) == "Updated 1 day ago")
        #expect(SnapshotAge.text(savedAt: saved, now: saved.addingTimeInterval(80 * 3600)) == "Updated 3 days ago")
        // Clock skew never shows a negative age.
        #expect(SnapshotAge.text(savedAt: saved, now: saved.addingTimeInterval(-500)) == "Updated just now")
    }
}

/// Package test bundles run without a host app, and the iOS Simulator refuses
/// Keychain access without one (errSecMissingEntitlement, -34018). The same
/// checks run app-hosted in MoolahubTests/KeychainHostedTests.swift, which is
/// where they are guaranteed to execute.
private let keychainAvailable: Bool = {
    let probe = KeychainTokenStore(service: "io.moolahub.app.tests.probe")
    do {
        try probe.saveToken("probe")
        try probe.deleteToken()
        return true
    } catch {
        return false
    }
}()

@Suite("Keychain token store", .serialized)
struct KeychainTokenStoreTests {
    @Test(.enabled(if: keychainAvailable, "Keychain needs a host app on the simulator; covered by MoolahubTests"))
    func savesReadsReplacesAndDeletes() throws {
        let store = KeychainTokenStore(service: "io.moolahub.app.tests.\(UUID().uuidString)")
        defer { try? store.deleteToken() }

        #expect(try store.readToken() == nil)
        try store.saveToken("first-token")
        #expect(try store.readToken() == "first-token")
        try store.saveToken("second-token")
        #expect(try store.readToken() == "second-token")
        #expect(store.storedAccessibility() == (kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String))
        try store.deleteToken()
        #expect(try store.readToken() == nil)
        // Deleting twice is fine.
        try store.deleteToken()
    }

    @Test func inMemoryStore() throws {
        let store = InMemoryTokenStore()
        #expect(try store.readToken() == nil)
        try store.saveToken("t")
        #expect(try store.readToken() == "t")
        try store.deleteToken()
        #expect(try store.readToken() == nil)
    }
}
