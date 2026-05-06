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

    // MARK: - Face-indexing pipeline

    @Test
    func testMarkFaceIndexedSetsTimestamp() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        var asset = PhotoAsset.new(canonicalName: "faces.dng", role: .original,
                                   filePath: "/faces.dng", fileSize: 0)
        asset.processingState = ProcessingState.proxyReady.rawValue
        try await repo.upsert(asset)

        #expect((try await repo.fetchById(asset.id))?.faceIndexedAt == nil,
                "face_indexed_at must be nil before markFaceIndexed")

        try await repo.markFaceIndexed(id: asset.id)

        let updated = try await repo.fetchById(asset.id)
        #expect(updated?.faceIndexedAt != nil, "markFaceIndexed must set face_indexed_at")
    }

    @Test
    func testClearAllFaceIndexedNullsTimestamps() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        for name in ["clear_a.dng", "clear_b.dng"] {
            var asset = PhotoAsset.new(canonicalName: name, role: .original,
                                       filePath: "/\(name)", fileSize: 0)
            asset.processingState = ProcessingState.proxyReady.rawValue
            try await repo.upsert(asset)
            try await repo.markFaceIndexed(id: asset.id)
        }

        try await repo.clearAllFaceIndexed()

        for name in ["clear_a.dng", "clear_b.dng"] {
            let row = try await repo.fetchByCanonicalName(name)
            #expect(row?.faceIndexedAt == nil, "\(name) face_indexed_at must be NULL after clearAllFaceIndexed")
        }
    }

    @Test
    func testFetchNeedingFaceIndexReturnsOnlyProxyReadyWithNilTimestamp() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        // proxyReady + face_indexed_at IS NULL → should appear
        var unindexed = PhotoAsset.new(canonicalName: "unindexed.dng", role: .original,
                                        filePath: "/unindexed.dng", fileSize: 0)
        unindexed.processingState = ProcessingState.proxyReady.rawValue
        try await repo.upsert(unindexed)

        // proxyReady but already indexed → must NOT appear
        var indexed = PhotoAsset.new(canonicalName: "indexed.dng", role: .original,
                                      filePath: "/indexed.dng", fileSize: 0)
        indexed.processingState = ProcessingState.proxyReady.rawValue
        try await repo.upsert(indexed)
        try await repo.markFaceIndexed(id: indexed.id)

        // proxyPending (wrong state) → must NOT appear
        let pending = PhotoAsset.new(canonicalName: "pending.dng", role: .original,
                                     filePath: "/pending.dng", fileSize: 0)
        try await repo.upsert(pending)

        let needing = try await repo.fetchNeedingFaceIndex()
        #expect(needing.count == 1, "fetchNeedingFaceIndex must return only proxyReady + nil face_indexed_at")
        #expect(needing.first?.canonicalName == "unindexed.dng")
    }

    // MARK: - stampProxyFields

    @Test
    func testStampProxyFieldsSetsProxyPath() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let asset = PhotoAsset.new(canonicalName: "stamp.dng", role: .original,
                                   filePath: "/stamp.dng", fileSize: 0)
        try await repo.upsert(asset)

        try await repo.stampProxyFields(
            id: asset.id,
            proxyPath: "/proxies/stamp.jpg",
            sourceDriveUUID: "DRIVE-001",
            sourceDrivePath: "/Volumes/Drive/stamp.dng"
        )

        let updated = try await repo.fetchById(asset.id)
        #expect(updated?.proxyPath == "/proxies/stamp.jpg", "stampProxyFields must set proxy_path")
        #expect(updated?.sourceDriveUUID == "DRIVE-001", "stampProxyFields must set source_drive_uuid")
    }
}
