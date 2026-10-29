import Foundation
import Testing
@testable import Domain

// Lane A's rules (account.md §17 items 1 to 4 and 6; SPEC §4.3, §4.6, D-43):
// one suite per rule.

/// The JSON body a request would send, as an object.
private func encodedObject(_ value: some Encodable) throws -> [String: Any] {
    let data = try APICoding.makeEncoder().encode(value)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A `GET /circles` row with only `status` mattering.
private func circle(_ status: String, id: Int) throws -> CircleSummary {
    try Fixture.decode(CircleSummary.self, object: [
        "id": "00000000-0000-4000-8000-0000000000\(String(format: "%02d", id))",
        "name": "QA Group \(id)", "status": status, "type": "rotating", "frequency": "monthly",
        "contributionCents": 10000, "payoutCents": 40000, "potCents": 40000, "memberCount": 4,
        "targetMembers": NSNull(), "feeBps": 0, "myPayoutRound": 1, "currentRound": 1, "totalRounds": 4,
        "nextPayoutDate": NSNull(), "imageUrl": NSNull(),
    ])
}

private struct ReadFailed: Error {}

@Suite("DeleteAccountPrecheck")
struct DeleteAccountPrecheckTests {
    /// The demo account's samples: $3,030.12, 18 active and 2 forming
    /// groups, 2 goals: three rows in the server's order (AC-12).
    @Test func theSamplesBlockWithThreeRowsInTheServersOrder() throws {
        let summary = try Fixture.decode(DashboardSummary.self, "GET_dashboard_summary")
        let goals = try Fixture.decode([Goal].self, "GET_goals")
        let statuses = Array(repeating: "active", count: 18) + ["forming", "forming"]
        let blockers = DeleteAccountPrecheck.blockers(
            totalCents: summary.totalCents, balanceUnavailable: summary.balanceUnavailable,
            circleStatuses: statuses, goalCount: goals.count
        )
        #expect(blockers == [
            .balance(Money(cents: 303_012)), .groups(count: 20), .goals(count: 2, afterBalance: true),
        ])
        #expect(blockers[0].value == "$3,030.12")
        #expect(blockers[1].value == "20")
        #expect(blockers[2].value == "2")
    }

    @Test func nothingInTheWayIsClear() throws {
        #expect(DeleteAccountPrecheck.blockers(totalCents: 0, balanceUnavailable: false, circleStatuses: [], goalCount: 0).isEmpty)
        #expect(DeleteAccountPrecheck.blockers(totalCents: 0, balanceUnavailable: nil, circleStatuses: [], goalCount: 0).isEmpty)
        let summary = try zeroSummary()
        let outcome = DeleteAccountPrecheck.outcome(
            summary: .success(summary),
            circles: Result<[CircleSummary], ReadFailed>.success([]),
            goals: .success([])
        )
        #expect(outcome == .clear)
        #expect(outcome.blockers.isEmpty)
    }

    /// "completed" (and any other status) never blocks; "forming" and
    /// "active" do, and only they are counted.
    @Test func onlyFormingAndActiveGroupsBlock() throws {
        #expect(DeleteAccountPrecheck.blockers(
            totalCents: 0, balanceUnavailable: false, circleStatuses: ["completed", "completed", "cancelled"], goalCount: 0
        ).isEmpty)
        #expect(DeleteAccountPrecheck.blockers(
            totalCents: 0, balanceUnavailable: false, circleStatuses: ["completed", "forming", "active", "Active"], goalCount: 0
        ) == [.groups(count: 2)])
        let summary = try zeroSummary()
        let circles = try [circle("completed", id: 1), circle("active", id: 2)]
        let outcome = DeleteAccountPrecheck.outcome(
            summary: .success(summary),
            circles: Result<[CircleSummary], ReadFailed>.success(circles),
            goals: .success([])
        )
        #expect(outcome == .blocked([.groups(count: 1)]))
    }

    /// `balanceUnavailable` blocks with no figure, whatever `totalCents` says
    /// (AC-13): never "$0.00".
    @Test func anUnknownBalanceBlocksWithoutAFigure() {
        for total in [Int64(0), 303_012] {
            let blockers = DeleteAccountPrecheck.blockers(totalCents: total, balanceUnavailable: true, circleStatuses: [], goalCount: 1)
            #expect(blockers == [.balanceUnknown, .goals(count: 1, afterBalance: true)])
            #expect(blockers[0].value == nil)
            #expect(blockers[0].subline == "We couldn't read your balance just now. Try again in a few minutes.")
            #expect(blockers[0].accessibilityValue
                == "Not available. We couldn't read your balance just now. Try again in a few minutes.")
        }
    }

    /// D-17, AC-16b: with a balance row the goals sub-line is "Money in a
    /// goal counts toward your balance." and never "Delete them first.".
    @Test func aBalanceAboveZeroGivesTheGoalsSublineThatMoneyInAGoalCounts() {
        let blockers = DeleteAccountPrecheck.blockers(totalCents: 1, balanceUnavailable: false, circleStatuses: [], goalCount: 3)
        #expect(blockers == [.balance(Money(cents: 1)), .goals(count: 3, afterBalance: true)])
        let goals = blockers[1]
        #expect(goals.subline == "Money in a goal counts toward your balance.")
        #expect(goals.subline != "Delete them first.")
        #expect(goals.accessibilityValue == "3. Money in a goal counts toward your balance.")
    }

    /// With every goal at $0.00 there is no balance row: "Delete them first.".
    @Test func goalsWithoutABalanceRowSayDeleteThemFirst() {
        let blockers = DeleteAccountPrecheck.blockers(totalCents: 0, balanceUnavailable: false, circleStatuses: ["forming"], goalCount: 2)
        #expect(blockers == [.groups(count: 1), .goals(count: 2, afterBalance: false)])
        #expect(blockers[1].subline == "Delete them first.")
        #expect(blockers[1].accessibilityValue == "2. Delete them first.")
    }

    /// Any failed read gives `.error`, never `.clear` (AC-13).
    @Test func anyFailedReadIsAnErrorNeverClear() throws {
        let summary = try zeroSummary()
        let cases: [DeleteAccountPrecheck.Outcome] = [
            DeleteAccountPrecheck.outcome(
                summary: Result<DashboardSummary, ReadFailed>.failure(ReadFailed()), circles: .success([]), goals: .success([])
            ),
            DeleteAccountPrecheck.outcome(
                summary: .success(summary), circles: Result<[CircleSummary], ReadFailed>.failure(ReadFailed()), goals: .success([])
            ),
            DeleteAccountPrecheck.outcome(
                summary: .success(summary), circles: Result<[CircleSummary], ReadFailed>.success([]), goals: .failure(ReadFailed())
            ),
        ]
        for outcome in cases {
            #expect(outcome == .error)
            #expect(outcome.blockers.isEmpty)
        }
    }

    /// W10.9-acc7 and acc10 exactly, and the D-14 values (AC-16: no
    /// "funds", "withdraw", "release", "circle" or "Wait for them to finish").
    @Test func wordsAreTheSpecsAndAvoidTheServersSentences() {
        let rows: [DeleteAccountPrecheck.Blocker] = [
            .balance(Money(cents: 303_012)), .balanceUnknown, .groups(count: 20),
            .goals(count: 2, afterBalance: true), .goals(count: 2, afterBalance: false),
        ]
        #expect(rows[0].title == "Total balance")
        #expect(rows[0].subline == "Needs to be $0.00. Cashing out isn't available yet.")
        #expect(rows[0].accessibilityValue
            == "3,030.12 US dollars. Needs to be 0.00 US dollars. Cashing out isn't available yet.")
        #expect(rows[2].title == "Forming or active groups")
        #expect(rows[2].subline
            == "Leaving a group isn't available yet. You can delete a group you started before anyone joins.")
        #expect(rows[2].accessibilityValue
            == "20. Leaving a group isn't available yet. You can delete a group you started before anyone joins.")
        #expect(rows[3].title == "Goals")
        for row in rows {
            for text in [row.title, row.subline, row.accessibilityValue, row.value ?? ""] {
                let lower = text.lowercased()
                for banned in ["funds", "withdraw", "release", "circle", "wait for them to finish"] {
                    #expect(!lower.contains(banned), "\(text)")
                }
            }
        }
    }

    private func zeroSummary() throws -> DashboardSummary {
        var object = try Fixture.object("GET_dashboard_summary")
        object["totalCents"] = 0
        object["availableCents"] = 0
        object["goalTotalCents"] = 0
        object["balanceUnavailable"] = false
        return try Fixture.decode(DashboardSummary.self, object: object)
    }
}

@Suite("DeleteAccountInput")
struct DeleteAccountInputTests {
    @Test func encodesConfirmDeleteAndOmitsNilCodes() throws {
        let body = try encodedObject(DeleteAccountInput(proof: StepUpProof(currentPassword: Secret("pw-test"))))
        #expect(body["confirm"] as? String == "DELETE")
        #expect(body["currentPassword"] as? String == "pw-test")
        #expect(body["twoFactorCode"] == nil)
        #expect(body["reauthCode"] == nil)
        #expect(Set(body.keys) == ["confirm", "currentPassword"])
    }

    @Test func carriesTheTwoFactorCodeWhenGiven() throws {
        let proof = StepUpProof(currentPassword: Secret("pw-test"), twoFactorCode: Secret("123456"))
        let body = try encodedObject(DeleteAccountInput(proof: proof))
        #expect(Set(body.keys) == ["confirm", "currentPassword", "twoFactorCode"])
        #expect(body["twoFactorCode"] as? String == "123456")
    }

    /// The code-only variant (an account without a password).
    @Test func codeOnlyOmitsThePassword() throws {
        let body = try encodedObject(DeleteAccountInput(proof: StepUpProof(currentPassword: nil, twoFactorCode: Secret("123456"))))
        #expect(Set(body.keys) == ["confirm", "twoFactorCode"])
    }
}

@Suite("StepUpProof encoding")
struct StepUpProofEncodingTests {
    /// The deactivate body: the password, and the code only with two-factor on.
    @Test func deactivateBody() throws {
        #expect(Set(try encodedObject(StepUpProof(currentPassword: Secret("pw-test"))).keys) == ["currentPassword"])
        let withCode = try encodedObject(StepUpProof(currentPassword: Secret("pw-test"), twoFactorCode: Secret("654321")))
        #expect(Set(withCode.keys) == ["currentPassword", "twoFactorCode"])
        #expect(withCode["currentPassword"] as? String == "pw-test")
        #expect(withCode["twoFactorCode"] as? String == "654321")
    }

    @Test func codeOnlyVariantOmitsCurrentPassword() throws {
        let body = try encodedObject(StepUpProof(currentPassword: nil, twoFactorCode: Secret("654321")))
        #expect(Set(body.keys) == ["twoFactorCode"])
    }

    /// Secrets never print.
    @Test func secretsAreRedactedInDescriptions() {
        let proof = StepUpProof(currentPassword: Secret("pw-test"), twoFactorCode: Secret("654321"))
        #expect(!String(describing: proof).contains("pw-test"))
        #expect(!String(describing: proof).contains("654321"))
    }
}

@Suite("ReferralSource")
struct ReferralSourceTests {
    /// The server's keys exactly, case-sensitive, in its order (AC-22).
    @Test func rawValuesAreTheSevenServerKeys() {
        #expect(ReferralSource.allCases.map(\.rawValue)
            == ["Twitter", "Telegram", "WhatsApp", "Discord", "LinkedIn", "Friends", "Others"])
    }

    @Test func displayNames() {
        #expect(ReferralSource.allCases.map(ReferralSourceNames.displayName)
            == ["X (Twitter)", "Telegram", "WhatsApp", "Discord", "LinkedIn", "Friends or family", "Somewhere else"])
        #expect(ReferralSourceNames.preferNotToSay == "Prefer not to say")
    }

    /// The menu: the seven in the server's order; "Prefer not to say" sends
    /// nothing.
    @Test func choicesAndWhatTheySend() {
        #expect(ReferralChoice.sources.map(\.displayName)
            == ["X (Twitter)", "Telegram", "WhatsApp", "Discord", "LinkedIn", "Friends or family", "Somewhere else"])
        #expect(ReferralChoice.source(.twitter).sentSource?.rawValue == "Twitter")
        #expect(ReferralChoice.source(.friends).sentSource?.rawValue == "Friends")
        #expect(ReferralChoice.source(.others).sentSource?.rawValue == "Others")
        #expect(ReferralChoice.preferNotToSay.displayName == "Prefer not to say")
        #expect(ReferralChoice.preferNotToSay.sentSource == nil)
    }

    /// `RegisterInput` sends the key when chosen, omits it otherwise, and
    /// never has `referralCode` (AC-21, AC-22).
    @Test func registerInputSendsTheKeyOrNothing() throws {
        func body(_ source: String?) throws -> [String: Any] {
            try encodedObject(RegisterInput(
                name: "QA Auth User", username: "qa_user", email: "x1@moolahub.test",
                password: Secret("pw-test"), dateOfBirth: "1990-01-15", referralSource: source
            ))
        }
        let chosen = try body(ReferralChoice.source(.telegram).sentSource?.rawValue)
        #expect(chosen["referralSource"] as? String == "Telegram")
        let declined = try body(ReferralChoice.preferNotToSay.sentSource?.rawValue)
        #expect(declined["referralSource"] == nil)
        let untouched = try body(nil)
        #expect(untouched["referralSource"] == nil)
        for object in [chosen, declined, untouched] {
            #expect(object["referralCode"] == nil)
        }
    }
}

@Suite("SendWarningRule")
struct SendWarningRuleTests {
    private func wallet(address: Any, syncEnabled: Bool) throws -> WalletInfo {
        try Fixture.decode(WalletInfo.self, object: [
            "availableCents": 0, "totalCents": 0, "goalAllocatedCents": 0, "pendingCents": 0,
            "balanceUnavailable": false, "address": address, "network": "test-network",
            "onchainEnabled": false, "hasWallet": true, "faucetEnabled": true, "syncEnabled": syncEnabled,
            "custody": NSNull(), "usdcAddress": NSNull(),
        ])
    }

    /// Copy shows exactly when the warning does (AC-25): the view passes the
    /// address to its row only when `showsSendWarning`, and the row draws Copy
    /// for a non-nil value.
    @Test func copyAndTheWarningGoTogetherForEveryWallet() throws {
        let fixtures: [(Any, Bool, Bool)] = [
            ("0x00000000000000000000000000000000000000aa", false, true),
            ("0x00000000000000000000000000000000000000aa", true, true),
            ("", false, false),
            (NSNull(), false, false),
            (NSNull(), true, false),
        ]
        for (address, sync, expected) in fixtures {
            let info = try wallet(address: address, syncEnabled: sync)
            let showsWarning = SendWarningRule.showsSendWarning(address: info.address)
            let rowValue = showsWarning ? info.address : nil
            let showsCopy = rowValue != nil
            #expect(showsWarning == expected)
            #expect(showsCopy == showsWarning)
        }
    }

    /// The third sentence only while sync is off (AC-24, Q7).
    @Test func notAddedSentenceOnlyWhileSyncIsOff() throws {
        #expect(SendWarningRule.includesNotAddedSentence(syncEnabled: false))
        #expect(!SendWarningRule.includesNotAddedSentence(syncEnabled: true))
        let info = try wallet(address: "0x00000000000000000000000000000000000000aa", syncEnabled: false)
        #expect(SendWarningRule.includesNotAddedSentence(syncEnabled: info.syncEnabled))
    }
}
