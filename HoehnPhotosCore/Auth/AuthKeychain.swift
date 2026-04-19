import Foundation
import Security

/// Errors thrown by ``AuthKeychain`` write operations.
public enum AuthKeychainError: Error {
    /// The string could not be encoded as UTF-8 data.
    case encodingFailed
    /// The underlying Security framework returned a non-success status on add.
    case unhandled(OSStatus)
}

/// Keychain wrapper for Cognito auth artifacts.
///
/// Stores three strings (`idToken`, `refreshToken`, `username`) under the
/// shared service identifier ``AuthKeychain/service``. Items use
/// `kSecAttrAccessibleAfterFirstUnlock` so they remain available after the
/// device has been unlocked once following a reboot.
public enum AuthKeychain {
    private static let service = "com.hoehn-photos.auth"

    private enum Account {
        static let idToken = "idToken"
        static let refreshToken = "refreshToken"
        static let username = "username"
    }

    // MARK: - Public API

    /// Persist all three auth values. Overwrites any existing entries.
    public static func save(idToken: String, refreshToken: String, username: String) throws {
        try set(idToken, account: Account.idToken)
        try set(refreshToken, account: Account.refreshToken)
        try set(username, account: Account.username)
    }

    public static func loadIdToken() -> String? {
        get(account: Account.idToken)
    }

    public static func loadRefreshToken() -> String? {
        get(account: Account.refreshToken)
    }

    public static func loadUsername() -> String? {
        get(account: Account.username)
    }

    /// Remove all three auth values. Missing items are ignored.
    public static func clear() {
        delete(account: Account.idToken)
        delete(account: Account.refreshToken)
        delete(account: Account.username)
    }

    // MARK: - Private helpers

    private static func set(_ value: String, account: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw AuthKeychainError.encodingFailed
        }

        // Delete first to avoid errSecDuplicateItem on re-save.
        delete(account: account)

        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthKeychainError.unhandled(status)
        }
    }

    private static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Swallow errors — a missing item (errSecItemNotFound) is expected.
        SecItemDelete(query as CFDictionary)
    }
}
