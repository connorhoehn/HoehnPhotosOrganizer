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

    // MARK: - ING-4: Pre-fetch Set skips already-processed files at O(1)

    @Test
    func testPreFetchSetSkipsAlreadyProcessedFiles() async throws {
        // ING-4 (optimised path): fetchAlreadyIndexedNames() pre-fetches a Set<String>
        // before the file loop. Files whose canonical names are in the set are skipped
        // without per-file DB reads.
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let driveRepo = DriveRepository(db: db)

        // Pre-seed two files past indexed state
        for name in ["SKIP_A.dng", "SKIP_B.dng"] {
            var asset = PhotoAsset.new(
                canonicalName: name,
                role: .original,
                filePath: "/\(name)",
                fileSize: 1_000_000
            )
            asset.processingState = ProcessingState.proxyPending.rawValue
            try await photoRepo.upsert(asset)
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-prefetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Place both seeded files + one brand-new file on the "drive"
        for name in ["SKIP_A.dng", "SKIP_B.dng", "NEW.dng"] {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }

        let drive = DriveInfo(
            volumeLabel: "PrefetchTestDrive",
            mountPoint: tempDir,
            totalBytes: 100_000_000,
            freeBytes: 50_000_000,
            volumeUUID: UUID().uuidString
        )

        let actor = IngestionActor(photoRepo: photoRepo, driveRepo: driveRepo)
        var finalEvent: IngestionProgress?
        for await progress in actor.startIngestion(drive: drive) {
            finalEvent = progress
        }

        // Skipped files must not count as failures
        #expect(finalEvent?.failedFiles == 0, "Skipped files must not count as failures")

        // Already-processed files must retain their state (not be reset to indexed)
        let skipA = try await photoRepo.fetchByCanonicalName("SKIP_A.dng")
        let skipB = try await photoRepo.fetchByCanonicalName("SKIP_B.dng")
        #expect(skipA?.processingState == ProcessingState.proxyPending.rawValue,
                "SKIP_A must remain in proxyPending — pre-fetch Set skipped re-processing it")
        #expect(skipB?.processingState == ProcessingState.proxyPending.rawValue,
                "SKIP_B must remain in proxyPending — pre-fetch Set skipped re-processing it")

        // The new file must have been indexed
        let newFile = try await photoRepo.fetchByCanonicalName("NEW.dng")
        #expect(newFile != nil, "NEW.dng must be indexed on first scan")
        #expect(newFile?.processingState == ProcessingState.proxyPending.rawValue,
                "NEW.dng must advance to proxyPending after ingestion")
    }

    // MARK: - deduplicateRawJpgPairs

    private func url(_ filename: String) -> URL {
        URL(fileURLWithPath: "/fake/\(filename)")
    }

    @Test
    func testRawJpgPairKeepsRawWithCompanion() {
        // IMG_0001.dng + IMG_0001.jpg → single entry, url=dng, jpgCompanion=jpg
        let inputs = [url("IMG_0001.dng"), url("IMG_0001.jpg")]
        let result = IngestionActor.deduplicateRawJpgPairs(inputs)
        #expect(result.count == 1, "RAW+JPG pair must produce one entry")
        #expect(result[0].url.lastPathComponent == "IMG_0001.dng")
        #expect(result[0].jpgCompanion?.lastPathComponent == "IMG_0001.jpg")
    }

    @Test
    func testJpgOnlyProducesEntryWithNoCompanion() {
        let inputs = [url("IMG_0002.jpg")]
        let result = IngestionActor.deduplicateRawJpgPairs(inputs)
        #expect(result.count == 1, "JPG-only must produce one entry")
        #expect(result[0].url.lastPathComponent == "IMG_0002.jpg")
        #expect(result[0].jpgCompanion == nil, "No companion when there is no RAW")
    }

    @Test
    func testRawOnlyProducesEntryWithNoCompanion() {
        let inputs = [url("IMG_0003.arw")]
        let result = IngestionActor.deduplicateRawJpgPairs(inputs)
        #expect(result.count == 1, "RAW-only must produce one entry")
        #expect(result[0].url.lastPathComponent == "IMG_0003.arw")
        #expect(result[0].jpgCompanion == nil)
    }

    @Test
    func testMultipleRawsSameStemProduceMultipleEntries() {
        // Edge case: camera wrote both DNG + CR3 with same stem (unlikely but possible)
        let inputs = [url("MULTI.dng"), url("MULTI.cr3"), url("MULTI.jpg")]
        let result = IngestionActor.deduplicateRawJpgPairs(inputs)
        #expect(result.count == 2, "Two RAWs same stem must produce two entries")
        // One of them gets the JPG companion; the other does not
        let withCompanion = result.filter { $0.jpgCompanion != nil }
        #expect(withCompanion.count == 1, "Exactly one RAW entry receives the JPG companion")
        // The standalone JPG must NOT appear as a top-level entry
        let jpgEntries = result.filter { $0.url.pathExtension.lowercased() == "jpg" }
        #expect(jpgEntries.isEmpty, "JPG must not appear as a top-level entry when a RAW exists")
    }

    @Test
    func testStemMatchingIsCaseInsensitive() {
        // Camera writes IMG_0001.DNG + IMG_0001.JPG (uppercase extensions)
        let inputs = [url("IMG_0001.DNG"), url("IMG_0001.JPG")]
        let result = IngestionActor.deduplicateRawJpgPairs(inputs)
        #expect(result.count == 1, "Uppercase extensions must still be treated as a RAW+JPG pair")
        let jpgAsTopLevel = result.filter { $0.url.pathExtension.uppercased() == "JPG" }
        #expect(jpgAsTopLevel.isEmpty, "JPG must not appear as a top-level entry even with uppercase extension")
    }

    @Test
    func testDifferentStemsProduceIndependentEntries() {
        // ABC.dng and XYZ.jpg have different stems — must not be paired
        let inputs = [url("ABC.dng"), url("XYZ.jpg")]
        let result = IngestionActor.deduplicateRawJpgPairs(inputs)
        #expect(result.count == 2, "Different stems must each produce their own entry")
        let abcEntry = result.first { $0.url.lastPathComponent == "ABC.dng" }
        let xyzEntry = result.first { $0.url.lastPathComponent == "XYZ.jpg" }
        #expect(abcEntry != nil, "ABC.dng must be present")
        #expect(xyzEntry != nil, "XYZ.jpg must be present")
        #expect(abcEntry?.jpgCompanion == nil, "ABC.dng must not pick up XYZ.jpg as companion")
    }

    // MARK: - Batch flush: multiple files land in DB via bulkUpsert path

    @Test
    func testBatchFlushLandsAllFilesInDB() async throws {
        // Verify that assets accumulated in the pending batch are all committed to GRDB.
        // Uses 3 files — well under batchSize (250) — so the end-of-scan flush is exercised.
        let db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let driveRepo = DriveRepository(db: db)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-batchflush-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let names = ["A.dng", "B.jpg", "C.tiff"]
        for name in names {
            try Data().write(to: tempDir.appendingPathComponent(name))
        }

        let drive = DriveInfo(
            volumeLabel: "FlushTestDrive",
            mountPoint: tempDir,
            totalBytes: 100_000_000,
            freeBytes: 50_000_000,
            volumeUUID: UUID().uuidString
        )

        let actor = IngestionActor(photoRepo: photoRepo, driveRepo: driveRepo)
        for await _ in actor.startIngestion(drive: drive) { /* consume stream */ }

        for name in names {
            let row = try await photoRepo.fetchByCanonicalName(name)
            #expect(row != nil, "\(name) must be in DB after batch flush")
            #expect(row?.processingState == ProcessingState.proxyPending.rawValue,
                    "\(name) should be in proxyPending after ingestion")
        }
    }
}
