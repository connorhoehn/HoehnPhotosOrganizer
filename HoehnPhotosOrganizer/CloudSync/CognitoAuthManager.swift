// CognitoAuthManager.swift
// HoehnPhotosOrganizer
//
// Actor that manages Cognito USER_PASSWORD_AUTH authentication via raw HTTP API.
// Stores tokens in UserDefaults (acceptable for local development; switch to
// Keychain with a stable signing identity for distribution).
//
// Supports:
//   - Sign in with email/password (USER_PASSWORD_AUTH flow)
//   - NEW_PASSWORD_REQUIRED challenge response
//   - Proactive token refresh (60-second buffer before expiry)
//   - REFRESH_TOKEN_AUTH flow for silent re-authentication
//   - Sign out (clears all stored tokens)

import Foundation

// MARK: - CognitoAuthError

enum CognitoAuthError: Error, LocalizedError, Sendable {
    case invalidCredentials
    case newPasswordRequired(session: String)
    case sessionExpired
    case networkError(Error)
    case unknownChallengeType(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password."
        case .newPasswordRequired:
            return "A new password is required. Please set a new password."
        case .sessionExpired:
            return "Your session has expired. Please sign in again."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .unknownChallengeType(let type):
            return "Unknown authentication challenge: \(type)"
        }
    }
}

// MARK: - CognitoAuthManager

/// Actor that authenticates against AWS Cognito User Pools via raw HTTP API
/// and manages token storage/refresh in UserDefaults.
actor CognitoAuthManager {

    // MARK: - Configuration

    /// Default Cognito User Pool configuration. Override per-key via UserDefaults.
    static let defaultRegion = "us-east-1"
    static let defaultUserPoolId = ""
    static let defaultClientId = ""

    private var region: String {
        UserDefaults.standard.string(forKey: "cognito.region") ?? Self.defaultRegion
    }

    private var userPoolId: String {
        UserDefaults.standard.string(forKey: "cognito.userPoolId") ?? Self.defaultUserPoolId
    }

    private var clientId: String {
        UserDefaults.standard.string(forKey: "cognito.clientId") ?? Self.defaultClientId
    }

    private var cognitoEndpoint: URL {
        URL(string: "https://cognito-idp.\(region).amazonaws.com/")!
    }

    // MARK: - UserDefaults Keys

    private enum DefaultsKey {
        static let accessToken = "cognito.accessToken"
        static let refreshToken = "cognito.refreshToken"
        static let idToken = "cognito.idToken"
        static let tokenExpiry = "cognito.tokenExpiry"
        static let userEmail = "cognito.userEmail"
    }

    // MARK: - Dependencies

    private let session: URLSession

    // MARK: - Init

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API

    /// Whether the user has stored tokens (does not validate expiry).
    nonisolated var isSignedIn: Bool {
        UserDefaults.standard.string(forKey: DefaultsKey.accessToken) != nil
    }

    /// Sign in with email and password using USER_PASSWORD_AUTH flow.
    ///
    /// - Throws: `CognitoAuthError.invalidCredentials` on bad credentials,
    ///           `CognitoAuthError.newPasswordRequired` if Cognito demands a password change,
    ///           `CognitoAuthError.networkError` on transport failure.
    func signIn(email: String, password: String) async throws {
        let body: [String: Any] = [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": clientId,
            "AuthParameters": [
                "USERNAME": email,
                "PASSWORD": password
            ]
        ]

        let data = try await cognitoRequest(
            target: "AWSCognitoIdentityProviderService.InitiateAuth",
            body: body
        )

        let json = try jsonObject(from: data)

        // Check for challenge
        if let challengeName = json["ChallengeName"] as? String {
            if challengeName == "NEW_PASSWORD_REQUIRED" {
                let session = json["Session"] as? String ?? ""
                throw CognitoAuthError.newPasswordRequired(session: session)
            } else {
                throw CognitoAuthError.unknownChallengeType(challengeName)
            }
        }

        // Extract tokens from AuthenticationResult
        guard let result = json["AuthenticationResult"] as? [String: Any] else {
            throw CognitoAuthError.invalidCredentials
        }

        try storeTokens(from: result, email: email)
    }

    /// Respond to a NEW_PASSWORD_REQUIRED challenge with a new password.
    ///
    /// - Parameters:
    ///   - session: The session string from the `CognitoAuthError.newPasswordRequired` error.
    ///   - email: The user's email address.
    ///   - newPassword: The new password to set.
    func respondToNewPasswordChallenge(
        session: String,
        email: String,
        newPassword: String
    ) async throws {
        let body: [String: Any] = [
            "ChallengeName": "NEW_PASSWORD_REQUIRED",
            "ClientId": clientId,
            "Session": session,
            "ChallengeResponses": [
                "USERNAME": email,
                "NEW_PASSWORD": newPassword
            ]
        ]

        let data = try await cognitoRequest(
            target: "AWSCognitoIdentityProviderService.RespondToAuthChallenge",
            body: body
        )

        let json = try jsonObject(from: data)

        guard let result = json["AuthenticationResult"] as? [String: Any] else {
            throw CognitoAuthError.invalidCredentials
        }

        try storeTokens(from: result, email: email)
    }

    /// Returns a valid access token, refreshing proactively if within 60 seconds of expiry.
    ///
    /// - Throws: `CognitoAuthError.sessionExpired` if no refresh token is available or refresh fails.
    func getValidAccessToken() async throws -> String {
        guard let accessToken = UserDefaults.standard.string(forKey: DefaultsKey.accessToken),
              let refreshToken = UserDefaults.standard.string(forKey: DefaultsKey.refreshToken) else {
            throw CognitoAuthError.sessionExpired
        }

        let expiry = UserDefaults.standard.double(forKey: DefaultsKey.tokenExpiry)
        let expiryDate = Date(timeIntervalSince1970: expiry)

        // Proactive refresh: 60-second buffer before expiry
        if Date().addingTimeInterval(60) < expiryDate {
            return accessToken
        }

        // Token is expired or near-expired — refresh
        return try await refreshAccessToken(refreshToken: refreshToken)
    }

    /// Force-refresh the access token using the stored refresh token.
    ///
    /// - Returns: The new access token.
    /// - Throws: `CognitoAuthError.sessionExpired` if refresh fails.
    @discardableResult
    func forceRefresh() async throws -> String {
        guard let refreshToken = UserDefaults.standard.string(forKey: DefaultsKey.refreshToken) else {
            throw CognitoAuthError.sessionExpired
        }
        return try await refreshAccessToken(refreshToken: refreshToken)
    }

    /// Clear all stored tokens and sign out.
    func signOut() {
        UserDefaults.standard.removeObject(forKey: DefaultsKey.accessToken)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.refreshToken)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.idToken)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.tokenExpiry)
        UserDefaults.standard.removeObject(forKey: DefaultsKey.userEmail)
    }

    // MARK: - Private: Token Refresh

    private func refreshAccessToken(refreshToken: String) async throws -> String {
        let body: [String: Any] = [
            "AuthFlow": "REFRESH_TOKEN_AUTH",
            "ClientId": clientId,
            "AuthParameters": [
                "REFRESH_TOKEN": refreshToken
            ]
        ]

        let data: Data
        do {
            data = try await cognitoRequest(
                target: "AWSCognitoIdentityProviderService.InitiateAuth",
                body: body
            )
        } catch {
            // Refresh failed — session is dead
            signOut()
            throw CognitoAuthError.sessionExpired
        }

        let json = try jsonObject(from: data)

        guard let result = json["AuthenticationResult"] as? [String: Any],
              let newAccessToken = result["AccessToken"] as? String else {
            signOut()
            throw CognitoAuthError.sessionExpired
        }

        // Refresh responses do not include a new RefreshToken — keep the existing one
        UserDefaults.standard.set(newAccessToken, forKey: DefaultsKey.accessToken)

        if let idToken = result["IdToken"] as? String {
            UserDefaults.standard.set(idToken, forKey: DefaultsKey.idToken)
        }

        if let expiresIn = result["ExpiresIn"] as? Int {
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970
            UserDefaults.standard.set(expiry, forKey: DefaultsKey.tokenExpiry)
        }

        return newAccessToken
    }

    // MARK: - Private: Token Storage

    private func storeTokens(from result: [String: Any], email: String) throws {
        guard let accessToken = result["AccessToken"] as? String,
              let refreshToken = result["RefreshToken"] as? String,
              let idToken = result["IdToken"] as? String else {
            throw CognitoAuthError.invalidCredentials
        }

        UserDefaults.standard.set(accessToken, forKey: DefaultsKey.accessToken)
        UserDefaults.standard.set(refreshToken, forKey: DefaultsKey.refreshToken)
        UserDefaults.standard.set(idToken, forKey: DefaultsKey.idToken)
        UserDefaults.standard.set(email, forKey: DefaultsKey.userEmail)

        if let expiresIn = result["ExpiresIn"] as? Int {
            let expiry = Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970
            UserDefaults.standard.set(expiry, forKey: DefaultsKey.tokenExpiry)
        }
    }

    // MARK: - Private: HTTP

    private func cognitoRequest(target: String, body: [String: Any]) async throws -> Data {
        var request = URLRequest(url: cognitoEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 30

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            throw CognitoAuthError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CognitoAuthError.networkError(URLError(.badServerResponse))
        }

        // Cognito returns 400 for invalid credentials, 200 for success/challenges
        if httpResponse.statusCode == 400 {
            // Parse Cognito error type
            if let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
               let type = json["__type"] as? String {
                if type.contains("NotAuthorizedException") || type.contains("UserNotFoundException") {
                    throw CognitoAuthError.invalidCredentials
                }
            }
            throw CognitoAuthError.invalidCredentials
        }

        guard httpResponse.statusCode == 200 else {
            throw CognitoAuthError.networkError(URLError(.badServerResponse))
        }

        return responseData
    }

    private func jsonObject(from data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CognitoAuthError.networkError(URLError(.cannotParseResponse))
        }
        return json
    }
}
