import CryptoKit
import Foundation

/// Name of one cached snapshot ("dashboard", "goals", "goal-<id>").
/// Characters outside `[A-Za-z0-9_-]` are hashed so any id is a safe file name.
public struct SnapshotKey: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public var description: String { rawValue }

    /// File-system-safe name.
    var fileName: String {
        let allowed = rawValue.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 45, 95: true
            default: false
            }
        }
        if allowed && !rawValue.isEmpty && rawValue.count <= 100 { return rawValue + ".json" }
        return SnapshotCache.sha256Hex(rawValue) + ".json"
    }

    // Keys shared across features. Features may add their own
    // (`SnapshotKey("goal-\(id)")`); keep them unique per feature.
    public static let dashboard: SnapshotKey = "dashboard"
    public static let goals: SnapshotKey = "goals"
    public static let groups: SnapshotKey = "groups"
    public static let groupInvites: SnapshotKey = "group-invites"
    public static let activity: SnapshotKey = "activity"
    public static let wallet: SnapshotKey = "wallet"
    public static let profile: SnapshotKey = "profile"
    /// The streak overview (`StreakStore`, read by Home, the Streak screen and
    /// Account).
    public static let streaks: SnapshotKey = "streaks"
    /// `GET /learn/lessons`, shared by Home's "Keep learning" and the Learn
    /// list.
    public static let lessons: SnapshotKey = "lessons"
    public static func goal(_ id: String) -> SnapshotKey { SnapshotKey("goal-\(id)") }
    public static func group(_ id: String) -> SnapshotKey { SnapshotKey("group-\(id)") }
    /// One lesson (`GET /learn/lessons/{slug}`).
    public static func lesson(_ slug: String) -> SnapshotKey { SnapshotKey("lesson-\(slug)") }
}

/// A cached value and when it was saved.
public struct Snapshot<Value: Sendable>: Sendable {
    public let value: Value
    public let savedAt: Date

    public init(value: Value, savedAt: Date) {
        self.value = value
        self.savedAt = savedAt
    }

    /// "Updated just now", "Updated 5 min ago", "Updated 2 hr ago",
    /// "Updated 3 days ago".
    public func updatedText(now: Date = Date()) -> String {
        SnapshotAge.text(savedAt: savedAt, now: now)
    }
}

public enum SnapshotAge {
    public static func text(savedAt: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(savedAt))
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "Updated just now" }
        if minutes < 60 { return "Updated \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Updated \(hours) hr ago" }
        let days = hours / 24
        return days == 1 ? "Updated 1 day ago" : "Updated \(days) days ago"
    }
}

/// Last-known API responses on disk, so screens can show something while
/// offline (with "Updated N min ago") instead of an empty state or `$0.00`.
///
/// - Lives in Application Support/Snapshots/<sha256(user id)>/, excluded from
///   backups, files protected until first unlock.
/// - Scoped to the signed-in user: nothing is read or written while no user is
///   set. `clearAll()` on sign-out deletes every user's snapshots.
/// - Never the source of truth: always refresh from the API and show the
///   snapshot only as a stand-in, with its age.
public actor SnapshotCache {
    private let root: URL
    private var userDirectory: URL?
    private let now: @Sendable () -> Date

    /// - Parameter rootDirectory: defaults to Application Support/Snapshots.
    public init(rootDirectory: URL? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        if let rootDirectory {
            root = rootDirectory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            root = support.appendingPathComponent("Snapshots", isDirectory: true)
        }
        self.now = now
    }

    /// Scopes the cache to a user (nil when signed out).
    public func setUser(_ userID: String?) {
        guard let userID, !userID.isEmpty else {
            userDirectory = nil
            return
        }
        userDirectory = root.appendingPathComponent(Self.sha256Hex(userID), isDirectory: true)
    }

    public var hasUser: Bool { userDirectory != nil }

    public func save<Value: Encodable & Sendable>(_ value: Value, for key: SnapshotKey) {
        guard let directory = userDirectory else { return }
        do {
            try ensureDirectory(directory)
            let envelope = EncodableEnvelope(savedAt: now(), value: value)
            let data = try JSONEncoder().encode(envelope)
            try data.write(
                to: directory.appendingPathComponent(key.fileName),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch {
            // A failed cache write must never break a screen; the next
            // successful load writes again.
        }
    }

    public func load<Value: Decodable & Sendable>(_ type: Value.Type, for key: SnapshotKey) -> Snapshot<Value>? {
        guard let directory = userDirectory else { return nil }
        let url = directory.appendingPathComponent(key.fileName)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(DecodableEnvelope<Value>.self, from: data)
        else { return nil }
        return Snapshot(value: envelope.value, savedAt: envelope.savedAt)
    }

    public func remove(_ key: SnapshotKey) {
        guard let directory = userDirectory else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(key.fileName))
    }

    /// Deletes every user's snapshots and unscopes the cache (sign-out).
    public func clearAll() {
        userDirectory = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func ensureDirectory(_ directory: URL) throws {
        let manager = FileManager.default
        if !manager.fileExists(atPath: root.path) {
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            var rootURL = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? rootURL.setResourceValues(values)
        }
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

// Dates use the default (Double) strategy on both sides, so cached DTOs
// round-trip exactly regardless of the API's string formats.
private struct EncodableEnvelope<Value: Encodable>: Encodable {
    let savedAt: Date
    let value: Value
}

private struct DecodableEnvelope<Value: Decodable>: Decodable {
    let savedAt: Date
    let value: Value
}
