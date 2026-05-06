import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct SyncStatusViewModelTests {

    // MARK: - Helpers

    private func seedPhoto(canonicalName: String, in db: AppDatabase) async throws {
        let asset = PhotoAsset.new(
            canonicalName: canonicalName,
            role: .original,
            filePath: "/tmp/\(canonicalName)",
            fileSize: 1024
        )
        try await PhotoRepository(db: db).bulkUpsert([asset])
    }

    private func writeSyncStatus(_ status: SyncStatus, canonicalName: String, in db: AppDatabase) async throws {
        let json = String(data: try JSONEncoder().encode(status), encoding: .utf8)!
        try await db.dbPool.write { d in
            try d.execute(
                sql: "UPDATE photo_assets SET sync_status = ? WHERE canonical_name = ?",
                arguments: [json, canonicalName]
            )
        }
    }

    // MARK: - Tests

    @MainActor @Test
    func test_syncStatus_localOnly() async throws {
        // Newly inserted photo has default sync_status = "localOnly" (string, not JSON).
        // SyncStatusViewModel falls back to .localOnly when JSON decode fails.
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(canonicalName: "local.dng", in: db)

        let vm = SyncStatusViewModel(db: db)
        vm.observeSyncStatus(for: "local.dng")
        // .scheduling: .immediate fires synchronously on subscription
        #expect(vm.syncStatus == .localOnly)
    }

    @MainActor @Test
    func test_syncStatus_syncing() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(canonicalName: "syncing.dng", in: db)
        try await writeSyncStatus(.syncing(progress: 0.42), canonicalName: "syncing.dng", in: db)

        let vm = SyncStatusViewModel(db: db)
        vm.observeSyncStatus(for: "syncing.dng")
        #expect(vm.syncStatus == .syncing(progress: 0.42))
    }

    @MainActor @Test
    func test_syncStatus_synced() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(canonicalName: "synced.dng", in: db)
        let syncedDate = Date(timeIntervalSince1970: 1710595200)
        try await writeSyncStatus(.synced(timestamp: syncedDate), canonicalName: "synced.dng", in: db)

        let vm = SyncStatusViewModel(db: db)
        vm.observeSyncStatus(for: "synced.dng")
        #expect(vm.syncStatus == .synced(timestamp: syncedDate))
    }

    @MainActor @Test
    func test_syncStatus_error() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(canonicalName: "error.dng", in: db)
        try await writeSyncStatus(.error(reason: "Network timeout"), canonicalName: "error.dng", in: db)

        let vm = SyncStatusViewModel(db: db)
        vm.observeSyncStatus(for: "error.dng")
        #expect(vm.syncStatus == .error(reason: "Network timeout"))
    }

    @MainActor @Test
    func test_syncStatus_persistence() async throws {
        // Status written to DB survives ViewModel recreation (simulates app restart).
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(canonicalName: "persist.dng", in: db)
        try await writeSyncStatus(.syncing(progress: 0.9), canonicalName: "persist.dng", in: db)

        let vm1 = SyncStatusViewModel(db: db)
        vm1.observeSyncStatus(for: "persist.dng")
        let firstStatus = vm1.syncStatus

        // Simulate re-creation from the same underlying DB
        let vm2 = SyncStatusViewModel(db: db)
        vm2.observeSyncStatus(for: "persist.dng")
        #expect(vm2.syncStatus == firstStatus)
        #expect(vm2.syncStatus == .syncing(progress: 0.9))
    }
}
