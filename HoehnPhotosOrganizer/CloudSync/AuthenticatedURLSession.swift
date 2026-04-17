// AuthenticatedURLSession.swift
// HoehnPhotosOrganizer
//
// Wrapper around URLSession that automatically injects a valid Cognito access token
// into every request's Authorization header. On 401 responses, forces a token refresh
// and retries once before throwing CognitoAuthError.sessionExpired.
//
// All sync clients (ThreadSyncClient, S3PresignedURLProvider, etc.) accept
// `any HTTPDataProvider` so this can be injected in place of URLSession.

import Foundation

// MARK: - HTTPDataProvider

/// Abstraction over URLSession.data(for:) for testability and auth injection.
protocol HTTPDataProvider: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

// MARK: - URLSession + HTTPDataProvider

extension URLSession: HTTPDataProvider {}

// MARK: - AuthenticatedURLSession

/// An `HTTPDataProvider` that attaches a Cognito Bearer token to every request
/// and retries once on 401 after forcing a token refresh.
final class AuthenticatedURLSession: HTTPDataProvider, @unchecked Sendable {

    private let authManager: CognitoAuthManager
    private let underlying: URLSession

    init(authManager: CognitoAuthManager, underlying: URLSession = .shared) {
        self.authManager = authManager
        self.underlying = underlying
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // First attempt: attach current valid token
        let token = try await authManager.getValidAccessToken()
        var authedRequest = request
        authedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (responseData, response) = try await underlying.data(for: authedRequest)

        // If not 401, return as-is
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 401 else {
            return (responseData, response)
        }

        // 401 — force refresh and retry once
        let freshToken = try await authManager.forceRefresh()
        var retryRequest = request
        retryRequest.setValue("Bearer \(freshToken)", forHTTPHeaderField: "Authorization")

        let (retryData, retryResponse) = try await underlying.data(for: retryRequest)

        // Second 401 — session is dead
        if let retryHttp = retryResponse as? HTTPURLResponse, retryHttp.statusCode == 401 {
            throw CognitoAuthError.sessionExpired
        }

        return (retryData, retryResponse)
    }
}
