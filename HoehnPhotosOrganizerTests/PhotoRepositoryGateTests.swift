import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

/// Verifies the `import_status = 'library'` gate that PhotoRepository applies by default
/// to fetchAll / fetchByIds. Staged photos (inside an open triage job) must be excluded
/// from default callers and only returned when `includingStaged: true` is passed.
final class PhotoRepositoryGateTests: XCTestCase {
    var db: AppDatabase!
    var repo: PhotoRepository!

    // Pre-inserted photo IDs for assertions
    var libraryAId: String!
    var stagedBId: String!
    var libraryCId: String!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = PhotoRepository(db: db)

        // Build three photos: A = library, B = staged, C = library.
        // `PhotoAsset.new` defaults importStatus to "staged"; we override per-photo.
        func mkPhoto(_ name: String, importStatus: String) -> PhotoAsset {
            var asset = PhotoAsset.new(
                canonicalName: name,
                role: .original,
                filePath: "/tmp/\(name)",
                fileSize: 0
            )
            asset.importStatus = importStatus
            return asset
        }

        let a = mkPhoto("a.dng", importStatus: "library")
        let b = mkPhoto("b.dng", importStatus: "staged")
        let c = mkPhoto("c.dng", importStatus: "library")

        libraryAId = a.id
        stagedBId  = b.id
        libraryCId = c.id

        try await repo.upsert(a)
        try await repo.upsert(b)
        try await repo.upsert(c)
    }

    override func tearDown() async throws {
        db = nil
        repo = nil
    }

    // MARK: - fetchAll gating

    func testFetchAllDefaultReturnsLibraryOnly() async throws {
        let rows = try await repo.fetchAll()
        let ids = Set(rows.map(\.id))
        XCTAssertEqual(rows.count, 2, "fetchAll() should return only the two library photos (A, C)")
        XCTAssertTrue(ids.contains(libraryAId),  "Library photo A must be returned")
        XCTAssertTrue(ids.contains(libraryCId),  "Library photo C must be returned")
        XCTAssertFalse(ids.contains(stagedBId),  "Staged photo B must be excluded")
    }

    func testFetchAllIncludingStagedReturnsAll() async throws {
        let rows = try await repo.fetchAll(includingStaged: true)
        let ids = Set(rows.map(\.id))
        XCTAssertEqual(rows.count, 3, "fetchAll(includingStaged: true) should return all three photos")
        XCTAssertTrue(ids.contains(libraryAId))
        XCTAssertTrue(ids.contains(stagedBId), "Staged photo B must be present when staged is included")
        XCTAssertTrue(ids.contains(libraryCId))
    }

    // MARK: - fetchByIds gating

    func testFetchByIdsDefaultDropsStaged() async throws {
        let rows = try await repo.fetchByIds([libraryAId, stagedBId, libraryCId])
        let ids = Set(rows.map(\.id))
        XCTAssertEqual(rows.count, 2, "fetchByIds([A,B,C]) should return only A and C by default")
        XCTAssertTrue(ids.contains(libraryAId))
        XCTAssertFalse(ids.contains(stagedBId),
                       "Staged ID passed to fetchByIds must be silently dropped from results")
        XCTAssertTrue(ids.contains(libraryCId))
    }

    func testFetchByIdsIncludingStagedReturnsAll() async throws {
        let rows = try await repo.fetchByIds([libraryAId, stagedBId, libraryCId],
                                             includingStaged: true)
        let ids = Set(rows.map(\.id))
        XCTAssertEqual(rows.count, 3, "fetchByIds(includingStaged: true) should return all three photos")
        XCTAssertTrue(ids.contains(libraryAId))
        XCTAssertTrue(ids.contains(stagedBId))
        XCTAssertTrue(ids.contains(libraryCId))
    }
}
