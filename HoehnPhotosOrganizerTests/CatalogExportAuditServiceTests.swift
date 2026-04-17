import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class CatalogExportAuditServiceTests: XCTestCase {
    var db: AppDatabase!
    var service: CatalogExportAuditService!
    var tempURL: URL!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        service = CatalogExportAuditService(db: db)
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jsonl")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportWritesValidJsonLinesForPhotoAssets() async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES ('id1', 'photo.NEF', 'original', '/DRIVE/photo.NEF', 1000,
                    'indexed', 'needs_review', 'local_only', ?, ?)
            """, arguments: [now, now])
        }
        try await service.exportAll(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path), "Export file must exist")
    }

    func testExportedLinesAreEachValidJson() async throws {
        try await service.exportAll(to: tempURL)
        let content = try String(contentsOf: tempURL, encoding: .utf8)
        let lines = content.split(separator: "\n").filter { !$0.isEmpty }
        for line in lines {
            let data = Data(line.utf8)
            XCTAssertNoThrow(
                try JSONSerialization.jsonObject(with: data),
                "Each line must be valid JSON: \(line)"
            )
        }
    }

    func testExportIncludesAllDomainTables() async throws {
        try await service.exportAll(to: tempURL)
        let content = try String(contentsOf: tempURL, encoding: .utf8)
        // The final manifest line contains table names
        XCTAssertTrue(content.contains("photo_assets"), "Export must reference photo_assets table")
        XCTAssertTrue(content.contains("drives"), "Export must reference drives table")
        XCTAssertTrue(content.contains("thread_entries"), "Export must reference thread_entries table")
    }

    func testExportCompletesWithoutLoadingAllRowsIntoMemory() async throws {
        // Smoke test: export runs to completion without error on empty DB
        // Memory profiling is a manual test — this verifies no exception is thrown
        try await service.exportAll(to: tempURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
    }
}
