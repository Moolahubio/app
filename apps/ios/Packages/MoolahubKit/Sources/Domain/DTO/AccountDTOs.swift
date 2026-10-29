import Foundation

// MARK: - Profile

/// `UserProfile` (`GET /profile`, `PATCH /profile`). The current route does not
/// send `emailVerified`/`hasPassword`/`privyLinked`; use `AuthUser` for those.
public struct UserProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let email: String
    public let username: String?
    /// `yyyy-MM-dd`. Parse with `APIDate.parseDay`, show with `APIDate.formatUTCDay`.
    public let dateOfBirth: String?
    public let nationality: String?
    public let avatarUrl: String?
    /// Technical details only.
    public let walletAddress: String?
    public let referralSource: String?
    public let emailVerified: Bool?
    public let hasPassword: Bool?
    public let privyLinked: Bool?
    public let createdAt: Date
    public let language: String?
    /// IANA time zone the server counts streak periods in (absent on a server
    /// before C3).
    public let timezone: String?
}

/// `ProfileUpdate` (`PATCH /profile`). Nil fields are left out of the body.
/// `timezone` is sent only by Auth's `TimeZoneSync`, alone
/// (`{"timezone":"Africa/Accra"}`); Profile's Save never sets it.
public struct ProfileUpdate: Encodable, Sendable {
    public var name: String?
    public var username: String?
    public var timezone: String?

    public init(name: String? = nil, username: String? = nil, timezone: String? = nil) {
        self.name = name
        self.username = username
        self.timezone = timezone
    }
}

// MARK: - Notifications

/// `Notification` (named `NotificationItem` to avoid Foundation's `Notification`).
public struct NotificationItem: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let title: String
    public let body: String
    public let link: String?
    public let read: Bool
    public let createdAt: Date
}

/// `NotificationsResponse` (`GET /notifications`).
public struct NotificationsResponse: Codable, Hashable, Sendable {
    public let notifications: [NotificationItem]
    public let unreadCount: Int
}

/// `NotificationCategories`. UI names: Money = `money`, Groups = `social`,
/// Tips = `engagement`.
public struct NotificationCategories: Codable, Hashable, Sendable {
    public var money: Bool
    public var social: Bool
    public var engagement: Bool

    public init(money: Bool, social: Bool, engagement: Bool) {
        self.money = money
        self.social = social
        self.engagement = engagement
    }
}

/// `NotificationPreferences` (`GET`/`PATCH /notifications/preferences`).
public struct NotificationPreferences: Codable, Hashable, Sendable {
    public var preference: String
    public var categories: NotificationCategories

    public var level: NotificationPreferenceLevel? { NotificationPreferenceLevel(rawValue: preference) }
}

/// `NotificationPreferencesUpdate`.
public struct NotificationPreferencesUpdate: Encodable, Sendable {
    public var preference: String
    public var categories: NotificationCategories?

    public init(level: NotificationPreferenceLevel, categories: NotificationCategories? = nil) {
        self.preference = level.rawValue
        self.categories = categories
    }
}

// MARK: - Learn (FeatureLearn, Home)

/// `LessonSummary` (`GET /learn/lessons`). Learn (FeatureLearn, Home), through
/// `LearnCatalog`. `emoji` is decoded and never drawn.
public struct LessonSummary: Codable, Hashable, Sendable, Identifiable {
    public let slug: String
    public let title: String
    public let summary: String
    public let minutes: Int
    public let level: String
    public let category: String
    public let emoji: String
    public let completed: Bool

    public var id: String { slug }
}

/// `LessonBody`.
public struct LessonBody: Codable, Hashable, Sendable {
    public let heading: String
    public let text: String
}

/// `LessonDetail` (`GET /learn/lessons/{slug}`).
public struct LessonDetail: Codable, Hashable, Sendable, Identifiable {
    public let slug: String
    public let title: String
    public let summary: String
    public let minutes: Int
    public let level: String
    public let category: String
    public let emoji: String
    public let completed: Bool
    public let body: [LessonBody]
    public let takeaways: [String]

    public var id: String { slug }
}
