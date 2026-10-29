import Foundation

/// When the time zone sender talks to the server (SPEC §4.5; streaks.md
/// ST.1.5, account.md §12). Auth's `TimeZoneSync` sends and stores; these
/// rules decide.
public enum TimeZoneSyncRule {
    /// True when the zone differs from the one last sent for this user, or
    /// nothing was sent yet.
    public static func shouldSend(current: String, lastSent: String?) -> Bool {
        current != lastSent
    }

    /// True when the server's answer echoes the zone sent, exactly. Only then
    /// is it stored as sent: a server before C3, or one that kept another
    /// zone, gets the zone again at the next trigger.
    public static func shouldStore(sent: String, echoed: String?) -> Bool {
        echoed == sent
    }
}
