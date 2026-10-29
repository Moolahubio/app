import Testing
@testable import Domain

/// SPEC §4.5's Decision and Store rows (account.md §17 item 7). The sender's
/// use of them is `AuthTests/TimeZoneSyncTests`.
@Suite("TimeZoneSyncRule")
struct TimeZoneSyncRuleTests {
    @Test func sendsWhenNothingWasSent() {
        #expect(TimeZoneSyncRule.shouldSend(current: "Africa/Accra", lastSent: nil))
    }

    @Test func sendsWhenTheZoneDiffersFromTheOneSent() {
        #expect(TimeZoneSyncRule.shouldSend(current: "Europe/London", lastSent: "Africa/Accra"))
        #expect(TimeZoneSyncRule.shouldSend(current: "Africa/Lagos", lastSent: "Africa/Accra"))
        // Exact names: a different spelling is a different zone.
        #expect(TimeZoneSyncRule.shouldSend(current: "Africa/Accra", lastSent: "africa/accra"))
    }

    @Test func sendsNothingWhenTheZoneWasSent() {
        #expect(!TimeZoneSyncRule.shouldSend(current: "Africa/Accra", lastSent: "Africa/Accra"))
        #expect(!TimeZoneSyncRule.shouldSend(current: "America/Argentina/Buenos_Aires", lastSent: "America/Argentina/Buenos_Aires"))
    }

    @Test func storesOnlyAnExactEcho() {
        #expect(TimeZoneSyncRule.shouldStore(sent: "Africa/Accra", echoed: "Africa/Accra"))
        // A server before C3 has no `timezone`; another zone means it kept its own.
        #expect(!TimeZoneSyncRule.shouldStore(sent: "Africa/Accra", echoed: nil))
        #expect(!TimeZoneSyncRule.shouldStore(sent: "Africa/Accra", echoed: "UTC"))
        #expect(!TimeZoneSyncRule.shouldStore(sent: "Africa/Accra", echoed: "africa/accra"))
        #expect(!TimeZoneSyncRule.shouldStore(sent: "Africa/Accra", echoed: ""))
    }
}
