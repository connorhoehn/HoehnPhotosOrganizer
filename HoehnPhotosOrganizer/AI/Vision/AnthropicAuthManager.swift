import Foundation

// MARK: - AnthropicAuthManager

/// Actor that stores and retrieves the Anthropic API key.
/// Uses UserDefaults instead of Keychain to avoid the keychain access prompt
/// that appears on every build (re-signing invalidates Keychain ACLs).
///
/// For local development this is acceptable. For distribution, switch back
/// to Keychain storage with a stable code-signing identity.
actor AnthropicAuthManager {

    // MARK: - Constants

    private static let defaultsKey = "com.hoehns.photo.anthropic.apikey"

    // MARK: - Public API

    /// Retrieve the stored Anthropic API key.
    /// - Throws: `VisionModelError.noAPIKey` if no key has been stored yet.
    func getAPIKey() throws -> String {
        if let key = UserDefaults.standard.string(forKey: Self.defaultsKey),
           !key.isEmpty {
            return key
        }

        // Fallback: check environment variable
        if let envKey = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"],
           validateAPIKey(envKey) {
            try? setAPIKey(envKey)
            return envKey
        }

        // Fallback: migrate from legacy Keychain storage (one-time)
        if let legacyKey = readLegacyKeychainKey() {
            try? setAPIKey(legacyKey)
            deleteLegacyKeychainKey()
            return legacyKey
        }

        throw VisionModelError.noAPIKey
    }

    /// Store (or replace) the Anthropic API key.
    /// - Parameter key: The API key. Must start with "sk-ant-" and be at least 40 characters.
    /// - Throws: `VisionModelError.providerUnavailable` if validation fails.
    func setAPIKey(_ key: String) throws {
        guard validateAPIKey(key) else {
            throw VisionModelError.providerUnavailable(
                reason: "Invalid Anthropic API key format. Key must start with 'sk-ant-' and be ≥40 characters."
            )
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

    /// Anthropic API key format: starts with "sk-ant-" and is at least 40 characters.
    nonisolated func validateAPIKey(_ key: String) -> Bool {
        key.hasPrefix("sk-ant-") && key.count >= 40
    }

    // MARK: - Legacy Keychain Migration

    private static let legacyKeychainService = "com.hoehns.photo.anthropic.apikey"
    private static let legacyKeychainAccount = "anthropic-api-key"

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
