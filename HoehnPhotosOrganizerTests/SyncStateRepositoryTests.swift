import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct SyncStateRepositoryTests {

    // MARK: - test_getLastSyncTimestamp_defaultsToZero

    @Test
    func test_getLastSyncTimestamp_defaultsToZero() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = SyncStateRepository(db: db)

        let ts = try await repo.getLastSyncTimestamp()
        #expect(ts == 0, "Fresh DB must return 0 for lastSyncTimestamp")
    }

    // MARK: - test_setAndGetLastSyncTimestamp_roundTrip

    @Test
    func test_setAndGetLastSyncTimestamp_roundTrip() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = SyncStateRepository(db: db)

        try await repo.setLastSyncTimestamp(1_711_000_000)
        let ts = try await repo.getLastSyncTimestamp()
        #expect(ts == 1_711_000_000, "getLastSyncTimestamp must return the value set by setLastSyncTimestamp")
    }

    @Test
    func test_setLastSyncTimestamp_overwritesPreviousValue() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = SyncStateRepository(db: db)

        try await repo.setLastSyncTimestamp(1_000_000)
        try await repo.setLastSyncTimestamp(2_000_000)
        let ts = try await repo.getLastSyncTimestamp()
        #expect(ts == 2_000_000, "Second set must overwrite the first")
    }

    // MARK: - test_updatePhotoSyncStatus_setsStatusAndError

    @Test
    func test_updatePhotoSyncStatus_setsStatusAndError() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = SyncStateRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        let asset = PhotoAsset.new(canonicalName: "sync_error.dng", role: .original,
                                   filePath: "/sync_error.dng", fileSize: 0)
        try await photoRepo.upsert(asset)

        try await repo.updatePhotoSyncStatus(
            canonicalId: "sync_error.dng",
            status: "error",
            error: "Network timeout"
        )

        // Read back via raw SQL since PhotoAsset.CodingKeys doesn't map sync_status/sync_error
        let row = try await db.dbPool.read { conn in
            try Row.fetchOne(conn,
                sql: "SELECT sync_status, sync_error FROM photo_assets WHERE canonical_name = ?",
                arguments: ["sync_error.dng"])
        }
        #expect((row?["sync_status"] as String?) == "error", "sync_status must be set to 'error'")
        #expect((row?["sync_error"] as String?) == "Network timeout", "sync_error must hold the error message")
    }

    // MARK: - test_getPhotosModifiedSince_returnsOnlyNewer

    @Test
    func test_getPhotosModifiedSince_returnsOnlyNewer() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = SyncStateRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        // Insert 3 photos then backdate their updated_at so we can control ordering
        let names = ["oldest.dng", "middle.dng", "newest.dng"]
        let dates = ["2024-01-01T00:00:00Z", "2024-06-01T00:00:00Z", "2024-12-01T00:00:00Z"]

        for (name, date) in zip(names, dates) {
            let asset = PhotoAsset.new(canonicalName: name, role: .original,
                                       filePath: "/\(name)", fileSize: 0)
            try await photoRepo.upsert(asset)
            try await db.dbPool.write { conn in
                try conn.execute(
                    sql: "UPDATE photo_assets SET updated_at = ? WHERE canonical_name = ?",
                    arguments: [date, name]
                )
            }
        }

        // 2024-06-01 in epoch seconds
        let middleTimestamp: Int64 = 1_717_200_000

        let results = try await repo.getPhotosModifiedSince(middleTimestamp)
        let resultNames = Set(results.map(\.canonicalName))
        #expect(!resultNames.contains("oldest.dng"), "Oldest photo must not appear (predates cutoff)")
        #expect(!resultNames.contains("middle.dng"), "Middle photo must not appear (equals cutoff; filter is >)")
        #expect(resultNames.contains("newest.dng"), "Newest photo must appear (postdates cutoff)")
    }

    // MARK: - test_syncStatusCounts_groupsByStatus

    @Test
    func test_syncStatusCounts_groupsByStatus() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = SyncStateRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        // Insert 5 photos (default sync_status = "localOnly") + set 2 to "synced"
        for i in 1...5 {
            let asset = PhotoAsset.new(canonicalName: "cnt_\(i).dng", role: .original,
                                       filePath: "/cnt_\(i).dng", fileSize: 0)
            try await photoRepo.upsert(asset)
        }
        for i in 1...2 {
            try await repo.updatePhotoSyncStatus(canonicalId: "cnt_\(i).dng", status: "synced")
        }

        let counts = try await repo.syncStatusCounts()
        #expect((counts["localOnly"] ?? 0) == 3, "3 photos must remain localOnly")
        #expect((counts["synced"] ?? 0) == 2, "2 photos must be synced")
    }

    // MARK: - test_photosWithSyncErrors_filtersCorrectly

    @Test
    func test_photosWithSyncErrors_filtersCorrectly() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = SyncStateRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        // 2 error + 3 localOnly
        for i in 1...5 {
            let asset = PhotoAsset.new(canonicalName: "err_\(i).dng", role: .original,
                                       filePath: "/err_\(i).dng", fileSize: 0)
            try await photoRepo.upsert(asset)
        }
        for i in 1...2 {
            try await repo.updatePhotoSyncStatus(
                canonicalId: "err_\(i).dng",
                status: "error",
                error: "Upload failed"
            )
        }

        let errors = try await repo.photosWithSyncErrors()
        #expect(errors.count == 2, "photosWithSyncErrors must return only the 2 error photos")
    }
}
