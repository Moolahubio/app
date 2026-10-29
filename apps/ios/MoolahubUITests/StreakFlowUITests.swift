import XCTest

/// End-to-end UI tests for the Savings streak (SPEC §2.8, streaks.md ST.15.2),
/// run against the local dev backend through `apps/ios/scripts/ui-test.sh`.
/// Owned by lane S. F0 stub with no tests yet: the tests that reach the
/// Streak screen through another lane's row run and merge after that lane
/// (SPEC §8.5 step 7).
final class StreakFlowUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }
}
