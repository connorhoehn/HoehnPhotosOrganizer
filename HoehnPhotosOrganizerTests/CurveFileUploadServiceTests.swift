import XCTest
import CryptoKit
@testable import HoehnPhotosOrganizer

// MARK: - Mock S3 Client for Testing

actor MockS3PresignedProvider: PresignedURLProviding {
    var shouldFail = false
    var failureReason = ""

    func presignedPutURL(for key: String, contentType: String) async throws -> URL {
        if shouldFail {
            throw NSError(domain: "MockS3", code: 500, userInfo: [NSLocalizedDescriptionKey: failureReason])
        }
        return URL(string: "https://s3.amazonaws.com/presigned-test-url")!
    }

    func invalidatePutURL(for key: String) async {
        // No-op for this mock
    }
}

// MARK: - Test Cases

final class CurveFileUploadServiceTests: XCTestCase {

    func testValidateCurveFile() {
        // Arrange
        let csvData = "Input,Red,Green,Blue\n0,0,0,0\n255,255,255,255\n".data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.csv")

        try? FileManager.default.removeItem(at: tempURL)
        try! csvData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Act & Assert
        let service = CurveFileUploadService(s3Client: MockS3PresignedProvider())
        XCTAssertNoThrow(try service.validateCurveFile(tempURL))
    }

    func testValidateCurveFileSize() {
        // Arrange - Create a 15 MB file
        let largeData = Data(repeating: 0, count: 15 * 1024 * 1024)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("large.csv")

        try? FileManager.default.removeItem(at: tempURL)
        try! largeData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Act & Assert
        let service = CurveFileUploadService(s3Client: MockS3PresignedProvider())
        do {
            try service.validateCurveFile(tempURL)
            XCTFail("Should have thrown fileTooLarge error")
        } catch let error as CurveFileError {
            if case .fileTooLarge = error {
                // Expected
            } else {
                XCTFail("Expected fileTooLarge, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testValidateCurveFileWrongExtension() {
        // Arrange
        let data = "text".data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")

        try? FileManager.default.removeItem(at: tempURL)
        try! data.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Act & Assert
        let service = CurveFileUploadService(s3Client: MockS3PresignedProvider())
        do {
            try service.validateCurveFile(tempURL)
            XCTFail("Should have thrown invalidExtension error")
        } catch let error as CurveFileError {
            if case .invalidExtension = error {
                // Expected
            } else {
                XCTFail("Expected invalidExtension, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testComputeFileHash() {
        // Arrange
        let testData = "test content for hashing".data(using: .utf8)!
        let service = CurveFileUploadService(s3Client: MockS3PresignedProvider())

        // Act
        let hash = try? service.computeFileHash(testData)

        // Assert - Verify SHA256 hash (just check it's not empty and looks like a hex string)
        XCTAssertNotNil(hash)
        XCTAssertTrue(hash?.count ?? 0 == 64)  // SHA256 produces 64 hex characters
        XCTAssertTrue(hash?.allSatisfy { $0.isHexDigit } ?? false)
    }

    func testUploadCurveFile() async {
        // Arrange
        let csvData = "Input,Red,Green,Blue\n0,0,0,0\n255,255,255,255\n".data(using: .utf8)!
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.csv")

        try? FileManager.default.removeItem(at: tempURL)
        try! csvData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let mockS3 = MockS3PresignedProvider()
        let service = CurveFileUploadService(s3Client: mockS3)

        // Act
        let reference = try? await service.uploadCurveFile(
            fileURL: tempURL,
            photoId: "photo-001",
            attemptId: "attempt-001"
        )

        // Assert
        XCTAssertNotNil(reference)
        XCTAssertEqual(reference?.originalFileName, "test.csv")
        XCTAssertTrue(reference?.s3Key.contains("curves/photo-001/attempt-001") ?? false)
        XCTAssertEqual(reference?.fileSize, csvData.count)
        XCTAssertFalse(reference?.contentHash.isEmpty ?? true)
    }
}
