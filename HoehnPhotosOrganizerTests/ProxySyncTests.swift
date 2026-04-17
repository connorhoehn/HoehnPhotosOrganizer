// ProxySyncTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-1: Proxy photos upload to S3 via presigned URL with retry logic.
// Tests use MockS3Client and MockPresignedURLProvider from SyncTests.swift.

import XCTest
@testable import HoehnPhotosOrganizer

final class ProxySyncTests: SyncTestCase {

    // MARK: - Subject Under Test

    var sut: ProxySyncClient!

    override func setUp() {
        super.setUp()
        sut = ProxySyncClient(
            s3Client: mockS3,
            urlProvider: mockURLProvider
        )
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - SYNC-1: Successful upload

    /// SYNC-1: Upload a JPEG proxy to proxies/{canonicalId}.jpg via presigned PUT URL.
    /// Verifies: MockS3Client receives PUT with correct key and data.
    func test_proxyUploadWithPresignedURL_success() async throws {
        let asset = MockPhotoAsset()
        mockS3.defaultPutResponse = .success(statusCode: 200)

        try await sut.uploadProxy(
            data: asset.proxyData,
            canonicalId: asset.canonicalId,
            bucketName: "test-bucket"
        )

        XCTAssertEqual(mockS3.putRequests.count, 1)
        XCTAssertEqual(mockS3.putRequests[0].key, "proxies/\(asset.canonicalId)")
        XCTAssertEqual(mockS3.putRequests[0].data, asset.proxyData)
    }

    // MARK: - SYNC-1: Content-Type header

    /// SYNC-1: Content-Type header on proxy upload must be image/jpeg.
    func test_proxyUploadWithPresignedURL_contentType() async throws {
        let asset = MockPhotoAsset()
        mockS3.defaultPutResponse = .success(statusCode: 200)

        try await sut.uploadProxy(
            data: asset.proxyData,
            canonicalId: asset.canonicalId,
            bucketName: "test-bucket"
        )

        XCTAssertEqual(mockS3.putRequests[0].contentType, "image/jpeg")
    }

    // MARK: - SYNC-1: URL expiration retry

    /// SYNC-1: Presigned URL expires (403 response) — client retries with fresh URL and succeeds.
    func test_proxyUploadWithPresignedURL_expiration() async throws {
        let asset = MockPhotoAsset()
        // First call returns 403 (expired URL), second call returns 200 (fresh URL)
        mockS3.putResponseSequence = [
            .failure(statusCode: 403),
            .success(statusCode: 200)
        ]

        try await sut.uploadProxy(
            data: asset.proxyData,
            canonicalId: asset.canonicalId,
            bucketName: "test-bucket"
        )

        // Should have retried: 2 PUT attempts total
        XCTAssertEqual(mockS3.putRequests.count, 2)
    }

    // MARK: - SYNC-1: Network failure exhausts retries

    /// SYNC-1: Network timeout retries up to max, then throws SyncError.maxRetriesExceeded.
    func test_proxyUploadWithPresignedURL_networkFailure() async throws {
        let asset = MockPhotoAsset()
        // All three attempts time out
        mockS3.putResponseSequence = [
            .timeout,
            .timeout,
            .timeout
        ]

        do {
            try await sut.uploadProxy(
                data: asset.proxyData,
                canonicalId: asset.canonicalId,
                bucketName: "test-bucket"
            )
            XCTFail("Expected SyncError.maxRetriesExceeded but upload succeeded")
        } catch SyncError.maxRetriesExceeded(let retryCount) {
            XCTAssertEqual(retryCount, 3)
        } catch {
            XCTFail("Expected SyncError.maxRetriesExceeded, got \(error)")
        }
    }

    // MARK: - SYNC-1: Progress callback

    /// SYNC-1: Progress callback reports values between 0.0 and 1.0.
    func test_proxyUploadWithPresignedURL_progressCallback() async throws {
        let asset = MockPhotoAsset()
        mockS3.defaultPutResponse = .success(statusCode: 200)

        var progressValues: [Double] = []

        try await sut.uploadProxy(
            data: asset.proxyData,
            canonicalId: asset.canonicalId,
            bucketName: "test-bucket",
            onProgress: { progress in
                progressValues.append(progress)
            }
        )

        XCTAssertFalse(progressValues.isEmpty, "Progress callback should have been called at least once")
        XCTAssertTrue(progressValues.allSatisfy { $0 >= 0.0 && $0 <= 1.0 },
                      "All progress values must be in [0.0, 1.0]")
    }

    // MARK: - SyncErrors

    /// SyncError cases produce non-nil errorDescription.
    func test_syncError_errorDescriptions() {
        let errors: [SyncError] = [
            .presignedURLExpired,
            .uploadFailed(reason: "connection reset"),
            .networkTimeout,
            .maxRetriesExceeded(retryCount: 3),
            .invalidInput(message: "empty canonicalId")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "errorDescription must not be nil for \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty, "errorDescription must not be empty for \(error)")
        }
    }
}
