import Foundation

/// The one place per-user device keys are built (SPEC §2.2, D-25). Writers
/// and account deletion use the same functions, so a key is never re-typed.
///
/// Keys hold raw user ids, as `session.lastUserID` already does. They are
/// kept on sign-out and deactivation; account deletion removes one user's
/// (`removeAll(for:in:)`), and Developer settings "Reset app data" and
/// `-mh-reset-state` (prefix `session.`) remove everyone's.
public enum PerUserKeys {
    /// Every per-user streak key starts with this.
    public static let streakPrefix = "session.streak."

    /// The quarter badges this user has seen on this device (`[String]`).
    public static func badgesSeen(userID: String) -> String {
        "\(streakPrefix)badgesSeen.\(userID)"
    }

    /// The time zone last sent for this user and echoed by the server.
    public static func timeZoneSent(userID: String) -> String {
        "\(streakPrefix)timezoneSent.\(userID)"
    }

    /// Every key this helper builds for one user.
    public static func all(for userID: String) -> [String] {
        [badgesSeen(userID: userID), timeZoneSent(userID: userID)]
    }

    /// Removes one user's keys (account deletion). Other users' keys stay.
    public static func removeAll(for userID: String, in defaults: UserDefaults) {
        for key in all(for: userID) {
            defaults.removeObject(forKey: key)
        }
    }

    /// Removes every user's streak keys (Developer settings "Reset app data").
    public static func removeAllStreakKeys(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(streakPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
