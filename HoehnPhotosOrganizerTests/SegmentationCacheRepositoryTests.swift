import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class SegmentationCacheRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repo: SegmentationCacheRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = SegmentationCacheRepository(db: db)
    }

    // MARK: - Cache miss

    func testFetchSegmentsReturnsCacheMissNil() async throws {
        let result = try await repo.fetchSegments(forPhoto: "unknown-id")
        XCTAssertNil(result, "fetchSegments must return nil for a photo with no cached entry")
    }

    // MARK: - Store + fetch round-trip

    func testStoreAndFetchSegmentsRoundTrip() async throws {
        let json = #"[{"label":"person","confidence":0.97}]"#
        try await repo.storeSegments(forPhoto: "photo-1", segmentsJSON: json)

        let fetched = try await repo.fetchSegments(forPhoto: "photo-1")
        XCTAssertEqual(fetched, json, "fetchSegments must return the exact JSON stored by storeSegments")
    }

    // MARK: - Upsert overwrites existing entry

    func testStoreSegmentsUpsertOverwritesExistingEntry() async throws {
        try await repo.storeSegments(forPhoto: "photo-2", segmentsJSON: #"[{"label":"sky"}]"#)
        let updated = #"[{"label":"sky"},{"label":"tree"}]"#
        try await repo.storeSegments(forPhoto: "photo-2", segmentsJSON: updated)

        let fetched = try await repo.fetchSegments(forPhoto: "photo-2")
        XCTAssertEqual(fetched, updated, "storeSegments must overwrite the previous entry on conflict")
    }

    // MARK: - Invalidate

    func testInvalidateDeletesCachedEntry() async throws {
        try await repo.storeSegments(forPhoto: "photo-3", segmentsJSON: #"[{"label":"water"}]"#)
        try await repo.invalidate(forPhoto: "photo-3")

        let fetched = try await repo.fetchSegments(forPhoto: "photo-3")
        XCTAssertNil(fetched, "fetchSegments must return nil after invalidate removes the cache entry")
    }
}
