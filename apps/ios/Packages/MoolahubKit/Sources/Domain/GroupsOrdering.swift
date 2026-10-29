import Foundation

/// One ordering for every list of groups, so Home and the Groups tab can never
/// order them differently (W9.2, home.md H5, savings-groups SG-G1).
public enum GroupsOrdering {
    /// Active 0, Forming and any unknown status 1, Completed 2.
    public static func rank(_ status: GroupStatus) -> Int {
        switch status {
        case .active: 0
        case .forming, .other: 1
        case .completed: 2
        }
    }

    /// Active, then Forming (and any unknown status), then Completed; stable
    /// within each (W9.2).
    public static func sorted(_ groups: [CircleSummary]) -> [CircleSummary] {
        groups.enumerated()
            .sorted { lhs, rhs in
                let left = rank(lhs.element.groupStatus)
                let right = rank(rhs.element.groupStatus)
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    /// Home's groups: `sorted` without completed groups. The view takes the
    /// first two. On the server's own order (active first, completed left out)
    /// this changes nothing.
    public static func forHome(_ groups: [CircleSummary]) -> [CircleSummary] {
        sorted(groups).filter { $0.groupStatus != .completed }
    }
}
