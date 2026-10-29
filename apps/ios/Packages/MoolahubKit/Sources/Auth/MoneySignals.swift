import Domain
import Foundation

/// The shared money signal (SPEC §1.9, home.md §6.2, savings-groups SG-J1).
/// Every money flow posts it once when its receipt's "Done" is tapped (Add
/// test money, Move to goal, Move to balance, Delete goal, Pay in); Home,
/// Activity, the Savings list, Goal detail and the Groups list listen.
///
/// It is the same notification as Domain's `AppSignals.moneyMoved`, so the
/// flows that still post through `AppSignals` and the screens that listen
/// through either name all meet until the lanes move their callers here.
public enum MoneySignals {
    public static let moneyMoved = AppSignals.moneyMoved

    @MainActor
    public static func postMoneyMoved() {
        NotificationCenter.default.post(name: moneyMoved, object: nil)
    }
}
