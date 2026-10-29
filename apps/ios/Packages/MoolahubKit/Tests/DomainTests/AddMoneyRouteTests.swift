import Testing
@testable import Domain

/// home.md H9's routing table, plus Release (`isDebugBuild: false`).
@Suite("AddMoneyRoute")
struct AddMoneyRouteTests {
    @Test func debugWithTheFaucetOnOpensTestMoney() {
        #expect(AddMoneyRoute.sheet(isDebugBuild: true, faucetEnabled: true) == .addTestMoney)
    }

    @Test func debugWithTheFaucetOffOpensAddMoney() {
        #expect(AddMoneyRoute.sheet(isDebugBuild: true, faucetEnabled: false) == .addMoney)
    }

    /// The wallet read is running, failed or offline: the server's refusal
    /// is the backstop.
    @Test func debugWithTheFaucetUnknownOpensTestMoney() {
        #expect(AddMoneyRoute.sheet(isDebugBuild: true, faucetEnabled: nil) == .addTestMoney)
    }

    @Test(arguments: [true, false, nil] as [Bool?])
    func releaseAlwaysOpensAddMoney(_ faucetEnabled: Bool?) {
        #expect(AddMoneyRoute.sheet(isDebugBuild: false, faucetEnabled: faucetEnabled) == .addMoney)
    }

    /// The tests build Debug, so the Debug sheets are the ones mapped.
    @Test func debugBuildMapsEachRouteToItsSheet() {
        #if DEBUG
        #expect(AddMoneyRoute.isDebugBuild)
        #expect(AddMoneyRoute.addTestMoney.appSheet == .addTestMoney)
        #expect(AddMoneyRoute.addMoney.appSheet == .addMoney)
        #expect(AppSheet.addTestMoney.id == "addTestMoney")
        #else
        #expect(!AddMoneyRoute.isDebugBuild)
        #expect(AddMoneyRoute.addTestMoney.appSheet == .addMoney)
        #endif
        #expect(AppSheet.addMoney.id == "addMoney")
    }
}
