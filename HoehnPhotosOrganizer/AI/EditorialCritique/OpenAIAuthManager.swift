import Foundation
import Security

// MARK: - AuthError

enum AuthError: LocalizedError {
    case noAPIKey
    case invalidKeyFormat

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No OpenAI API key configured. Go to Settings > Cloud AI to add one."
        case .invalidKeyFormat:
            return "Invalid API key format. Key must start with 'sk-' and be at least 56 characters."
        }
    }
}

// MARK: - OpenAIAuthManager

/// Actor that stores and retrieves the OpenAI API key.
/// Uses UserDefaults instead of Keychain to avoid the keychain access prompt
/// that appears on every build (re-signing invalidates Keychain ACLs).
actor OpenAIAuthManager {

    // MARK: - Constants

    private static let defaultsKey = "com.hoehns.photo.openai.apikey"

    // MARK: - Public API

    /// Retrieve the stored API key.
    /// - Throws: `AuthError.noAPIKey` if no key has been stored yet.
    func getAPIKey() throws -> String {
        if let key = UserDefaults.standard.string(forKey: Self.defaultsKey),
           !key.isEmpty {
            return key
        }

        // Fallback: migrate from legacy Keychain storage (one-time)
        if let legacyKey = readLegacyKeychainKey() {
            try? setAPIKey(legacyKey)
            deleteLegacyKeychainKey()
            return legacyKey
        }

        throw AuthError.noAPIKey
    }

    /// Store (or replace) the API key.
    /// - Parameter key: The OpenAI API key to store. Must pass `validateAPIKey` check.
    /// - Throws: `AuthError.invalidKeyFormat` if key doesn't meet format requirements.
    func setAPIKey(_ key: String) throws {
        guard validateAPIKey(key) else {
            throw AuthError.invalidKeyFormat
        }
        UserDefaults.standard.set(key, forKey: Self.defaultsKey)
    }

    /// Remove the API key.
    func removeAPIKey() throws {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    /// Check whether an API key has been stored, without returning it.
    func isConfigured() -> Bool {
        (try? getAPIKey()) != nil
    }

    // MARK: - Validation

    /// Basic format check: must start with "sk-" and be at least 56 characters.
    nonisolated func validateAPIKey(_ key: String) -> Bool {
        key.hasPrefix("sk-") && key.count >= 56
    }

    // MARK: - Legacy Keychain Migration

    private static let legacyKeychainService = "com.hoehns.photo.openai.apikey"
    private static let legacyKeychainAccount = "openai-api-key"

    private func readLegacyKeychainKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: Self.legacyKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess,
           let data = result as? Data,
           let key = String(data: data, encoding: .utf8),
           !key.isEmpty {
            return key
        }
        return nil
    }

    private func deleteLegacyKeychainKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.legacyKeychainService,
            kSecAttrAccount as String: Self.legacyKeychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
