import Foundation

/// What "Add money" opens (home.md H9): Home's tile and Pay in when there is
/// not enough money. The enum exists in every build so the rule can be tested
/// as Release; only `appSheet` knows that Release has no test-money sheet.
public enum AddMoneyRoute: Equatable, Sendable {
    /// Debug builds with the faucet on (or not known yet).
    case addTestMoney
    /// "Adding money isn't available yet." (`AppSheet.addMoney`).
    case addMoney

    /// Decided at tap time. Debug: the faucet on or not known (`nil`: the read
    /// is running, failed or offline; the server refuses a deposit when it is
    /// off) gives `.addTestMoney`, off gives `.addMoney`. Not Debug: always
    /// `.addMoney`.
    public static func sheet(isDebugBuild: Bool, faucetEnabled: Bool?) -> AddMoneyRoute {
        guard isDebugBuild, faucetEnabled != false else { return .addMoney }
        return .addTestMoney
    }

    /// True only in a Debug build.
    public static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The sheet to present. Release has no `AppSheet.addTestMoney`, so every
    /// case gives `.addMoney` there.
    public var appSheet: AppSheet {
        #if DEBUG
        switch self {
        case .addTestMoney: .addTestMoney
        case .addMoney: .addMoney
        }
        #else
        .addMoney
        #endif
    }
}
