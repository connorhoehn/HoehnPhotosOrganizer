// SyncErrors.swift
// HoehnPhotosOrganizer
//
// Typed errors for all cloud sync operations (proxy uploads, catalog export,
// curve file sync). SyncError is thrown by ProxySyncClient, CatalogExportService,
// and CurveFileSyncClient to surface precise failure information to callers.
//
// Design notes:
//   - Each case carries the information needed to decide whether to retry,
//     show a user-facing message, or escalate to the sync status badge.
//   - maxRetriesExceeded carries retryCount so callers can log the number
//     of attempts that were made before giving up.
//   - presignedURLExpired is a distinct case from uploadFailed because it
//     should trigger a fresh-URL fetch + retry rather than a direct error display.

import Foundation

// MARK: - SyncError

/// Errors thrown by ProxySyncClient, CatalogExportService, and CurveFileSyncClient.
enum SyncError: LocalizedError, Sendable {

    /// The presigned URL returned a 403 (Forbidden) — it has expired.
    /// Callers should fetch a new presigned URL and retry the upload.
    case presignedURLExpired

    /// An upload (PUT) or download (GET) request failed with a non-retryable status code
    /// or a general network error that is not a timeout.
    case uploadFailed(reason: String)

    /// The request timed out. This is distinct from uploadFailed so retry logic can
    /// increment the retry counter and apply backoff correctly.
    case networkTimeout

    /// The maximum number of retry attempts was exhausted. retryCount is the number
    /// of attempts made (including the initial attempt).
    case maxRetriesExceeded(retryCount: Int)

    /// A pre-condition for the operation was violated (e.g., empty canonicalId, nil data).
    /// This is not retryable — the caller must fix the input.
    case invalidInput(message: String)

    /// The server returned a non-HTTP or otherwise unparseable response.
    case invalidResponse

    /// A DynamoDB query request failed (e.g., HTTP error or network failure).
    case queryFailed(String)

    // MARK: LocalizedError

    var errorDescription: String? {
        switch self {
        case .presignedURLExpired:
            return "The upload URL has expired. A fresh URL will be requested automatically."
        case .uploadFailed(let reason):
            return "Upload failed: \(reason)"
        case .networkTimeout:
            return "The upload timed out. Check your network connection and try again."
        case .maxRetriesExceeded(let retryCount):
            return "Upload failed after \(retryCount) attempt\(retryCount == 1 ? "" : "s"). Check your connection and retry."
        case .invalidInput(let message):
            return "Invalid input: \(message)"
        case .invalidResponse:
            return "Server returned an unexpected response format."
        case .queryFailed(let reason):
            return "Query failed: \(reason)"
        }
    }
}
