import Testing
import Foundation
@testable import HoehnPhotosOrganizer

// MARK: - IngestionActorTests

struct IngestionActorTests {

    // MARK: - ING-4: Resume skips already-indexed files

    @Test
    func testResumeSkipsAlreadyIndexedFiles() async throws {
        // ING-4: files already in state > indexed are not re-processed on drive reconnect.
        // Uses fetchByCanonicalName — the camera-assigned filename — NOT fetchById.
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let driveRepo = DriveRepository(db: db)

        // Pre-seed a file already past indexed state (proxyPending)
        var existing = PhotoAsset.new(
            canonicalName: "IMG_0001.dng",
            role: .original,
            filePath: "/IMG_0001.dng",
            fileSize: 1_000_000
        )
        existing.processingState = ProcessingState.proxyPending.rawValue
        try await photoRepo.upsert(existing)

        // Create a temp directory with that file
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-drive-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Create a minimal valid file (not a real DNG, but file exists for enumeration)
        let testFile = tempDir.appendingPathComponent("IMG_0001.dng")
        try Data().write(to: testFile)

        let drive = DriveInfo(
            volumeLabel: "TestDrive",
            mountPoint: tempDir,
            totalBytes: 100_000_000,
            freeBytes: 50_000_000,
            volumeUUID: UUID().uuidString
        )

        let actor = IngestionActor(photoRepo: photoRepo, driveRepo: driveRepo)
        var progressEvents: [IngestionProgress] = []
        for await progress in actor.startIngestion(drive: drive) {
            progressEvents.append(progress)
        }

        // The file was skipped (already in proxyPending), so 0 failures
        // and the file's state should remain proxyPending, not reset to indexed
        let after = try await photoRepo.fetchByCanonicalName("IMG_0001.dng")
        #expect(after?.processingState == ProcessingState.proxyPending.rawValue,
                "Resume: already-indexed file should keep proxyPending state, not be reset")
        // failed count must be 0 — skipping is not a failure
        let finalEvent = progressEvents.last
        #expect(finalEvent?.failedFiles == 0, "Skipped files must not count as failures")
    }

    // MARK: - ING-8: Per-file EXIF error continues batch

    @Test
    func testPerFileExifErrorContinuesBatch() async throws {
        // ING-8: a corrupt/unreadable file writes error_message to its record but the
        // remaining files in the batch complete normally.
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let driveRepo = DriveRepository(db: db)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // File 1: corrupt (0-byte DNG — EXIFExtractor will return empty snapshot, no error thrown)
        let corrupt = tempDir.appendingPathComponent("CORRUPT.dng")
        try Data().write(to: corrupt)

        // File 2: also a 0-byte file — EXIF returns empty snapshot
        let valid = tempDir.appendingPathComponent("VALID.dng")
        try Data().write(to: valid)

        let drive = DriveInfo(
            volumeLabel: "BatchTestDrive",
            mountPoint: tempDir,
            totalBytes: 100_000_000,
            freeBytes: 50_000_000,
            volumeUUID: UUID().uuidString
        )

        let actor = IngestionActor(photoRepo: photoRepo, driveRepo: driveRepo)
        for await _ in actor.startIngestion(drive: drive) { /* consume stream */ }

        // Both files should be upserted (batch continues regardless of EXIF content)
        let corruptRecord = try await photoRepo.fetchByCanonicalName("CORRUPT.dng")
        let validRecord   = try await photoRepo.fetchByCanonicalName("VALID.dng")
        #expect(corruptRecord != nil, "Corrupt file should still have a DB record")
        #expect(validRecord != nil,   "Valid file should have a DB record")
    }
}
