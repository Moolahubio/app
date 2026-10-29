import Foundation

/// Client-side checks that mirror the server's rules exactly
/// (`artifacts/api-server/src/routes/auth.ts`, `routes/profile.ts`). The server
/// stays the authority; these only let the UI say what's wrong before a round
/// trip.
public enum Validation {
    /// Server `MIN_PASSWORD`.
    public static let minimumPasswordLength = 8

    /// Server `USERNAME_RE` = `^[a-zA-Z0-9_]{3,30}$` (ASCII only). The server
    /// trims and lowercases before checking; pass the trimmed value.
    public static func isValidUsername(_ username: String) -> Bool {
        let scalars = username.unicodeScalars
        guard (3...30).contains(scalars.count) else { return false }
        return scalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122, 95: true
            default: false
            }
        }
    }

    /// Server check `^[^@\s]+@[^@\s]+\.[^@\s]+$` after trimming and
    /// lowercasing.
    public static func isValidEmail(_ email: String) -> Bool {
        let value = normalizedEmail(email)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return false }
        // Exactly one "@" with something before it.
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return false }
        // `[^@\s]+\.[^@\s]+`: some "." with at least one character on each side.
        let domain = Array(parts[1])
        guard domain.count >= 3 else { return false }
        return domain.indices.dropFirst().dropLast().contains { domain[$0] == "." }
    }

    /// What the server stores and compares: trimmed and lowercased.
    public static func normalizedEmail(_ email: String) -> String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Server: `password.length < 8` is rejected. JavaScript counts UTF-16
    /// code units, so this does too.
    public static func isValidPassword(_ password: String) -> Bool {
        password.utf16.count >= minimumPasswordLength
    }

    /// A 6-digit code (email verification, password reset, authenticator).
    public static func isSixDigitCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy(\.isASCIIDigit)
    }
}
