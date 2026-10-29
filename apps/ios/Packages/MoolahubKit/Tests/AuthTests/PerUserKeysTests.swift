import Auth
import Foundation
import Testing

// `PerUserKeys` (SPEC §2.2, D-25): the exact key names, and which keys each
// removal takes.

@Suite("PerUserKeys")
struct PerUserKeysTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "AuthTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func keysAreTheSessionStreakNamesWithTheRawUserID() {
        #expect(PerUserKeys.streakPrefix == "session.streak.")
        #expect(PerUserKeys.badgesSeen(userID: "00000000-0000-4000-8000-0000000000aa") == "session.streak.badgesSeen.00000000-0000-4000-8000-0000000000aa")
        #expect(PerUserKeys.timeZoneSent(userID: "00000000-0000-4000-8000-0000000000aa") == "session.streak.timezoneSent.00000000-0000-4000-8000-0000000000aa")
        #expect(PerUserKeys.all(for: "u1") == ["session.streak.badgesSeen.u1", "session.streak.timezoneSent.u1"])
    }

    @Test func removeAllTakesExactlyThatUsersKeys() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(["2026-q1"], forKey: PerUserKeys.badgesSeen(userID: "user-a"))
        defaults.set("Africa/Accra", forKey: PerUserKeys.timeZoneSent(userID: "user-a"))
        defaults.set(["2026-q2"], forKey: PerUserKeys.badgesSeen(userID: "user-b"))
        defaults.set("Europe/London", forKey: PerUserKeys.timeZoneSent(userID: "user-b"))
        // An id that starts with the same characters is another user.
        defaults.set(["2026-q3"], forKey: PerUserKeys.badgesSeen(userID: "user-a2"))
        defaults.set("user-a", forKey: "session.lastUserID")

        PerUserKeys.removeAll(for: "user-a", in: defaults)

        #expect(defaults.object(forKey: "session.streak.badgesSeen.user-a") == nil)
        #expect(defaults.object(forKey: "session.streak.timezoneSent.user-a") == nil)
        #expect(defaults.stringArray(forKey: "session.streak.badgesSeen.user-b") == ["2026-q2"])
        #expect(defaults.string(forKey: "session.streak.timezoneSent.user-b") == "Europe/London")
        #expect(defaults.stringArray(forKey: "session.streak.badgesSeen.user-a2") == ["2026-q3"])
        #expect(defaults.string(forKey: "session.lastUserID") == "user-a")
    }

    @Test func removeAllStreakKeysTakesEveryUsersStreakKeysAndNothingElse() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        for user in ["user-a", "user-b"] {
            defaults.set(["2026-q1"], forKey: PerUserKeys.badgesSeen(userID: user))
            defaults.set("Africa/Accra", forKey: PerUserKeys.timeZoneSent(userID: user))
        }
        defaults.set("user-a", forKey: "session.lastUserID")
        defaults.set("marker", forKey: "session.installMarker")
        defaults.set(true, forKey: "device.appLockEnabled")

        PerUserKeys.removeAllStreakKeys(in: defaults)

        let left = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("session.streak.") }
        #expect(left.isEmpty)
        #expect(defaults.string(forKey: "session.lastUserID") == "user-a")
        #expect(defaults.string(forKey: "session.installMarker") == "marker")
        #expect(defaults.bool(forKey: "device.appLockEnabled"))
    }
}
