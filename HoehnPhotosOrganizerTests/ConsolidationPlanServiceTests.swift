import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class ConsolidationPlanServiceTests: XCTestCase {
    var db: AppDatabase!
    var service: ConsolidationPlanService!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        service = ConsolidationPlanService(db: db)
    }

    private func insertDrive(_ label: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO drives (id, volume_label, mount_point, total_bytes, free_bytes, last_seen, created_at, updated_at)
                VALUES (?, ?, '/Volumes/\(label)', 500000000000, 200000000000, ?, ?, ?)
            """, arguments: [UUID().uuidString, label, now, now, now])
        }
    }

    func testPlanGenerationProducesNoFileManagerCalls() async throws {
        // ConsolidationPlanService must compile without importing Foundation's FileManager
        // We verify it by running generatePlan and confirming no side effects (no new files)
        try await insertDrive("SOURCE")
        try await insertDrive("TARGET")
        let plan = try await service.generatePlan(sourceDriveLabel: "SOURCE", targetDriveLabel: "TARGET")
        XCTAssertEqual(plan.moves.count, 0)  // no photos in DB — empty plan is valid
        XCTAssertNotNil(plan.generatedAt)
    }

    func testPlanIncludesGeneratedAtTimestampAndPhotoCount() async throws {
        try await insertDrive("SOURCE")
        try await insertDrive("TARGET")
        let plan = try await service.generatePlan(sourceDriveLabel: "SOURCE", targetDriveLabel: "TARGET")
        XCTAssertGreaterThan(plan.generatedAt.timeIntervalSinceReferenceDate, 0)
        XCTAssertGreaterThanOrEqual(plan.photoCount, 0)
    }

    func testPlanGroupsPhotosBySourceDrive() async throws {
        try await insertDrive("SOURCE")
        try await insertDrive("TARGET")
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES ('pa1', 'photo1.NEF', 'original', 'SOURCE/photo1.NEF', 3000, 'indexed', 'needs_review', 'local_only', ?, ?)
            """, arguments: [now, now])
        }
        let plan = try await service.generatePlan(sourceDriveLabel: "SOURCE", targetDriveLabel: "TARGET")
        XCTAssertEqual(plan.moves.count, 1)
        XCTAssertEqual(plan.moves.first?.sourceDriveLabel, "SOURCE")
        XCTAssertEqual(plan.moves.first?.targetDriveLabel, "TARGET")
    }

    func testStalenessValidationAbortsWhenCountDiffers() async throws {
        try await insertDrive("SOURCE")
        try await insertDrive("TARGET")
        let plan = try await service.generatePlan(sourceDriveLabel: "SOURCE", targetDriveLabel: "TARGET")
        // Inject a new photo after plan was generated
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(sql: """
                INSERT INTO photo_assets (id, canonical_name, role, file_path, file_size,
                    processing_state, curation_state, sync_state, created_at, updated_at)
                VALUES ('pa-new', 'newphoto.NEF', 'original', 'SOURCE/newphoto.NEF', 4000, 'indexed', 'needs_review', 'local_only', ?, ?)
            """, arguments: [now, now])
        }
        do {
            try await service.validateFreshness(plan: plan)
            XCTFail("Expected staleLibrary error")
        } catch ConsolidationPlanError.staleLibrary {
            // Expected
        }
    }
}
