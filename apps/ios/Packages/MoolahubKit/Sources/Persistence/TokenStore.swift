import Foundation
import os
import Security

/// Where the session token lives. The live implementation is the Keychain;
/// tests and previews use `InMemoryTokenStore`.
public protocol SessionTokenStore: Sendable {
    func readToken() throws(KeychainError) -> String?
    func saveToken(_ token: String) throws(KeychainError)
    func deleteToken() throws(KeychainError)
}

public struct KeychainError: Error, Hashable, Sendable, CustomStringConvertible {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
    public var description: String { "Keychain error \(status)" }
}

/// Keychain storage for the Moolahub session token: a generic password item
/// readable after the first unlock, never synced to iCloud and never restored
/// to another device (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
public struct KeychainTokenStore: SessionTokenStore {
    public let service: String
    public let account: String

    public init(service: String = "io.moolahub.app.session", account: String = "session-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func readToken() throws(KeychainError) -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
            return token
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError(status: status)
        }
    }

    public func saveToken(_ token: String) throws(KeychainError) {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = baseQuery
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        default:
            throw KeychainError(status: updateStatus)
        }
    }

    public func deleteToken() throws(KeychainError) {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// The accessibility class of the stored item, for tests and diagnostics.
    public func storedAccessibility() -> String? {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any]
        else { return nil }
        return attributes[kSecAttrAccessible as String] as? String
    }
}

/// Token store for tests and SwiftUI previews.
public final class InMemoryTokenStore: SessionTokenStore {
    private let storage: OSAllocatedUnfairLock<String?>

    public init(token: String? = nil) {
        storage = OSAllocatedUnfairLock(initialState: token)
    }

    public func readToken() throws(KeychainError) -> String? {
        storage.withLock { $0 }
    }

    public func saveToken(_ token: String) throws(KeychainError) {
        storage.withLock { $0 = token }
    }

    public func deleteToken() throws(KeychainError) {
        storage.withLock { $0 = nil }
    }
}
