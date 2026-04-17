// CurveFileSyncClient.swift
// HoehnPhotosOrganizer
//
// Uploads Photoshop curve files (.acv) to S3.
// Stores curve files at: curves/{photoId}_{printAttemptId}.acv
//
// Architecture notes:
//   - Reuses S3Uploading protocol — same mock infrastructure as ProxySyncClient.
//   - Does NOT read the curve file from disk — callers load file data and pass it in.
//     This keeps the client testable without touching the filesystem.
//   - Returns the S3 key so callers can store it in the PrintAttempt record (DB update
//     is the caller's responsibility — this client only handles the S3 transfer).
//   - Content-Type is always application/octet-stream for .acv binary files.
//   - Error handling: empty data → invalidInput; non-200 HTTP → uploadFailed.
//
// Usage:
//   let client = CurveFileSyncClient(s3Client: mockS3, bucketName: "my-bucket")
//   let key = try await client.uploadCurveFile(data: acvData, photoId: id, printAttemptId: pid)
//   // Store key in PrintAttempt record

import Foundation

// MARK: - CurveFileSyncClient

/// Uploads .acv curve files to S3 and returns the storage key.
///
/// Key format: curves/{photoId}_{printAttemptId}.acv
/// Matches the s3_curves_prefix ("curves/") from config.json.
struct CurveFileSyncClient: Sendable {

    // MARK: Dependencies

    private let s3Client: any S3Uploading
    private let bucketName: String

    // MARK: Configuration

    private let contentType = "application/octet-stream"

    // MARK: Init

    init(s3Client: any S3Uploading, bucketName: String) {
        self.s3Client = s3Client
        self.bucketName = bucketName
    }

    // MARK: Public API

    /// Uploads a curve file to S3 and returns the S3 object key.
    ///
    /// - Parameters:
    ///   - data: Raw curve file bytes (.acv, .csv, .lut, or .cube). Must not be empty.
    ///   - photoId: Photo canonical ID (e.g. "IMG_1234.CR3"). Used in S3 key.
    ///   - printAttemptId: UUID string identifying the print attempt. Used in S3 key.
    /// - Returns: S3 object key, e.g. "curves/IMG_1234.CR3_B8F2-....acv".
    /// - Throws: SyncError.invalidInput for empty data or missing IDs.
    ///           SyncError.uploadFailed for non-200 S3 responses.
    func uploadCurveFile(
        data: Data,
        photoId: String,
        printAttemptId: String
    ) async throws -> String {
        guard !data.isEmpty else {
            throw SyncError.invalidInput(message: "Curve file data must not be empty")
        }
        guard !photoId.isEmpty else {
            throw SyncError.invalidInput(message: "photoId must not be empty")
        }
        guard !printAttemptId.isEmpty else {
            throw SyncError.invalidInput(message: "printAttemptId must not be empty")
        }

        let key = makeS3Key(photoId: photoId, printAttemptId: printAttemptId)

        let statusCode = try await s3Client.put(
            bucket: bucketName,
            key: key,
            data: data,
            contentType: contentType,
            metadata: [
                "photoId": photoId,
                "printAttemptId": printAttemptId
            ]
        )

        guard statusCode == 200 else {
            throw SyncError.uploadFailed(reason: "Curve file PUT returned HTTP \(statusCode)")
        }

        return key
    }

    // MARK: Private

    private func makeS3Key(photoId: String, printAttemptId: String) -> String {
        "curves/\(photoId)_\(printAttemptId).acv"
    }
}
