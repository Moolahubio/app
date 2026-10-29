import Foundation

/// Signals between features, which never import each other (README §4).
public enum AppSignals {
    /// Money may have moved: a money move's receipt, or a move whose outcome is
    /// unknown (DESIGN.md v2 J0.7). Home refreshes its balance and goals, while
    /// the sheet is still up and again when it closes.
    public static let moneyMoved = Notification.Name("io.moolahub.home.moneyMoved")

    @MainActor
    public static func postMoneyMoved() {
        NotificationCenter.default.post(name: moneyMoved, object: nil)
    }
}
