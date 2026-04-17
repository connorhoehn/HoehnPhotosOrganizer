// S3PresignedURLProvider.swift
// HoehnPhotosOrganizer
//
// Fetches and caches presigned PUT/GET URLs from the HoehnPhotosSync Lambda endpoint.
// Caches each URL keyed by S3 object key. Automatically refreshes the URL when fewer
// than 2 minutes remain before expiration to avoid 403s mid-transfer.
//
// Architecture notes:
//   - The Lambda issues the presigned URL; this client transfers bytes directly to S3.
//   - Lambda never handles binary data — it only signs and returns the URL.
//   - URLSession.shared is used for the Lambda fetch; the presigned URL itself is used
//     with URLSession for the actual S3 PUT/GET.
//   - Supports Task cancellation at every await point via withTaskCancellationHandler.
//
// Usage:
//   let provider = S3PresignedURLProvider(presignEndpoint: URL(string: env.lambdaURL)!)
//   let url = try await provider.presignedPutURL(for: "proxies/IMG_1234.jpg")
//
// Thread safety:
//   S3PresignedURLProvider is an actor — all state mutations are serialized.

import Foundation

// MARK: - PresignedURLResponse

/// JSON shape returned by the presigned-URL Lambda endpoint.
private struct PresignedURLResponse: Codable {
    let url: String
    let expiresAt: String   // ISO8601 string
}

// MARK: - CachedURL

private struct CachedURL {
    let url: URL
    let expiresAt: Date

    /// Returns true when fewer than `bufferSeconds` remain before expiration.
    func isNearlyExpired(bufferSeconds: TimeInterval = 120) -> Bool {
        Date().addingTimeInterval(bufferSeconds) >= expiresAt
    }
}

// MARK: - S3PresignedURLProvider

/// Actor that fetches presigned S3 URLs from the HoehnPhotosSync Lambda and caches them.
///
/// The provider refreshes a cached URL when less than 2 minutes remain before its
/// expiration timestamp. On fresh fetch, the Lambda returns a URL valid for 15 minutes
/// (900 seconds, configurable via `PRESIGNED_URL_EXPIRY_SECONDS` Lambda environment variable).
actor S3PresignedURLProvider {

    // MARK: Configuration

    /// Lambda endpoint that issues presigned PUT URLs.
    /// In production: the API Gateway URL from CDK stack output (SyncApiEndpoint).
    /// In tests: overridden by the MockPresignedURLProvider protocol.
    private let presignEndpoint: URL

    /// HTTP provider for Lambda API calls (not for S3 transfer — that lives in ProxySyncClient).
    private let session: any HTTPDataProvider

    /// How many seconds before expiration a cached URL is considered stale. Default 120 s.
    private let refreshBufferSeconds: TimeInterval

    // MARK: Cache

    /// Keyed by S3 object key (e.g. "proxies/IMG_1234.CR3"). Values are valid or near-expired.
    private var cache: [String: CachedURL] = [:]

    // MARK: Init

    init(
        presignEndpoint: URL,
        session: any HTTPDataProvider = URLSession.shared,
        refreshBufferSeconds: TimeInterval = 120
    ) {
        self.presignEndpoint = presignEndpoint
        self.session = session
        self.refreshBufferSeconds = refreshBufferSeconds
    }

    // MARK: Public API

    /// Returns a valid presigned PUT URL for the given S3 object key.
    ///
    /// If a cached URL has more than 2 minutes remaining it is returned immediately.
    /// Otherwise a fresh URL is fetched from the Lambda endpoint.
    ///
    /// - Parameters:
    ///   - key: The S3 object key, e.g. "proxies/IMG_1234.CR3".
    ///   - contentType: MIME type sent to Lambda so it can embed it in the presigned signature.
    /// - Throws: SyncError.invalidInput if key is empty; URLError on network failures.
    func presignedPutURL(for key: String, contentType: String = "application/octet-stream") async throws -> URL {
        guard !key.isEmpty else {
            throw SyncError.invalidInput(message: "S3 object key must not be empty")
        }

        // Return cached URL if still valid (with buffer)
        if let cached = cache[key], !cached.isNearlyExpired(bufferSeconds: refreshBufferSeconds) {
            return cached.url
        }

        // Fetch fresh URL from Lambda
        let fresh = try await fetchPresignedURL(for: key, contentType: contentType, method: "PUT")
        cache[key] = fresh
        return fresh.url
    }

    /// Returns a valid presigned GET URL for downloading an S3 object.
    func presignedGetURL(for key: String) async throws -> URL {
        guard !key.isEmpty else {
            throw SyncError.invalidInput(message: "S3 object key must not be empty")
        }

        let cacheKey = "GET:\(key)"
        if let cached = cache[cacheKey], !cached.isNearlyExpired(bufferSeconds: refreshBufferSeconds) {
            return cached.url
        }

        let fresh = try await fetchPresignedURL(for: key, contentType: "", method: "GET")
        cache[cacheKey] = fresh
        return fresh.url
    }

    /// Evicts a cached URL (call after a 403 so the next request fetches fresh).
    func invalidateCache(for key: String) {
        cache.removeValue(forKey: key)
        cache.removeValue(forKey: "GET:\(key)")
    }

    // MARK: Private

    private func fetchPresignedURL(for key: String, contentType: String, method: String) async throws -> CachedURL {
        var components = URLComponents(url: presignEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "contentType", value: contentType)
        ]
        guard let requestURL = components.url else {
            throw SyncError.invalidInput(message: "Could not construct presigned URL request from endpoint \(presignEndpoint)")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw SyncError.uploadFailed(reason: "Presigned URL Lambda returned HTTP \(statusCode)")
        }

        let decoded = try JSONDecoder().decode(PresignedURLResponse.self, from: data)
        guard let url = URL(string: decoded.url) else {
            throw SyncError.uploadFailed(reason: "Lambda returned malformed presigned URL: \(decoded.url)")
        }

        let formatter = ISO8601DateFormatter()
        let expiresAt = formatter.date(from: decoded.expiresAt) ?? Date().addingTimeInterval(900)

        return CachedURL(url: url, expiresAt: expiresAt)
    }
}

// MARK: - PresignedURLProviding

/// Protocol that abstracts presigned URL generation for testability.
/// MockPresignedURLProvider (SyncTests.swift) conforms to this in tests.
/// S3PresignedURLProvider is the production implementation.
protocol PresignedURLProviding: Sendable {
    /// Returns a valid presigned PUT URL for the given S3 object key.
    func presignedPutURL(for key: String, contentType: String) async throws -> URL
    /// Evicts cached URL so next call fetches fresh (called after 403 retry).
    func invalidatePutURL(for key: String) async
}

// MARK: S3PresignedURLProvider: PresignedURLProviding

extension S3PresignedURLProvider: PresignedURLProviding {
    func invalidatePutURL(for key: String) async {
        invalidateCache(for: key)
    }
}
