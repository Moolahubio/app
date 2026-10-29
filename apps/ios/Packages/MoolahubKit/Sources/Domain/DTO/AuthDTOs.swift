import Foundation

// Mirrors lib/api-spec/openapi.yaml (components/schemas). Field names match the
// API exactly. Optional where the spec says optional or nullable, or where the
// route is known not to send the field, so decoding never fails on a missing
// optional value.

/// `GET /healthz`
public struct HealthStatus: Codable, Hashable, Sendable {
    public let status: String
}

/// `{ "ok": true }`
public struct OkResponse: Codable, Hashable, Sendable {
    public let ok: Bool
}

/// The API error envelope `{ "error": "<message>" }`.
public struct APIErrorBody: Codable, Hashable, Sendable {
    public let error: String
}

/// `AuthUser` (`GET /auth/me`).
public struct AuthUser: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let email: String
    public let username: String?
    public let avatarUrl: String?
    public let hasWallet: Bool?
    public let walletAddress: String?
    public let hasPassword: Bool?
    public let privyLinked: Bool?
    public let emailVerified: Bool?
    public let language: String?

    public init(
        id: String, name: String, email: String, username: String? = nil, avatarUrl: String? = nil,
        hasWallet: Bool? = nil, walletAddress: String? = nil, hasPassword: Bool? = nil,
        privyLinked: Bool? = nil, emailVerified: Bool? = nil, language: String? = nil
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.username = username
        self.avatarUrl = avatarUrl
        self.hasWallet = hasWallet
        self.walletAddress = walletAddress
        self.hasPassword = hasPassword
        self.privyLinked = privyLinked
        self.emailVerified = emailVerified
        self.language = language
    }

    /// `name` up to the first space; empty when there is no name.
    public var firstName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
    }
}

/// `LoginResult`: returned by `/auth/login` and `/auth/verify-email`.
/// Exactly one of: a 2FA challenge, "verify your email", or a signed-in user
/// (with `sessionToken` for native clients).
public struct LoginResult: Decodable, Sendable {
    public let twoFactorRequired: Bool
    public let challengeId: String?
    public let emailVerificationRequired: Bool?
    public let id: String?
    public let name: String?
    public let email: String?
    public let username: String?
    public let avatarUrl: String?
    public let hasWallet: Bool?
    public let walletAddress: String?
    public let hasPassword: Bool?
    public let privyLinked: Bool?
    public let sessionToken: SessionToken?

    /// The signed-in user, when the response carries one.
    public var user: AuthUser? {
        guard let id, let name, let email else { return nil }
        return AuthUser(
            id: id, name: name, email: email, username: username, avatarUrl: avatarUrl,
            hasWallet: hasWallet, walletAddress: walletAddress, hasPassword: hasPassword,
            privyLinked: privyLinked
        )
    }
}

/// `TwoFactorLoginResult` (`/auth/2fa/login`): an `AuthUser` plus
/// `sessionToken` for native clients.
public struct TwoFactorLoginResult: Decodable, Sendable {
    public let user: AuthUser
    public let sessionToken: SessionToken?

    private enum CodingKeys: String, CodingKey { case sessionToken }

    public init(from decoder: any Decoder) throws {
        user = try AuthUser(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionToken = try container.decodeIfPresent(SessionToken.self, forKey: .sessionToken)
    }
}

/// `EmailVerificationRequired` (`/auth/register`).
public struct EmailVerificationRequired: Codable, Hashable, Sendable {
    public let emailVerificationRequired: Bool
    public let email: String
}

/// `UsernameAvailability` (`/auth/username-available`).
public struct UsernameAvailability: Codable, Hashable, Sendable {
    public let available: Bool
    public let reason: String?
}

/// `TwoFactorStatus` (`GET /security/2fa`).
public struct TwoFactorStatus: Codable, Hashable, Sendable {
    public let enabled: Bool
    public let backupCodesRemaining: Int
}

// MARK: - Auth inputs

/// "How did you hear about MoolaHub?" (`RegisterInput.referralSource`). Raw
/// values are the server's keys exactly (case-sensitive); any other value is a
/// 400. Display names live in Domain's `ReferralSourceNames`.
public enum ReferralSource: String, CaseIterable, Hashable, Sendable {
    case twitter = "Twitter"
    case telegram = "Telegram"
    case whatsApp = "WhatsApp"
    case discord = "Discord"
    case linkedIn = "LinkedIn"
    case friends = "Friends"
    case others = "Others"
}

/// `RegisterInput`. `dateOfBirth` is `yyyy-MM-dd` and required by the server.
/// `referralSource` is a `ReferralSource` raw value, left out of the body when
/// nil; `referralCode` is never sent.
public struct RegisterInput: Encodable, Sendable {
    public var name: String
    public var username: String
    public var email: String
    public var password: Secret
    public var dateOfBirth: String
    public var rememberMe: Bool
    public var referralSource: String?

    public init(
        name: String, username: String, email: String, password: Secret, dateOfBirth: String,
        rememberMe: Bool = true, referralSource: String? = nil
    ) {
        self.name = name
        self.username = username
        self.email = email
        self.password = password
        self.dateOfBirth = dateOfBirth
        self.rememberMe = rememberMe
        self.referralSource = referralSource
    }
}

/// `LoginInput`.
public struct LoginInput: Encodable, Sendable {
    public var email: String
    public var password: Secret
    public var rememberMe: Bool

    public init(email: String, password: Secret, rememberMe: Bool = true) {
        self.email = email
        self.password = password
        self.rememberMe = rememberMe
    }
}

/// `VerifyEmailInput`.
public struct VerifyEmailInput: Encodable, Sendable {
    public var email: String
    public var code: Secret
    public var rememberMe: Bool

    public init(email: String, code: Secret, rememberMe: Bool = true) {
        self.email = email
        self.code = code
        self.rememberMe = rememberMe
    }
}

/// `ResendCodeInput` and `ForgotPasswordInput`.
public struct EmailInput: Encodable, Sendable {
    public var email: String
    public init(email: String) { self.email = email }
}

/// `ResetPasswordInput`.
public struct ResetPasswordInput: Encodable, Sendable {
    public var email: String
    public var code: Secret
    public var newPassword: Secret

    public init(email: String, code: Secret, newPassword: Secret) {
        self.email = email
        self.code = code
        self.newPassword = newPassword
    }
}

/// `TwoFactorLoginInput`. `code` is a 6-digit TOTP code or a backup code.
public struct TwoFactorLoginInput: Encodable, Sendable {
    public var challengeId: String
    public var code: Secret

    public init(challengeId: String, code: Secret) {
        self.challengeId = challengeId
        self.code = code
    }
}

/// `ChangePasswordInput`. `twoFactorCode` is required when 2FA is on.
public struct ChangePasswordInput: Encodable, Sendable {
    public var currentPassword: Secret?
    public var twoFactorCode: Secret?
    public var newPassword: Secret

    public init(currentPassword: Secret?, twoFactorCode: Secret?, newPassword: Secret) {
        self.currentPassword = currentPassword
        self.twoFactorCode = twoFactorCode
        self.newPassword = newPassword
    }
}

/// `StepUpProofInput`: fresh proof for sensitive actions (goal delete, …).
/// Never store these values; clear the fields after the request.
public struct StepUpProof: Encodable, Sendable {
    public var currentPassword: Secret?
    public var twoFactorCode: Secret?

    public init(currentPassword: Secret?, twoFactorCode: Secret? = nil) {
        self.currentPassword = currentPassword
        self.twoFactorCode = twoFactorCode
    }
}

/// `DeleteAccountInput` (`DELETE /account`): `confirm` is always `"DELETE"`
/// (iOS sends it itself; the dialog and the step-up are the confirmation).
/// Nil fields are left out of the body; `reauthCode` is never sent. Never
/// store these values; clear the fields after the request.
public struct DeleteAccountInput: Encodable, Sendable {
    public var confirm: String
    public var currentPassword: Secret?
    public var twoFactorCode: Secret?

    public init(proof: StepUpProof) {
        self.confirm = "DELETE"
        self.currentPassword = proof.currentPassword
        self.twoFactorCode = proof.twoFactorCode
    }
}

/// An empty JSON object `{}`: the body of a mutation that takes none.
public struct EmptyBody: Encodable, Sendable {
    public init() {}
}
