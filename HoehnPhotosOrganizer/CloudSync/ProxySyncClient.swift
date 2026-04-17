// ProxySyncClient.swift
// HoehnPhotosOrganizer
//
// Uploads proxy JPEG images to S3 via presigned PUT URLs.
// Handles URL expiration (403 response) by fetching a fresh presigned URL and retrying.
// Handles network timeouts with up to `maxRetries` total attempts.
//
// Architecture notes:
//   - Does NOT hold a reference to AppDatabase. Callers update sync_status after upload.
//   - The `onProgress` callback is called synchronously in the upload completion — it is
//     always called at least once with 1.0 (100%) on successful upload and with the
//     partial value on final failure.
//   - Content-Type is always "image/jpeg" for proxy assets.
//   - Retry ceiling: 3 total attempts (initial + 2 retries). Each 403 fetches a fresh URL.
//     Each timeout or network error retries with the same URL (fresh URL not needed).
//
// Usage:
//   let client = ProxySyncClient(s3Client: mockS3, urlProvider: mockURLProvider)
//   try await client.uploadProxy(data: proxyData, canonicalId: canonicalId, bucketName: bucket)

import Foundation

// MARK: - S3Uploading Protocol

/// Protocol that abstracts S3 PUT operations for testability.
/// MockS3Client (SyncTests.swift) conforms to this in tests.
/// Production callers use URLSession directly via the presigned URL pattern.
protocol S3Uploading: Sendable {
    /// Performs an S3 PUT via presigned URL.
    /// - Returns: HTTP status code (200 on success, 403 on expired URL, etc.)
    /// - Throws: URLError for network-level failures (timeout, no connection, etc.)
    func put(
        bucket: String,
        key: String,
        data: Data,
        contentType: String,
        metadata: [String: String]
    ) async throws -> Int
}

// MARK: - ProxySyncClient

/// Uploads proxy images to S3 with presigned URL retry logic.
///
/// Retry policy:
///   - 403 (URL expired): fetch fresh presigned URL, retry upload.
///   - URLError.timedOut: retry with existing URL.
///   - Other errors: throw immediately (not retryable).
///   - Maximum 3 total attempts (configurable via `maxRetries`).
struct ProxySyncClient: Sendable {

    // MARK: Dependencies (injected for testability)

    private let s3Client: any S3Uploading
    private let urlProvider: any PresignedURLProviding

    // MARK: Configuration

    /// Total number of upload attempts (initial + retries). Default 3.
    private let maxRetries: Int

    /// Content-Type for all proxy JPEG uploads.
    private let contentType = "image/jpeg"

    // MARK: Init

    init(
        s3Client: any S3Uploading,
        urlProvider: any PresignedURLProviding,
        maxRetries: Int = 3
    ) {
        self.s3Client = s3Client
        self.urlProvider = urlProvider
        self.maxRetries = maxRetries
    }

    // MARK: Public API

    /// Uploads a proxy JPEG to S3 at key `proxies/{canonicalId}`.
    ///
    /// - Parameters:
    ///   - data: JPEG proxy image data. Must not be empty.
    ///   - canonicalId: Camera-assigned filename (e.g. "IMG_1234.CR3"). Used as S3 key suffix.
    ///   - bucketName: Target S3 bucket name.
    ///   - onProgress: Optional callback receiving upload progress (0.0–1.0).
    ///                 Called at least once with 1.0 on success.
    /// - Throws: SyncError.invalidInput for empty inputs.
    ///           SyncError.maxRetriesExceeded if all attempts are exhausted.
    ///           SyncError.uploadFailed for non-retryable HTTP errors.
    func uploadProxy(
        data: Data,
        canonicalId: String,
        bucketName: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws {
        guard !data.isEmpty else {
            throw SyncError.invalidInput(message: "Proxy data must not be empty")
        }
        guard !canonicalId.isEmpty else {
            throw SyncError.invalidInput(message: "canonicalId must not be empty")
        }
        guard !bucketName.isEmpty else {
            throw SyncError.invalidInput(message: "bucketName must not be empty")
        }

        let key = "proxies/\(canonicalId)"
        try await performUploadWithRetry(
            key: key,
            bucketName: bucketName,
            data: data,
            contentType: contentType,
            onProgress: onProgress
        )
    }

    // MARK: Private

    private func performUploadWithRetry(
        key: String,
        bucketName: String,
        data: Data,
        contentType: String,
        onProgress: ((Double) -> Void)?
    ) async throws {
        var attemptCount = 0
        var lastError: Error?

        while attemptCount < maxRetries {
            attemptCount += 1

            do {
                // Report indeterminate progress at start of each attempt
                onProgress?(Double(attemptCount - 1) / Double(maxRetries))

                let statusCode = try await s3Client.put(
                    bucket: bucketName,
                    key: key,
                    data: data,
                    contentType: contentType,
                    metadata: [:]
                )

                if statusCode == 200 {
                    // Success — report 100% and return
                    onProgress?(1.0)
                    return
                } else if statusCode == 403 {
                    // Presigned URL expired — invalidate cache and retry with fresh URL
                    await urlProvider.invalidatePutURL(for: key)
                    lastError = SyncError.presignedURLExpired
                    // Continue loop for retry
                } else {
                    // Non-retryable HTTP error
                    throw SyncError.uploadFailed(reason: "HTTP \(statusCode)")
                }

            } catch let urlError as URLError where urlError.code == .timedOut {
                lastError = SyncError.networkTimeout
                // Continue loop for retry
            } catch let syncError as SyncError {
                // Propagate non-retryable SyncErrors immediately
                throw syncError
            } catch {
                // Unknown network error — treat as non-retryable
                throw SyncError.uploadFailed(reason: error.localizedDescription)
            }
        }

        // All attempts exhausted
        throw SyncError.maxRetriesExceeded(retryCount: attemptCount)
    }
}
