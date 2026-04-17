import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class FilmScanIngestionServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Creates a minimal FilmStripExtractionResult for testing.
    /// The `exportedURLs` are real (zero-byte) temporary files so that
    /// `resourceValues(.fileSizeKey)` resolves without error.
    private func makeExtractionResult(
        exportedURLs: [URL],
        sourceURL: URL = URL(fileURLWithPath: "/tmp/test_scan.tif")
    ) -> FilmStripExtractionResult {
        FilmStripExtractionResult(
            sourceURL: sourceURL,
            frameRects: [],
            exportedURLs: exportedURLs,
            trimResults: [],
            lineageManifestURL: nil,
            toolRuns: []
        )
    }

    /// Creates `count` zero-byte temp files and returns their URLs.
    /// Caller is responsible for cleanup (or rely on OS tmp cleanup).
    private func makeTempFrameURLs(count: Int, baseName: String = "frame") -> [URL] {
        let tempDir = FileManager.default.temporaryDirectory
        return (1...count).map { index in
            let url = tempDir.appendingPathComponent("\(baseName)_\(index)_\(UUID().uuidString).tif")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            return url
        }
    }

    // MARK: - FILM-4, CP-1

    /// persist() must create exactly one photo_assets row per exported frame URL,
    /// each with role == "workflow_output".
    func testPersistCreatesPhotoAssetRowPerFrame() async throws {
        let db = try AppDatabase.makeInMemory()

        // Insert a source photo asset to satisfy the FK reference in asset_lineage.
        var source = PhotoAsset.new(
            canonicalName: "scan_source_\(UUID().uuidString).tif",
            role: .original,
            filePath: "/tmp/scan_source.tif",
            fileSize: 1_000
        )
        try await db.dbPool.write { try source.insert($0) }

        let urls = makeTempFrameURLs(count: 3, baseName: "persist_asset_test")
        let result = makeExtractionResult(exportedURLs: urls)

        try await FilmScanIngestionService().persist(
            result,
            sourcePhotoId: source.id,
            orientation: FilmStripOrientation.horizontal.rawValue,
            detectorMethod: "visionRectangles",
            batchLabel: nil,
            db: db
        )

        let assets: [PhotoAsset] = try await db.dbPool.read { database in
            try PhotoAsset
                .filter(Column("role") == PhotoRole.workflowOutput.rawValue)
                .fetchAll(database)
        }
        XCTAssertEqual(assets.count, 3, "Expected one photo_assets row per exported frame")
    }

    // MARK: - FILM-6, CP-1

    /// persist() must create exactly one asset_lineage row per frame,
    /// each linking parent (source) to child (frame asset).
    func testPersistCreatesAssetLineageRowPerFrame() async throws {
        let db = try AppDatabase.makeInMemory()

        var source = PhotoAsset.new(
            canonicalName: "scan_source_lineage_\(UUID().uuidString).tif",
            role: .original,
            filePath: "/tmp/scan_lineage.tif",
            fileSize: 1_000
        )
        try await db.dbPool.write { try source.insert($0) }

        let urls = makeTempFrameURLs(count: 3, baseName: "persist_lineage_test")
        let result = makeExtractionResult(exportedURLs: urls)

        try await FilmScanIngestionService().persist(
            result,
            sourcePhotoId: source.id,
            orientation: FilmStripOrientation.horizontal.rawValue,
            detectorMethod: "visionRectangles",
            batchLabel: nil,
            db: db
        )

        let lineageRows: [AssetLineage] = try await db.dbPool.read { database in
            try AssetLineage.fetchAll(database)
        }
        XCTAssertEqual(lineageRows.count, 3, "Expected one asset_lineage row per exported frame")

        // Every lineage row should point back to the source photo as the parent.
        for row in lineageRows {
            XCTAssertEqual(row.parentPhotoId, source.id)
            XCTAssertEqual(row.operation, "film_strip_extract")
        }
    }

    // MARK: - FILM-6

    /// persist() must create exactly one extraction_events row for the batch.
    func testPersistCreatesExtractionEventRow() async throws {
        let db = try AppDatabase.makeInMemory()

        var source = PhotoAsset.new(
            canonicalName: "scan_source_event_\(UUID().uuidString).tif",
            role: .original,
            filePath: "/tmp/scan_event.tif",
            fileSize: 1_000
        )
        try await db.dbPool.write { try source.insert($0) }

        let urls = makeTempFrameURLs(count: 4, baseName: "persist_event_test")
        let result = makeExtractionResult(
            exportedURLs: urls,
            sourceURL: URL(fileURLWithPath: "/tmp/scan_event.tif")
        )

        try await FilmScanIngestionService().persist(
            result,
            sourcePhotoId: source.id,
            orientation: FilmStripOrientation.vertical.rawValue,
            detectorMethod: "projection",
            batchLabel: nil,
            db: db
        )

        let events: [ExtractionEvent] = try await db.dbPool.read { database in
            try ExtractionEvent.fetchAll(database)
        }
        XCTAssertEqual(events.count, 1, "Expected exactly one extraction_events row for the batch")

        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.frameCount, 4)
        XCTAssertEqual(event.orientation, FilmStripOrientation.vertical.rawValue)
        XCTAssertEqual(event.detectorMethod, "projection")
        XCTAssertEqual(event.sourcePhotoId, source.id)
    }

    // MARK: - FILM-5

    /// When batchLabel is provided, asset_lineage.metadata_json must contain the label.
    func testPersistWithBatchLabelStoresBatchLabelInMetadata() async throws {
        let db = try AppDatabase.makeInMemory()

        var source = PhotoAsset.new(
            canonicalName: "scan_source_label_\(UUID().uuidString).tif",
            role: .original,
            filePath: "/tmp/scan_label.tif",
            fileSize: 1_000
        )
        try await db.dbPool.write { try source.insert($0) }

        let urls = makeTempFrameURLs(count: 2, baseName: "persist_label_test")
        let result = makeExtractionResult(exportedURLs: urls)

        try await FilmScanIngestionService().persist(
            result,
            sourcePhotoId: source.id,
            orientation: FilmStripOrientation.horizontal.rawValue,
            detectorMethod: "visionContours",
            batchLabel: "Roll-42",
            db: db
        )

        let lineageRows: [AssetLineage] = try await db.dbPool.read { database in
            try AssetLineage.fetchAll(database)
        }
        XCTAssertEqual(lineageRows.count, 2)

        for row in lineageRows {
            let json = try XCTUnwrap(row.metadataJson, "metadataJson should not be nil when batchLabel is provided")
            XCTAssertTrue(json.contains("Roll-42"), "metadataJson should contain the batch label, got: \(json)")
        }
    }

    // MARK: - FILM-4: atomic failure

    /// Atomicity test — requires mock DB injection to trigger a mid-transaction
    /// error. Deferred until dependency injection is added to FilmScanIngestionService.
    func testPersistIsAtomicOnPartialFailure() throws {
        throw XCTSkip("Wave 4 — FILM-4 atomicity test requires mock DB injection, deferred")
    }
}
