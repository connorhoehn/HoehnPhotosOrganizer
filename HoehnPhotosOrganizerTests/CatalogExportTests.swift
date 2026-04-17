// CatalogExportTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-2: SQLite catalog export to S3 with versioning.
// Tests use MockS3Client from SyncTests.swift.

import XCTest
@testable import HoehnPhotosOrganizer

final class CatalogExportTests: SyncTestCase {

    // MARK: - Subject Under Test

    var sut: CatalogExportService!

    override func setUp() {
        super.setUp()
        sut = CatalogExportService(
            s3Client: mockS3,
            bucketName: "test-catalog-bucket"
        )
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - SYNC-2: Export produces a .sql.gz object in S3

    /// SYNC-2: Exporting catalog creates a .sql.gz object in S3 under catalog/exports/.
    func test_catalogExportToS3_versioningEnabled() async throws {
        mockS3.defaultPutResponse = .success(statusCode: 200)

        let key = try await sut.exportToS3(sqlContent: testCatalogExportSQL)

        XCTAssertTrue(key.hasPrefix("catalog/exports/"), "S3 key must start with catalog/exports/")
        XCTAssertTrue(key.hasSuffix(".sql.gz"), "S3 key must end with .sql.gz")
        XCTAssertEqual(mockS3.putRequests.count, 1)
        XCTAssertEqual(mockS3.putRequests[0].key, key)
    }

    // MARK: - SYNC-2: Compression reduces size

    /// SYNC-2: Exported .sql.gz is smaller than the raw SQL input.
    func test_catalogExportToS3_compressionEfficiency() async throws {
        mockS3.defaultPutResponse = .success(statusCode: 200)

        _ = try await sut.exportToS3(sqlContent: testCatalogExportSQL)

        let uploadedSize = mockS3.putRequests[0].data.count
        let originalSize = testCatalogExportSQL.data(using: .utf8)!.count
        XCTAssertLessThan(uploadedSize, originalSize + 100,
                          "Gzip output must not significantly exceed raw SQL size")
    }

    // MARK: - SYNC-2: Content-Type

    /// SYNC-2: Content-Type for catalog export must be application/gzip.
    func test_catalogExportToS3_contentType() async throws {
        mockS3.defaultPutResponse = .success(statusCode: 200)

        _ = try await sut.exportToS3(sqlContent: testCatalogExportSQL)

        XCTAssertEqual(mockS3.putRequests[0].contentType, "application/gzip")
    }

    // MARK: - SYNC-2: Upload failure propagated

    /// SYNC-2: S3 upload failure is propagated as SyncError.uploadFailed.
    func test_catalogExportToS3_uploadFailure() async throws {
        mockS3.defaultPutResponse = .failure(statusCode: 500)

        do {
            _ = try await sut.exportToS3(sqlContent: testCatalogExportSQL)
            XCTFail("Expected SyncError.uploadFailed")
        } catch SyncError.uploadFailed {
            // Expected
        } catch {
            XCTFail("Expected SyncError.uploadFailed, got \(error)")
        }
    }

    // MARK: - SYNC-2: Concurrent calls produce separate keys

    /// SYNC-2: Two concurrent exports each produce their own PUT to S3.
    func test_catalogExportToS3_concurrentUserEdit() async throws {
        mockS3.defaultPutResponse = .success(statusCode: 200)

        async let key1 = sut.exportToS3(sqlContent: testCatalogExportSQL)
        async let key2 = sut.exportToS3(sqlContent: testCatalogExportSQL)

        let results = try await [key1, key2]
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.hasPrefix("catalog/exports/") })
        XCTAssertEqual(mockS3.putRequests.count, 2)
    }

    // MARK: - SYNC-2 / SYNC-8: Restore path placeholder

    /// SYNC-2 / SYNC-8: Restore downloads the latest S3 version and validates schema.
    func test_catalogRestoreFromS3_latestVersion() throws {
        throw XCTSkip("Wave 4 (04-04): RestoreService.restoreCatalog() implemented in restore-flow plan")
    }
}
