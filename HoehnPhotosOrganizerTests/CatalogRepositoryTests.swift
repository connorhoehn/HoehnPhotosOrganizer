import Foundation
import Testing
@testable import HoehnPhotosOrganizer

struct CatalogRepositoryTests {

    // MARK: - ING-2: UNIQUE constraint on canonical_name

    @Test func testNoDuplicateInsertByCanonicalName() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let first = PhotoAsset.new(
            canonicalName: "DSC_0001.ARW",
            role: .original,
            filePath: "/Volumes/TestDrive/DSC_0001.ARW",
            fileSize: 24_000_000
        )
        try await repo.upsert(first)

        // Insert second record with same canonical_name — must not create a second row
        let second = PhotoAsset.new(
            canonicalName: "DSC_0001.ARW",
            role: .original,
            filePath: "/Volumes/TestDrive/DSC_0001.ARW",
            fileSize: 24_000_000
        )
        try await repo.upsert(second)

        // Verify only one row exists
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
    }

    // MARK: - ING-5: Second upsert returns same canonical record (no duplication)

    @Test func testDuplicateCanonicalNameReturnsSameRecord() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let original = PhotoAsset.new(
            canonicalName: "L1004821.DNG",
            role: .original,
            filePath: "/Volumes/TravelArchive/L1004821.DNG",
            fileSize: 30_000_000
        )
        try await repo.upsert(original)

        // Fetch and verify
        let found = try await repo.fetchByCanonicalName("L1004821.DNG")
        #expect(found != nil)
        #expect(found?.canonicalName == "L1004821.DNG")

        // Upsert again (simulating resume scenario)
        var updated = original
        updated.processingState = ProcessingState.proxyReady.rawValue
        try await repo.upsert(updated)

        // Still only one row, but updated
        let all = try await repo.fetchAll()
        #expect(all.count == 1)
        #expect(all.first?.processingState == ProcessingState.proxyReady.rawValue)
    }

    // MARK: - fetchByCanonicalName returns nil when not found

    @Test func testFetchByCanonicalNameReturnsNilWhenMissing() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let result = try await repo.fetchByCanonicalName("NONEXISTENT.DNG")
        #expect(result == nil)
    }

    // MARK: - fetchById returns correct record

    @Test func testFetchById() async throws {
        let db = try AppDatabase.makeInMemory()
        let repo = PhotoRepository(db: db)

        let asset = PhotoAsset.new(
            canonicalName: "TEST_001.CR3",
            role: .original,
            filePath: "/Volumes/Camera/TEST_001.CR3",
            fileSize: 40_000_000
        )
        try await repo.upsert(asset)

        let found = try await repo.fetchById(asset.id)
        #expect(found?.id == asset.id)
        #expect(found?.canonicalName == "TEST_001.CR3")
    }

    // MARK: - DriveRepository: upsert and fetch

    @Test func testDriveRepositoryUpsertAndFetch() async throws {
        let db = try AppDatabase.makeInMemory()
        let driveRepo = DriveRepository(db: db)

        let now = ISO8601DateFormatter().string(from: .now)
        let drive = DriveDB(
            id: UUID().uuidString,
            volumeLabel: "TravelArchive-01",
            mountPoint: "/Volumes/TravelArchive-01",
            totalBytes: 4_000_000_000_000,
            freeBytes: 1_800_000_000_000,
            lastSeen: now,
            createdAt: now,
            updatedAt: now
        )
        try await driveRepo.upsert(drive)

        let found = try await driveRepo.fetchByVolumeLabel("TravelArchive-01")
        #expect(found?.volumeLabel == "TravelArchive-01")
    }
}
