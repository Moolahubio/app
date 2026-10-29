import Testing
@testable import Domain

@Suite("GroupWords")
struct GroupWordsTests {
    /// savings-groups §3.3: the count joins the type line of active and
    /// completed groups.
    @Test func typeLineCountsMembersOfActiveAndCompletedGroups() {
        #expect(GroupWords.typeLine(kind: .takeTurns, frequency: .monthly, status: .active, memberCount: 4)
            == "Take turns \u{00B7} Monthly \u{00B7} 4 members")
        #expect(GroupWords.typeLine(kind: .saveTogether, frequency: .biweekly, status: .completed, memberCount: 20)
            == "Save together \u{00B7} Every 2 weeks \u{00B7} 20 members")
    }

    /// Forming groups' footers already count who joined.
    @Test func typeLineOfAFormingGroupHasNoCount() {
        #expect(GroupWords.typeLine(kind: .takeTurns, frequency: .monthly, status: .forming, memberCount: 1)
            == "Take turns \u{00B7} Monthly")
        #expect(GroupWords.typeLine(kind: .saveTogether, frequency: .weekly, status: .other("pending"), memberCount: 2)
            == "Save together \u{00B7} Weekly")
    }

    @Test func typeLineSingularAndMissingFrequency() {
        #expect(GroupWords.typeLine(kind: .saveTogether, frequency: .weekly, status: .active, memberCount: 1)
            == "Save together \u{00B7} Weekly \u{00B7} 1 member")
        #expect(GroupWords.typeLine(kind: .takeTurns, frequency: nil, status: .active, memberCount: 3)
            == "Take turns \u{00B7} 3 members")
        #expect(GroupWords.typeLine(kind: .takeTurns, frequency: nil, status: .forming, memberCount: 3) == "Take turns")
    }

    @Test func memberCount() {
        #expect(GroupWords.memberCount(1) == "1 member")
        #expect(GroupWords.memberCount(4) == "4 members")
        #expect(GroupWords.memberCount(0) == "0 members")
    }

    /// Save together reads `paidOut`, never `state` (W10-SG-13).
    @Test func saveTogetherMembersFromPaidOut() {
        #expect(GroupWords.memberSecondary(kind: .saveTogether, state: .paid, payoutRound: 1, paidOut: false) == "Saving")
        #expect(GroupWords.memberSecondary(kind: .saveTogether, state: .upcoming, payoutRound: 2, paidOut: true) == "Savings returned")
    }

    /// Take turns is unchanged: it reads the payout order.
    @Test func takeTurnsMembersFromThePayoutOrder() {
        #expect(GroupWords.memberSecondary(kind: .takeTurns, state: .paid, payoutRound: 1, paidOut: true) == "Received payout")
        #expect(GroupWords.memberSecondary(kind: .takeTurns, state: .current, payoutRound: 2, paidOut: false) == "Receiving this round")
        #expect(GroupWords.memberSecondary(kind: .takeTurns, state: .upcoming, payoutRound: 4, paidOut: false) == "Payout in round 4")
        #expect(GroupWords.memberSecondary(kind: .takeTurns, state: .other("x"), payoutRound: 3, paidOut: false) == "Payout in round 3")
    }
}

@Suite("PayInStatus")
struct PayInStatusTests {
    @Test func unavailableSaysSo() {
        #expect(PayInStatus.unavailable.accessibilityLabel == "Status unavailable")
    }

    @Test func knownStatusesKeepTheMoveStatusWords() {
        #expect(PayInStatus.known(.done).accessibilityLabel == "Done")
        #expect(PayInStatus.known(.processing).accessibilityLabel == "Processing")
        #expect(PayInStatus.known(.failed).accessibilityLabel == "Didn't go through, nothing was taken")
        #expect(PayInStatus.known(.done) != .unavailable)
    }
}
