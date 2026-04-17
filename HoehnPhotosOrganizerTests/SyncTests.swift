// SyncTests.swift
// HoehnPhotosOrganizerTests
//
// Common test infrastructure for Phase 4 cloud sync tests.
// Provides MockS3Client, MockDynamoDBClient, and MockPresignedURLProvider.
// All other sync test files import this file's types via shared test target membership.
//
// Network failure injection:
//   - Set MockS3Client.nextError to simulate any URLError or HTTP status code.
//   - Set MockS3Client.failAfterRequestCount to trigger failure partway through a batch.
//   - Set MockDynamoDBClient.nextError to simulate DynamoDB throttling or network loss.
//
// Retry scenario setup:
//   - Use MockS3Client.responseSequence to return different results per request (e.g., fail, fail, succeed).
//   - Use MockPresignedURLProvider.expireAfterSeconds = 0 to simulate immediate URL expiration.

import XCTest
import Foundation
@testable import HoehnPhotosOrganizer

// MARK: - S3 Request/Response Types

/// Recorded details of a single S3 PUT request (proxy upload or catalog export).
struct MockS3PutRequest {
    let bucket: String
    let key: String
    let data: Data
    let contentType: String
    let metadata: [String: String]
    let timestamp: Date
}

/// Recorded details of a single S3 GET request (proxy or catalog download).
struct MockS3GetRequest {
    let bucket: String
    let key: String
    let timestamp: Date
}

/// Recorded details of a HeadObject request (used for incremental sync checksum check).
struct MockS3HeadRequest {
    let bucket: String
    let key: String
    let timestamp: Date
}

/// Response returned by MockS3Client for a PUT request.
enum MockS3Response {
    case success(statusCode: Int = 200, etag: String = "\"mock-etag-\(UUID().uuidString)\"")
    case failure(statusCode: Int, error: Error? = nil)
    case timeout
}

// MARK: - MockS3Client

/// In-memory mock for AWS S3 operations.
/// Records all requests and returns configurable responses.
///
/// Usage:
///   let client = MockS3Client()
///   client.nextPutResponse = .failure(statusCode: 403)
///   // ... call upload code that uses client ...
///   XCTAssertEqual(client.putRequests.count, 1)
final class MockS3Client {

    // MARK: Recorded requests

    private(set) var putRequests: [MockS3PutRequest] = []
    private(set) var getRequests: [MockS3GetRequest] = []
    private(set) var headRequests: [MockS3HeadRequest] = []

    // MARK: Response configuration

    /// Single response returned for the next PUT call, then reverts to defaultPutResponse.
    var nextPutResponse: MockS3Response?

    /// Sequence of responses returned in order for successive PUT calls.
    /// When exhausted, falls back to nextPutResponse then defaultPutResponse.
    var putResponseSequence: [MockS3Response] = []

    /// Default response when no override is set.
    var defaultPutResponse: MockS3Response = .success()

    /// Number of successful PUTs before injecting the configured error.
    /// -1 means never fail automatically.
    var failAfterRequestCount: Int = -1

    /// Single response for the next GET call.
    var nextGetResponse: (data: Data, statusCode: Int)?

    /// Response for HeadObject (nil = object not found / 404).
    var headObjectETag: String? = nil  // nil simulates 404 (not uploaded yet)

    // MARK: S3 Operations

    /// Simulates presigned URL PUT upload.
    func put(
        bucket: String,
        key: String,
        data: Data,
        contentType: String,
        metadata: [String: String] = [:]
    ) async throws -> Int {
        let req = MockS3PutRequest(
            bucket: bucket,
            key: key,
            data: data,
            contentType: contentType,
            metadata: metadata,
            timestamp: Date()
        )
        putRequests.append(req)

        // Automatic failure after N requests
        if failAfterRequestCount >= 0 && putRequests.count > failAfterRequestCount {
            throw URLError(.timedOut)
        }

        let response = nextResponseForPut()
        switch response {
        case .success(let statusCode, _):
            return statusCode
        case .failure(let statusCode, let error):
            if let error { throw error }
            return statusCode
        case .timeout:
            throw URLError(.timedOut)
        }
    }

    /// Simulates presigned URL GET download.
    func get(bucket: String, key: String) async throws -> Data {
        getRequests.append(MockS3GetRequest(bucket: bucket, key: key, timestamp: Date()))
        if let response = nextGetResponse {
            if response.statusCode == 200 {
                return response.data
            } else {
                throw URLError(.badServerResponse)
            }
        }
        return testProxyJPEGData
    }

    /// Simulates HeadObject — returns ETag if object exists, throws 404-like error if not.
    func headObject(bucket: String, key: String) async throws -> String? {
        headRequests.append(MockS3HeadRequest(bucket: bucket, key: key, timestamp: Date()))
        return headObjectETag
    }

    // MARK: Helpers

    func resetRecordings() {
        putRequests = []
        getRequests = []
        headRequests = []
    }

    private func nextResponseForPut() -> MockS3Response {
        if !putResponseSequence.isEmpty {
            return putResponseSequence.removeFirst()
        }
        if let next = nextPutResponse {
            nextPutResponse = nil
            return next
        }
        return defaultPutResponse
    }
}

// MARK: - DynamoDB Types

/// Represents a single item stored in the mock DynamoDB ThreadEntry table.
struct MockDynamoDBItem {
    let threadRootId: String   // Partition key
    let sortKey: String        // Sort key: ISO-8601 timestamp + "#" + entryId
    let type: String           // "note" | "ai_turn" | "print_attempt"
    let content: String        // Raw JSON or plain text
    let createdAt: Date
}

// MARK: - MockDynamoDBClient

/// In-memory mock for AWS DynamoDB operations on the ThreadEntry table.
/// Simulates GSI query returning items in chronological order.
/// Does NOT enforce DynamoDB provisioned throughput — inject errors via nextError.
///
/// Usage:
///   let client = MockDynamoDBClient()
///   client.nextError = NSError(domain: "DynamoDB", code: 400) // simulate throttle
final class MockDynamoDBClient {

    // MARK: Storage (simulates GSI partition by threadRootId)

    private var items: [String: [MockDynamoDBItem]] = [:]   // [threadRootId: [items sorted by sortKey]]
    private(set) var putItemCalls: Int = 0
    private(set) var batchWriteItemCalls: Int = 0
    private(set) var queryCallCount: Int = 0

    // MARK: Error injection

    var nextError: Error?

    // MARK: Operations

    /// Simulates PutItem — stores a single thread entry.
    func putItem(_ item: MockDynamoDBItem) async throws {
        if let error = nextError { nextError = nil; throw error }
        putItemCalls += 1
        var bucket = items[item.threadRootId] ?? []
        bucket.append(item)
        bucket.sort { $0.sortKey < $1.sortKey }
        items[item.threadRootId] = bucket
    }

    /// Simulates BatchWriteItem — stores multiple entries atomically.
    /// DynamoDB limit: 25 items per call. Mock enforces this for realism.
    func batchWriteItems(_ batch: [MockDynamoDBItem]) async throws {
        if let error = nextError { nextError = nil; throw error }
        precondition(batch.count <= 25, "DynamoDB BatchWriteItem limit is 25 items")
        batchWriteItemCalls += 1
        for item in batch {
            var bucket = items[item.threadRootId] ?? []
            bucket.append(item)
            bucket.sort { $0.sortKey < $1.sortKey }
            items[item.threadRootId] = bucket
        }
    }

    /// Simulates GSI Query — returns all entries for a threadRootId in sort-key order.
    /// Optionally filters to entries with sortKey > `afterSortKey` for incremental sync.
    func query(threadRootId: String, afterSortKey: String? = nil) async throws -> [MockDynamoDBItem] {
        if let error = nextError { nextError = nil; throw error }
        queryCallCount += 1
        let all = items[threadRootId] ?? []
        if let after = afterSortKey {
            return all.filter { $0.sortKey > after }
        }
        return all
    }

    func resetRecordings() {
        items = [:]
        putItemCalls = 0
        batchWriteItemCalls = 0
        queryCallCount = 0
    }
}

// MARK: - MockPresignedURLProvider

/// Generates deterministic presigned URLs for sync tests.
/// Simulates URL expiration by tracking issue time against a configurable TTL.
final class MockPresignedURLProvider {

    /// TTL in seconds. Default 900 (15 minutes) per SYNC-5.
    var expirationSeconds: TimeInterval = 900

    /// Force all generated URLs to be immediately expired.
    var expireImmediately: Bool = false

    private struct IssuedURL {
        let url: URL
        let issuedAt: Date
        let expiresAt: Date
    }

    private var issued: [String: IssuedURL] = [:]

    /// Generates a presigned URL for the given S3 key.
    /// In production this would call AWS SDK; here it builds a local test URL.
    func presignedPutURL(for key: String, contentType: String) -> URL {
        let now = Date()
        let ttl = expireImmediately ? -1.0 : expirationSeconds
        let url = URL(string: "https://test-bucket.s3.amazonaws.com/\(key)?X-Amz-Expires=\(Int(ttl))&X-Amz-Signature=mock")!
        issued[key] = IssuedURL(url: url, issuedAt: now, expiresAt: now.addingTimeInterval(ttl))
        return url
    }

    /// Returns true if the URL for `key` has expired relative to `now`.
    func isExpired(key: String, at now: Date = Date()) -> Bool {
        guard let record = issued[key] else { return true }
        return now >= record.expiresAt
    }

    func resetRecordings() {
        issued = [:]
    }
}

// MARK: - Shared Helper Functions

/// Creates a MockDynamoDBItem from a MockThreadEntry for test convenience.
func makeTestDynamoDBItem(from entry: MockThreadEntry) -> MockDynamoDBItem {
    MockDynamoDBItem(
        threadRootId: entry.threadRootId,
        sortKey: entry.sortKey,
        type: entry.type.rawValue,
        content: entry.content,
        createdAt: entry.timestamp
    )
}

/// Builds a test proxy payload (key + data) simulating what SyncManager would upload.
func makeTestProxyPayload(canonicalId: String = testCanonicalIds[0]) -> (key: String, data: Data) {
    (key: "proxies/\(canonicalId)", data: testProxyJPEGData)
}

/// Builds a minimal MockThreadEntry for use in sync tests.
func makeTestThreadEntry(
    threadRootId: String = testCanonicalIds[0],
    type: MockThreadEntry.EntryType = .note,
    content: String = "Test note"
) -> MockThreadEntry {
    MockThreadEntry(threadRootId: threadRootId, type: type, content: content)
}

/// Builds a mock sync status payload (used by SyncStatusViewModelTests).
func makeTestSyncStatus(
    canonicalId: String = testCanonicalIds[0],
    state: String = "localOnly"
) -> [String: String] {
    ["canonicalId": canonicalId, "state": state, "updatedAt": ISO8601DateFormatter().string(from: Date())]
}

/// Returns true if the presigned URL for `key` is expired relative to `after`.
/// Uses MockPresignedURLProvider under the hood so tests don't need to know the URL format.
func verifyPresignedURLExpired(provider: MockPresignedURLProvider, key: String, after: Date = Date()) -> Bool {
    provider.isExpired(key: key, at: after)
}

// MARK: - Base Test Class

/// Base class providing pre-built mock clients for sync test subclasses.
/// Subclass this instead of XCTestCase to get MockS3Client, MockDynamoDBClient,
/// and MockPresignedURLProvider wired up and reset between tests.
class SyncTestCase: XCTestCase {
    var mockS3: MockS3Client!
    var mockDynamo: MockDynamoDBClient!
    var mockURLProvider: MockPresignedURLProvider!

    override func setUp() {
        super.setUp()
        mockS3 = MockS3Client()
        mockDynamo = MockDynamoDBClient()
        mockURLProvider = MockPresignedURLProvider()
    }

    override func tearDown() {
        mockS3.resetRecordings()
        mockDynamo.resetRecordings()
        mockURLProvider.resetRecordings()
        super.tearDown()
    }
}

// MARK: - Protocol Conformances (production protocols from CloudSync/)

// MockS3Client conforms to S3Uploading so ProxySyncClient can accept it in tests.
extension MockS3Client: S3Uploading {}

// MockPresignedURLProvider conforms to PresignedURLProviding so ProxySyncClient and
// CurveFileSyncClient can accept it in tests.
extension MockPresignedURLProvider: PresignedURLProviding {
    func presignedPutURL(for key: String, contentType: String) async throws -> URL {
        // Explicitly call the concrete synchronous method to avoid recursive protocol dispatch.
        let now = Date()
        let ttl = expireImmediately ? -1.0 : expirationSeconds
        return URL(string: "https://test-bucket.s3.amazonaws.com/\(key)?X-Amz-Expires=\(Int(ttl))&X-Amz-Signature=mock")!
    }

    func invalidatePutURL(for key: String) async {
        // No explicit invalidation needed — MockPresignedURLProvider.expireImmediately
        // is set per-test for expiration scenarios.
        resetRecordings()
    }
}
