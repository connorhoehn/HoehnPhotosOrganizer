import Testing
import Foundation
@testable import HoehnPhotosOrganizer

struct PhotoRepositoryTests {

    // MARK: - bulkUpsert

    @Test
    func testBulkUpsertInsertsAllAssetsInSingleTransaction() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let assets = (1...5).map { i in
            PhotoAsset.new(canonicalName: "bulk_\(i).dng", role: .original,
                           filePath: "/bulk_\(i).dng", fileSize: i * 1000)
        }
        try await repo.bulkUpsert(assets)

        for i in 1...5 {
            let row = try await repo.fetchByCanonicalName("bulk_\(i).dng")
            #expect(row != nil, "bulk_\(i).dng must be in DB after bulkUpsert")
        }
    }

    @Test
    func testBulkUpsertIsIdempotentOnConflict() async throws {
        // ON CONFLICT DO UPDATE: upserting the same canonical_name twice must not error
        // and the row count must remain 1.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let asset = PhotoAsset.new(canonicalName: "idempotent.dng", role: .original,
                                   filePath: "/idempotent.dng", fileSize: 0)
        try await repo.bulkUpsert([asset, asset])

        let count = try await repo.fetchCountByProcessingState(.indexed)
        #expect(count == 1, "Duplicate canonical_name in bulkUpsert must not create two rows")
    }

    @Test
    func testBulkUpsertWithEmptyArrayIsNoOp() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        await #expect(throws: Never.self) {
            try await repo.bulkUpsert([])
        }
        let count = try await repo.fetchCountByProcessingState(.indexed)
        #expect(count == 0)
    }

    // MARK: - fetchCountByProcessingState

    @Test
    func testFetchCountByProcessingStateCountsCorrectly() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        for i in 1...3 {
            var asset = PhotoAsset.new(canonicalName: "proxy_\(i).dng", role: .original,
                                       filePath: "/proxy_\(i).dng", fileSize: 0)
            asset.processingState = ProcessingState.proxyPending.rawValue
            try await repo.upsert(asset)
        }
        // Insert one indexed asset so we don't pick it up in the proxyPending count
        let indexed = PhotoAsset.new(canonicalName: "idx.dng", role: .original,
                                     filePath: "/idx.dng", fileSize: 0)
        try await repo.upsert(indexed)

        let count = try await repo.fetchCountByProcessingState(.proxyPending)
        #expect(count == 3, "fetchCountByProcessingState must count only proxyPending rows")
    }

    // MARK: - fetchAlreadyIndexedNames

    @Test
    func testFetchAlreadyIndexedNamesExcludesIndexedState() async throws {
        // Only assets whose processing_state != 'indexed' should appear in the result.
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        // Insert one asset in 'indexed' state (should NOT appear in result)
        let indexed = PhotoAsset.new(canonicalName: "still_indexed.dng", role: .original,
                                     filePath: "/still_indexed.dng", fileSize: 0)
        try await repo.upsert(indexed)

        // Insert one asset past indexed (should appear)
        var advanced = PhotoAsset.new(canonicalName: "past_indexed.dng", role: .original,
                                      filePath: "/past_indexed.dng", fileSize: 0)
        advanced.processingState = ProcessingState.proxyPending.rawValue
        try await repo.upsert(advanced)

        let names = try await repo.fetchAlreadyIndexedNames()
        #expect(!names.contains("still_indexed.dng"),
                "fetchAlreadyIndexedNames must exclude assets still in .indexed state")
        #expect(names.contains("past_indexed.dng"),
                "fetchAlreadyIndexedNames must include assets past .indexed state")
    }

    @Test
    func testFetchAlreadyIndexedNamesReturnsEmptySetWhenAllIndexed() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let asset = PhotoAsset.new(canonicalName: "only.dng", role: .original,
                                   filePath: "/only.dng", fileSize: 0)
        try await repo.upsert(asset)

        let names = try await repo.fetchAlreadyIndexedNames()
        #expect(names.isEmpty, "All assets are in .indexed state — result must be empty")
    }

    // MARK: - commitToLibrary

    @Test
    func testCommitToLibrarySetsImportStatusToLibrary() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let asset = PhotoAsset.new(canonicalName: "staged.dng", role: .original,
                                   filePath: "/staged.dng", fileSize: 0)
        try await repo.upsert(asset)

        try await repo.commitToLibrary(ids: [asset.id])

        let updated = try await repo.fetchById(asset.id)
        #expect(updated?.importStatus == "library",
                "commitToLibrary must set import_status to 'library'")
    }

    @Test
    func testCommitToLibraryWithEmptySetIsNoOp() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        await #expect(throws: Never.self) {
            try await repo.commitToLibrary(ids: [])
        }
    }

    @Test
    func testCommitToLibraryOnlyAffectsSpecifiedIds() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let a = PhotoAsset.new(canonicalName: "a.dng", role: .original, filePath: "/a.dng", fileSize: 0)
        let b = PhotoAsset.new(canonicalName: "b.dng", role: .original, filePath: "/b.dng", fileSize: 0)
        try await repo.upsert(a)
        try await repo.upsert(b)

        try await repo.commitToLibrary(ids: [a.id])

        let fetchedA = try await repo.fetchById(a.id)
        let fetchedB = try await repo.fetchById(b.id)
        #expect(fetchedA?.importStatus == "library", "a.dng must be promoted to library")
        #expect(fetchedB?.importStatus != "library", "b.dng must not be affected")
    }
}
