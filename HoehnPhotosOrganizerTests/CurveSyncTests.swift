// CurveSyncTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-4: Photoshop curve files (.acv) upload to S3 at curves/{photoId}_{attemptId}.acv.
// Tests use MockS3Client from SyncTests.swift.

import XCTest
@testable import HoehnPhotosOrganizer

final class CurveSyncTests: SyncTestCase {

    // MARK: - Subject Under Test

    var sut: CurveFileSyncClient!

    override func setUp() {
        super.setUp()
        sut = CurveFileSyncClient(
            s3Client: mockS3,
            bucketName: "test-curves-bucket"
        )
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - SYNC-4: Successful curve file upload

    /// SYNC-4: Upload .acv curve file via presigned PUT URL.
    /// Verifies key == curves/{photoId}_{attemptId}.acv, status 200.
    func test_curveFileUploadWithPresignedURL_success() async throws {
        let attempt = MockPrintAttempt()
        let curveData = makeACVData()
        mockS3.defaultPutResponse = .success(statusCode: 200)

        let s3Key = try await sut.uploadCurveFile(
            data: curveData,
            photoId: attempt.canonicalId,
            printAttemptId: attempt.attemptId
        )

        XCTAssertEqual(s3Key, "curves/\(attempt.canonicalId)_\(attempt.attemptId).acv")
        XCTAssertEqual(mockS3.putRequests.count, 1)
        XCTAssertEqual(mockS3.putRequests[0].key, s3Key)
    }

    // MARK: - SYNC-4: Content-Type header

    /// SYNC-4: Content-Type for .acv files must be application/octet-stream.
    func test_curveFileUploadWithPresignedURL_contentType() async throws {
        let attempt = MockPrintAttempt()
        let curveData = makeACVData()
        mockS3.defaultPutResponse = .success(statusCode: 200)

        _ = try await sut.uploadCurveFile(
            data: curveData,
            photoId: attempt.canonicalId,
            printAttemptId: attempt.attemptId
        )

        XCTAssertEqual(mockS3.putRequests[0].contentType, "application/octet-stream")
    }

    // MARK: - SYNC-4: Metadata storage in returned s3Key

    /// SYNC-4: After upload, returned s3Key encodes both photoId and attemptId.
    func test_curveFileUploadMetadata_storage() async throws {
        let photoId = "IMG_1234.CR3"
        let attemptId = UUID().uuidString
        let curveData = makeACVData()
        mockS3.defaultPutResponse = .success(statusCode: 200)

        let s3Key = try await sut.uploadCurveFile(
            data: curveData,
            photoId: photoId,
            printAttemptId: attemptId
        )

        XCTAssertTrue(s3Key.contains(photoId), "s3Key must contain photoId")
        XCTAssertTrue(s3Key.contains(attemptId), "s3Key must contain attemptId")
        XCTAssertTrue(s3Key.hasSuffix(".acv"), "s3Key must end with .acv")
    }

    // MARK: - SYNC-4: Empty data rejected

    /// SYNC-4: Empty curve file data throws SyncError.invalidInput.
    func test_curveFileUpload_emptyData() async throws {
        do {
            _ = try await sut.uploadCurveFile(
                data: Data(),
                photoId: "IMG_0001.jpg",
                printAttemptId: UUID().uuidString
            )
            XCTFail("Expected SyncError.invalidInput for empty data")
        } catch SyncError.invalidInput {
            // Expected
        } catch {
            XCTFail("Expected SyncError.invalidInput, got \(error)")
        }
    }

    // MARK: - SYNC-4: Upload failure propagated

    /// SYNC-4: S3 failure during curve upload is propagated as SyncError.uploadFailed.
    func test_curveFileUpload_uploadFailure() async throws {
        mockS3.defaultPutResponse = .failure(statusCode: 500)

        do {
            _ = try await sut.uploadCurveFile(
                data: makeACVData(),
                photoId: "IMG_0001.jpg",
                printAttemptId: UUID().uuidString
            )
            XCTFail("Expected SyncError.uploadFailed")
        } catch SyncError.uploadFailed {
            // Expected
        } catch {
            XCTFail("Expected SyncError.uploadFailed, got \(error)")
        }
    }

    // MARK: - Helpers

    /// Creates minimal valid .acv-like binary data (Adobe magic bytes 0x00 0x05).
    private func makeACVData() -> Data {
        var bytes = [UInt8](repeating: 0x00, count: 128)
        bytes[0] = 0x00
        bytes[1] = 0x05
        return Data(bytes)
    }
}
