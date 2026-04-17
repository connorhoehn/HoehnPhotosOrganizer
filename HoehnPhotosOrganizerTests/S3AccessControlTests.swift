// S3AccessControlTests.swift
// HoehnPhotosOrganizerTests
//
// SYNC-5: All S3 assets (proxies and curve files) remain private.
// Access requires a presigned URL; direct GET returns 403.
// All tests are stub skips; Wave 2 implementation will drive them RED → GREEN.

import XCTest

final class S3AccessControlTests: XCTestCase {

    /// SYNC-5: Direct GET to proxies/{id}.jpg without presigned URL returns 403.
    /// Verifies: MockS3Client configured to deny unsigned requests → statusCode 403.
    func test_s3BucketPolicy_deniesDirectAccess() throws {
        throw XCTSkip("Wave 2+ implementation: unsigned GET → MockS3Client returns 403 → SyncError.accessDenied")
    }

    /// SYNC-5: GET with valid presigned URL returns 200 + proxy data.
    /// Verifies: MockPresignedURLProvider generates URL → MockS3Client returns 200 with testProxyJPEGData.
    func test_s3BucketPolicy_allowsPresignedURL() throws {
        throw XCTSkip("Wave 2+ implementation: presigned GET URL → 200 + proxy data returned and verified")
    }

    /// SYNC-5: Presigned URL valid for 15 minutes, then rejected.
    /// Verifies: MockPresignedURLProvider.isExpired after TTL → request with expired URL returns 403.
    func test_presignedURL_expiresAfterTime() throws {
        throw XCTSkip("Wave 2+ implementation: URL TTL = 900s → isExpired at t+901 = true → GET returns 403")
    }

    /// SYNC-5: Curve file prefix (curves/) also requires presigned URL.
    /// Verifies: Direct GET to curves/{id}_{attemptId}.acv returns 403; presigned returns 200.
    func test_curveFileAccess_requiresPresignedURL() throws {
        throw XCTSkip("Wave 2+ implementation: unsigned GET curves/ prefix → 403; presigned GET curves/ prefix → 200")
    }
}
