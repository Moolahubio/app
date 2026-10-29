import Auth
import Testing

// `SignedOutArrival.route(for:)` (SPEC §8.2 item 5, D-43; account.md §17
// item 5): every `SignedOutReason` and nil.

@Suite("SignedOutArrival")
struct SignedOutArrivalTests {
    @Test(arguments: [SignedOutReason.sessionExpired, .passwordReset, .serverChanged])
    func expiryResetAndServerChangeGoToSignIn(_ reason: SignedOutReason) {
        #expect(SignedOutArrival.route(for: reason) == .signIn)
    }

    @Test func aSignOutGoesToWelcomeWithNoToast() {
        #expect(SignedOutArrival.route(for: .userSignedOut) == .welcome(toast: nil))
    }

    @Test func noReasonGoesToWelcomeWithNoToast() {
        #expect(SignedOutArrival.route(for: nil) == .welcome(toast: nil))
    }

    @Test func deactivationGoesToWelcomeWithTheDeactivatedToast() {
        #expect(SignedOutArrival.route(for: .accountDeactivated) == .welcome(toast: .deactivated))
    }

    @Test func deletionGoesToWelcomeWithTheDeletedToast() {
        #expect(SignedOutArrival.route(for: .accountDeleted) == .welcome(toast: .deleted))
    }
}
