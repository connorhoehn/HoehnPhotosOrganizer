import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

// MARK: - SavedSearchRepositoryTests
// Requirement: SRCH-7 — Smart albums / saved searches with SQL predicate persistence

final class SavedSearchRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repo: SavedSearchRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = SavedSearchRepository(db: db)
    }

    override func tearDown() async throws {
        db = nil
        repo = nil
    }

    // SRCH-7: Creating a saved search persists a SavedSearchRule row with the generated SQL predicate
    func testCreateSavedSearch_storesRule_withSQLPredicate() async throws {
        var filter = SearchFilter()
        filter.sceneType = "landscape"
        filter.peopleDetected = false

        let rule = try await repo.createSavedSearch(name: "Landscapes No People", filters: filter)

        XCTAssertEqual(rule.name, "Landscapes No People")
        XCTAssertFalse(rule.sqlPredicate.isEmpty)
        XCTAssertTrue(rule.sqlPredicate.contains("scene_type"), "Predicate should include scene_type condition")
        XCTAssertTrue(rule.sqlPredicate.contains("people_detected"), "Predicate should include people_detected condition")

        // Verify stored in DB
        let all = try await repo.fetchAllSavedSearches()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].id, rule.id)
    }

    // SRCH-7: Executing a saved search against the photo_assets table returns matching photos
    func testExecuteSavedSearch_returns_matchingPhotos() async throws {
        // Insert test photo assets
        let landscapeNoPersonId = UUID().uuidString
        let landscapeWithPersonId = UUID().uuidString
        let portraitId = UUID().uuidString

        try await db.dbPool.write { conn in
            let now = ISO8601DateFormatter().string(from: .now)
            try conn.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size, processing_state,
                    curation_state, sync_state, created_at, updated_at, scene_type, people_detected)
                VALUES (?, ?, 'original', '/test/landscape1.jpg', 1000, 'indexed', 'needs_review', 'local_only', ?, ?, 'landscape', 0),
                       (?, ?, 'original', '/test/landscape2.jpg', 1000, 'indexed', 'needs_review', 'local_only', ?, ?, 'landscape', 1),
                       (?, ?, 'original', '/test/portrait1.jpg', 1000, 'indexed', 'needs_review', 'local_only', ?, ?, 'portrait', 1)
            """, arguments: [
                landscapeNoPersonId, "landscape1.jpg", now, now,
                landscapeWithPersonId, "landscape2.jpg", now, now,
                portraitId, "portrait1.jpg", now, now
            ])
        }

        var filter = SearchFilter()
        filter.sceneType = "landscape"
        filter.peopleDetected = false

        let rule = try await repo.createSavedSearch(name: "Landscapes No People", filters: filter)
        let results = try await repo.executeSavedSearch(ruleId: rule.id)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, landscapeNoPersonId)
    }

    // SRCH-7: A saved search rule with a date range generates a WHERE clause with BETWEEN
    func testSavedSearchRule_withDateRange_sqlPredicateGenerated() async throws {
        var filter = SearchFilter()
        filter.yearFrom = 2024
        filter.yearTo = 2024

        let rule = try await repo.createSavedSearch(name: "2024 Photos", filters: filter)

        XCTAssertTrue(
            rule.sqlPredicate.contains("2024"),
            "Predicate should reference year 2024. Got: \(rule.sqlPredicate)"
        )
        XCTAssertTrue(
            rule.sqlPredicate.lowercased().contains("capture_date") ||
            rule.sqlPredicate.lowercased().contains("created_at"),
            "Predicate should reference a date column. Got: \(rule.sqlPredicate)"
        )
    }

    // SRCH-7: A saved search rule filtering by scene type generates a WHERE clause on scene_type column
    func testSavedSearchRule_withSceneType_sqlPredicateGenerated() async throws {
        var filter = SearchFilter()
        filter.sceneType = "landscape"

        let rule = try await repo.createSavedSearch(name: "Landscapes", filters: filter)

        XCTAssertTrue(
            rule.sqlPredicate.contains("scene_type"),
            "Predicate should contain scene_type. Got: \(rule.sqlPredicate)"
        )
        XCTAssertTrue(
            rule.sqlPredicate.contains("landscape"),
            "Predicate should contain 'landscape'. Got: \(rule.sqlPredicate)"
        )
    }
}
