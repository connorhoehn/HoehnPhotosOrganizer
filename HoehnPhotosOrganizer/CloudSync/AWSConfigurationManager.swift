// AWSConfigurationManager.swift
// HoehnPhotosOrganizer
//
// Centralized AWS configuration for the cloud sync stack.
// Reads from UserDefaults (set during onboarding or from the Settings pane).
// Provides a single source of truth for API endpoint, Cognito credentials,
// S3 bucket, and region — consumed by all sync clients.
//
// UserDefaults keys (match deploy.sh outputs.json shape):
//   syncAPIEndpoint       — API Gateway endpoint URL (e.g. "https://xyz.execute-api.us-east-1.amazonaws.com/prod")
//   cognito.userPoolId    — Cognito User Pool ID (e.g. "us-east-1_AbCdEf")
//   cognito.clientId      — Cognito App Client ID
//   cognito.region        — AWS region (default "us-east-1")
//   syncS3Bucket          — S3 bucket name for proxy/curve uploads
//   syncEnabled           — Master toggle (Bool)
//
// Configuration can also be imported from a JSON file matching deploy.sh output format.

import Foundation

// MARK: - AWSConfiguration

/// Immutable snapshot of AWS configuration values.
/// Passed to sync clients at initialization time.
struct AWSConfiguration: Sendable {
    let apiEndpoint: String
    let userPoolId: String
    let clientId: String
    let region: String
    let s3BucketName: String

    /// Whether the configuration has all required fields populated.
    var isComplete: Bool {
        !apiEndpoint.isEmpty && !userPoolId.isEmpty && !clientId.isEmpty && !s3BucketName.isEmpty
    }
}

// MARK: - AWSConfigurationManager

/// Reads and writes AWS sync configuration to UserDefaults.
/// Thread-safe: all reads go through UserDefaults (atomic for scalar types).
final class AWSConfigurationManager: Sendable {

    // MARK: - UserDefaults Keys

    private enum Key {
        static let apiEndpoint = "syncAPIEndpoint"
        static let userPoolId = "cognito.userPoolId"
        static let clientId = "cognito.clientId"
        static let region = "cognito.region"
        static let s3BucketName = "syncS3Bucket"
        static let syncEnabled = "syncEnabled"
    }

    // MARK: - Singleton

    static let shared = AWSConfigurationManager()

    // MARK: - Read Configuration

    /// Returns the current AWS configuration snapshot from UserDefaults.
    var current: AWSConfiguration {
        AWSConfiguration(
            apiEndpoint: UserDefaults.standard.string(forKey: Key.apiEndpoint) ?? "",
            userPoolId: UserDefaults.standard.string(forKey: Key.userPoolId) ?? "",
            clientId: UserDefaults.standard.string(forKey: Key.clientId) ?? "",
            region: UserDefaults.standard.string(forKey: Key.region) ?? "us-east-1",
            s3BucketName: UserDefaults.standard.string(forKey: Key.s3BucketName) ?? ""
        )
    }

    /// Whether cloud sync is enabled by the user AND configuration is complete.
    var isSyncReady: Bool {
        UserDefaults.standard.bool(forKey: Key.syncEnabled) && current.isComplete
    }

    /// Whether the user has toggled sync on (configuration may still be incomplete).
    var isSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: Key.syncEnabled)
    }

    // MARK: - Write Configuration

    /// Store individual configuration values.
    func setAPIEndpoint(_ value: String) {
        UserDefaults.standard.set(value, forKey: Key.apiEndpoint)
    }

    func setUserPoolId(_ value: String) {
        UserDefaults.standard.set(value, forKey: Key.userPoolId)
    }

    func setClientId(_ value: String) {
        UserDefaults.standard.set(value, forKey: Key.clientId)
    }

    func setRegion(_ value: String) {
        UserDefaults.standard.set(value, forKey: Key.region)
    }

    func setS3BucketName(_ value: String) {
        UserDefaults.standard.set(value, forKey: Key.s3BucketName)
    }

    func setSyncEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Key.syncEnabled)
    }

    // MARK: - Bulk Import from deploy.sh Output

    /// Imports configuration from a JSON file matching the deploy.sh outputs.json format:
    /// ```json
    /// {
    ///   "HoehnPhotosSync": {
    ///     "SyncApiEndpoint": "https://...",
    ///     "UserPoolId": "us-east-1_...",
    ///     "UserPoolClientId": "...",
    ///     "PhotoSyncBucketName": "..."
    ///   }
    /// }
    /// ```
    /// - Parameter url: File URL to the outputs.json file.
    /// - Throws: If the file cannot be read or parsed.
    func importFromDeployOutput(url: URL) throws {
        let data = try Data(contentsOf: url)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Navigate into the stack output key
        let stackOutputs: [String: Any]
        if let nested = json?["HoehnPhotosSync"] as? [String: Any] {
            stackOutputs = nested
        } else {
            // Flat format (keys at top level)
            stackOutputs = json ?? [:]
        }

        if let endpoint = stackOutputs["SyncApiEndpoint"] as? String {
            setAPIEndpoint(endpoint)
        }
        if let poolId = stackOutputs["UserPoolId"] as? String {
            setUserPoolId(poolId)
        }
        if let clientId = stackOutputs["UserPoolClientId"] as? String {
            setClientId(clientId)
        }
        if let bucket = stackOutputs["PhotoSyncBucketName"] as? String {
            setS3BucketName(bucket)
        }

        // Derive region from User Pool ID (format: us-east-1_AbCdEf)
        if let poolId = stackOutputs["UserPoolId"] as? String,
           let regionPart = poolId.split(separator: "_").first {
            setRegion(String(regionPart))
        }
    }

    /// Imports configuration from a paste-friendly string (one key=value per line).
    /// Accepts the format printed by deploy.sh:
    /// ```
    /// API Endpoint:    https://...
    /// User Pool ID:    us-east-1_...
    /// Client ID:       ...
    /// S3 Bucket:       ...
    /// ```
    func importFromDeployText(_ text: String) {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let value = extractValue(from: trimmed, prefix: "API Endpoint:") {
                setAPIEndpoint(value)
            } else if let value = extractValue(from: trimmed, prefix: "User Pool ID:") {
                setUserPoolId(value)
                if let regionPart = value.split(separator: "_").first {
                    setRegion(String(regionPart))
                }
            } else if let value = extractValue(from: trimmed, prefix: "Client ID:") {
                setClientId(value)
            } else if let value = extractValue(from: trimmed, prefix: "S3 Bucket:") {
                setS3BucketName(value)
            }
        }
    }

    // MARK: - Clear

    /// Removes all AWS configuration from UserDefaults.
    func clearAll() {
        UserDefaults.standard.removeObject(forKey: Key.apiEndpoint)
        UserDefaults.standard.removeObject(forKey: Key.userPoolId)
        UserDefaults.standard.removeObject(forKey: Key.clientId)
        UserDefaults.standard.removeObject(forKey: Key.region)
        UserDefaults.standard.removeObject(forKey: Key.s3BucketName)
    }

    // MARK: - Private

    private func extractValue(from line: String, prefix: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }
}
