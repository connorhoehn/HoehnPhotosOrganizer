import Testing
import GRDB
@testable import HoehnPhotosOrganizer

struct CurationRepositoryTests {

    @Test
    func testUpdateCurationStatePersistsKeeper() async throws {
        // CUR-1: updateCurationState(_:for:) must persist .keeper to photo_assets
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)

        // Insert a test PhotoAsset using the .new() helper
        var asset = PhotoAsset.new(canonicalName: "test.dng", role: .original, filePath: "/tmp/test.dng", fileSize: 1000)
        try await photoRepo.upsert(asset)

        // Update curation state to keeper
        try await photoRepo.updateCurationState(id: asset.id, state: .keeper)

        // Fetch and verify
        let updated = try await photoRepo.fetchById(asset.id)
        #expect(updated?.curationState == CurationState.keeper.rawValue)
    }

    @Test
    func testBulkUpdateCurationStateAppliesStateToAllIDs() async throws {
        // CUR-2: bulkUpdateCurationState(_:for:) must apply state to all provided IDs in one transaction
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)

        // Insert 3 test PhotoAssets
        var ids: [String] = []
        for i in 1...3 {
            var asset = PhotoAsset.new(canonicalName: "test-\(i).dng", role: .original, filePath: "/tmp/test-\(i).dng", fileSize: 1000)
            try await photoRepo.upsert(asset)
            ids.append(asset.id)
        }

        // Bulk update 2 of them to archive
        try await photoRepo.bulkUpdateCurationState(ids: Set(ids.prefix(2)), state: .archive)

        // Verify updates
        let p1 = try await photoRepo.fetchById(ids[0])
        let p2 = try await photoRepo.fetchById(ids[1])
        let p3 = try await photoRepo.fetchById(ids[2])

        #expect(p1?.curationState == CurationState.archive.rawValue)
        #expect(p2?.curationState == CurationState.archive.rawValue)
        #expect(p3?.curationState == CurationState.needsReview.rawValue)
    }

    @Test
    func testCurationCountsReturnsCorrectTotals() async throws {
        // CUR-5: curationCounts() must return correct per-state totals from photo_assets
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)

        // Insert 2 keepers, 1 archive
        // First insert with default state (needsReview), then update states
        var keeper1 = PhotoAsset.new(canonicalName: "keeper1.dng", role: .original, filePath: "/tmp/keeper1.dng", fileSize: 1000)
        var keeper2 = PhotoAsset.new(canonicalName: "keeper2.dng", role: .original, filePath: "/tmp/keeper2.dng", fileSize: 1000)
        var archive1 = PhotoAsset.new(canonicalName: "archive1.dng", role: .original, filePath: "/tmp/archive1.dng", fileSize: 1000)

        try await photoRepo.upsert(keeper1)
        try await photoRepo.upsert(keeper2)
        try await photoRepo.upsert(archive1)

        // Update curation states
        try await photoRepo.updateCurationState(id: keeper1.id, state: .keeper)
        try await photoRepo.updateCurationState(id: keeper2.id, state: .keeper)
        try await photoRepo.updateCurationState(id: archive1.id, state: .archive)

        // Fetch counts
        let counts = try await photoRepo.curationCounts()

        #expect(counts.keeper == 2)
        #expect(counts.archive == 1)
        #expect(counts.needsReview == 0)
        #expect(counts.rejected == 0)
    }
}
