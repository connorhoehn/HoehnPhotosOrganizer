import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct CollectionModelTests {

    // MARK: - PhotoCollection round-trip

    @Test
    func testCollectionInsertAndFetchRoundTrip() async throws {
        // CUR-1: insert a PhotoCollection row, fetch it back — returns the same row
        let db = try AppDatabase.makeInMemory()
        let collection = PhotoCollection.new(name: "Test Collection", kind: "manual")
        try await db.dbPool.write { conn in
            try collection.insert(conn)
        }
        let fetched = try await db.dbPool.read { conn in
            try PhotoCollection.fetchOne(conn, key: collection.id)
        }
        #expect(fetched?.id == collection.id)
        #expect(fetched?.name == "Test Collection")
        #expect(fetched?.kind == "manual")
    }

    // MARK: - CollectionMember insert and fetch

    @Test
    func testCollectionMemberInsertAndFetchByCollectionId() async throws {
        // CUR-2: insert a CollectionMember, fetch by collection_id — returns the member
        let db = try AppDatabase.makeInMemory()
        let collection = PhotoCollection.new(name: "Keepers", kind: "manual")
        let photo = PhotoAsset.new(canonicalName: "IMG_001.dng", role: .original,
                                   filePath: "/vol/IMG_001.dng", fileSize: 5_000_000)
        try await db.dbPool.write { conn in
            try collection.insert(conn)
            try photo.insert(conn)
        }
        let now = ISO8601DateFormatter().string(from: .now)
        let member = CollectionMember(id: UUID().uuidString, collectionId: collection.id,
                                      photoId: photo.id, addedAt: now)
        try await db.dbPool.write { conn in
            try member.insert(conn)
        }
        let fetched = try await db.dbPool.read { conn in
            try CollectionMember
                .filter(Column("collection_id") == collection.id)
                .fetchAll(conn)
        }
        #expect(fetched.count == 1)
        #expect(fetched.first?.photoId == photo.id)
    }

    // MARK: - SmartCollectionRule JSON encode/decode

    @Test
    func testSmartCollectionRuleEncodesAndDecodesWithoutDataLoss() throws {
        // CUR-4: SmartCollectionRule encodes/decodes from JSON without data loss
        let rule = SmartCollectionRule(field: .curationState, op: .equals, value: "keeper")
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(SmartCollectionRule.self, from: data)
        #expect(decoded.field == rule.field)
        #expect(decoded.op == rule.op)
        #expect(decoded.value == rule.value)
    }

    // MARK: - CurationCounts structure

    @Test
    func testCurationCountsDefaultsToZero() {
        let counts = CurationCounts(keeper: 0, archive: 0, needsReview: 0, rejected: 0)
        #expect(counts.keeper == 0)
        #expect(counts.archive == 0)
        #expect(counts.needsReview == 0)
        #expect(counts.rejected == 0)
    }
}

struct PhotoRepositoryCurationTests {

    // MARK: - updateCurationState

    @Test
    func testUpdateCurationStatePersistsCorrectly() async throws {
        // CUR-1: updateCurationState sets curation_state for a given photo ID
        let appDb = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: appDb)
        let photo = PhotoAsset.new(canonicalName: "IMG_002.dng", role: .original,
                                   filePath: "/vol/IMG_002.dng", fileSize: 4_000_000)
        try await appDb.dbPool.write { conn in
            try photo.insert(conn)
        }
        try await repo.updateCurationState(id: photo.id, state: .keeper)
        let updated = try await repo.fetchById(photo.id)
        #expect(updated?.curationState == CurationState.keeper.rawValue)
    }

    // MARK: - bulkUpdateCurationState

    @Test
    func testBulkUpdateCurationStateUpdatesAllIDs() async throws {
        // CUR-2: bulkUpdateCurationState sets state for all IDs in one transaction
        let appDb = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: appDb)
        let photo1 = PhotoAsset.new(canonicalName: "IMG_003.dng", role: .original,
                                    filePath: "/vol/IMG_003.dng", fileSize: 3_000_000)
        let photo2 = PhotoAsset.new(canonicalName: "IMG_004.dng", role: .original,
                                    filePath: "/vol/IMG_004.dng", fileSize: 3_000_000)
        try await appDb.dbPool.write { conn in
            try photo1.insert(conn)
            try photo2.insert(conn)
        }
        try await repo.bulkUpdateCurationState(ids: [photo1.id, photo2.id], state: .archive)
        let updated1 = try await repo.fetchById(photo1.id)
        let updated2 = try await repo.fetchById(photo2.id)
        #expect(updated1?.curationState == CurationState.archive.rawValue)
        #expect(updated2?.curationState == CurationState.archive.rawValue)
    }

    // MARK: - curationCounts

    @Test
    func testCurationCountsReturnsCorrectTotals() async throws {
        // CUR-5: curationCounts returns per-state totals matching actual row counts
        let appDb = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: appDb)
        let photo1 = PhotoAsset.new(canonicalName: "IMG_005.dng", role: .original,
                                    filePath: "/vol/IMG_005.dng", fileSize: 3_000_000)
        let photo2 = PhotoAsset.new(canonicalName: "IMG_006.dng", role: .original,
                                    filePath: "/vol/IMG_006.dng", fileSize: 3_000_000)
        let photo3 = PhotoAsset.new(canonicalName: "IMG_007.dng", role: .original,
                                    filePath: "/vol/IMG_007.dng", fileSize: 3_000_000)
        try await appDb.dbPool.write { conn in
            try photo1.insert(conn)
            try photo2.insert(conn)
            try photo3.insert(conn)
        }
        // photo1 -> keeper, photo2 -> archive, photo3 stays needs_review (default)
        try await repo.updateCurationState(id: photo1.id, state: .keeper)
        try await repo.updateCurationState(id: photo2.id, state: .archive)
        let counts = try await repo.curationCounts()
        #expect(counts.keeper == 1)
        #expect(counts.archive == 1)
        #expect(counts.needsReview == 1)
        #expect(counts.rejected == 0)
    }
}
