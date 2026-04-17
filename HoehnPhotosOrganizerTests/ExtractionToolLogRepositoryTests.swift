import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class ExtractionToolLogRepositoryTests: XCTestCase {

    // MARK: - Helpers

    private func makeDatabase() throws -> AppDatabase {
        try AppDatabase.makeInMemory()
    }

    private func makeRepo(_ appDB: AppDatabase) -> ExtractionToolLogRepository {
        ExtractionToolLogRepository(appDB.dbPool)
    }

    /// Inserts a minimal ExtractionEvent so FK constraints are satisfied when saving tool logs.
    private func insertEvent(id: String, db: AppDatabase) async throws {
        let event = ExtractionEvent(
            id: id,
            sourcePhotoId: nil,
            sourceFileName: "test_scan.tif",
            orientation: "horizontal",
            detectorMethod: "geometry",
            frameCount: 0,
            manifestPath: nil,
            createdAt: ISO8601DateFormatter().string(from: .now)
        )
        try await db.dbPool.write { database in
            try event.insert(database)
        }
    }

    private func makeToolRun(name: String, status: PipelineToolStatus = .succeeded, detail: String = "ok") -> PipelineToolRun {
        PipelineToolRun(name: name, status: status, detail: detail)
    }

    // MARK: - Tests

    /// Save 3 tool logs, fetch by extractionId — verify all rows present in correct order.
    func testSaveAndFetchRoundTrip() async throws {
        let db = try makeDatabase()
        let repo = makeRepo(db)
        let extractionId = UUID().uuidString

        try await insertEvent(id: extractionId, db: db)

        let runs: [PipelineToolRun] = [
            makeToolRun(name: "VisionRectangles", status: .succeeded, detail: "Found 4 rects"),
            makeToolRun(name: "EdgeRefine", status: .fallback, detail: "Fallback to projection"),
            makeToolRun(name: "FrameExport", status: .succeeded, detail: "Exported 4 frames")
        ]

        try await repo.save(logs: runs, extractionId: extractionId)

        let fetched = try await repo.fetch(extractionId: extractionId)
        XCTAssertEqual(fetched.count, 3)

        // Verify order is preserved (tool_order ASC)
        XCTAssertEqual(fetched[0].toolName, "VisionRectangles")
        XCTAssertEqual(fetched[0].toolOrder, 0)
        XCTAssertEqual(fetched[0].status, .succeeded)

        XCTAssertEqual(fetched[1].toolName, "EdgeRefine")
        XCTAssertEqual(fetched[1].toolOrder, 1)
        XCTAssertEqual(fetched[1].status, .fallback)

        XCTAssertEqual(fetched[2].toolName, "FrameExport")
        XCTAssertEqual(fetched[2].toolOrder, 2)
        XCTAssertEqual(fetched[2].status, .succeeded)

        // Verify extractionId FK is stored correctly
        XCTAssertTrue(fetched.allSatisfy { $0.extractionId == extractionId })
    }

    /// Save empty array — fetch returns empty (no error).
    func testSaveEmpty() async throws {
        let db = try makeDatabase()
        let repo = makeRepo(db)
        let extractionId = UUID().uuidString

        try await insertEvent(id: extractionId, db: db)

        // Should not throw
        try await repo.save(logs: [], extractionId: extractionId)

        let fetched = try await repo.fetch(extractionId: extractionId)
        XCTAssertTrue(fetched.isEmpty)
    }

    /// Fetch for nonexistent extractionId returns empty array (not an error).
    func testFetchNonexistent() async throws {
        let db = try makeDatabase()
        let repo = makeRepo(db)

        let fetched = try await repo.fetch(extractionId: UUID().uuidString)
        XCTAssertTrue(fetched.isEmpty)
    }

    /// Insert extraction event + tool logs, delete event, verify tool logs cascade-deleted.
    func testCascadeDelete() async throws {
        let db = try makeDatabase()
        let repo = makeRepo(db)
        let extractionId = UUID().uuidString

        try await insertEvent(id: extractionId, db: db)

        let runs = [
            makeToolRun(name: "VisionRectangles"),
            makeToolRun(name: "FrameExport")
        ]
        try await repo.save(logs: runs, extractionId: extractionId)

        // Verify logs are present before delete
        let before = try await repo.fetch(extractionId: extractionId)
        XCTAssertEqual(before.count, 2)

        // Delete the parent ExtractionEvent
        try await db.dbPool.write { database in
            try database.execute(
                sql: "DELETE FROM extraction_events WHERE id = ?",
                arguments: [extractionId]
            )
        }

        // Verify tool logs are cascade-deleted
        let after = try await repo.fetch(extractionId: extractionId)
        XCTAssertTrue(after.isEmpty, "Tool logs should be deleted when parent ExtractionEvent is deleted (CASCADE)")
    }
}
