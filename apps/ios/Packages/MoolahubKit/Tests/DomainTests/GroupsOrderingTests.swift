import Foundation
import Testing
@testable import Domain

/// A group from the dashboard fixture's first circle, renamed and with
/// another status.
private func group(_ name: String, _ status: String) throws -> CircleSummary {
    let dashboard = try Fixture.object("GET_dashboard_summary")
    let circles = try #require(dashboard["activeCircles"] as? [[String: Any]])
    var object = try #require(circles.first)
    object["id"] = name
    object["name"] = name
    object["status"] = status
    return try Fixture.decode(CircleSummary.self, object: object)
}

@Suite("GroupsOrdering")
struct GroupsOrderingTests {
    @Test func ranks() {
        #expect(GroupsOrdering.rank(.active) == 0)
        #expect(GroupsOrdering.rank(.forming) == 1)
        #expect(GroupsOrdering.rank(.other("paused")) == 1)
        #expect(GroupsOrdering.rank(.completed) == 2)
    }

    /// Active, then Forming and any unknown status, then Completed (W9.2).
    @Test func activeThenFormingThenCompleted() throws {
        let groups = [
            try group("done", "completed"), try group("new", "forming"),
            try group("running", "active"), try group("odd", "paused"),
        ]
        #expect(GroupsOrdering.sorted(groups).map(\.name) == ["running", "new", "odd", "done"])
    }

    /// Stable within each status: the server's order is kept.
    @Test func stableWithinAStatus() throws {
        let groups = [
            try group("a1", "active"), try group("f1", "forming"), try group("a2", "active"),
            try group("c1", "completed"), try group("f2", "forming"), try group("a3", "active"),
        ]
        #expect(GroupsOrdering.sorted(groups).map(\.name) == ["a1", "a2", "a3", "f1", "f2", "c1"])
        #expect(GroupsOrdering.sorted([]).isEmpty)
    }

    @Test func forHomeDropsCompletedGroups() throws {
        let groups = [
            try group("c1", "completed"), try group("f1", "forming"),
            try group("a1", "active"), try group("c2", "completed"),
        ]
        #expect(GroupsOrdering.forHome(groups).map(\.name) == ["a1", "f1"])
        #expect(GroupsOrdering.forHome([try group("c1", "completed")]).isEmpty)
    }

    /// On the server's own order (active first, completed left out) the rule
    /// changes nothing.
    @Test func forHomeKeepsTheServersOrder() throws {
        let summary = try Fixture.decode(DashboardSummary.self, "GET_dashboard_summary")
        #expect(GroupsOrdering.forHome(summary.activeCircles) == summary.activeCircles)
    }
}
