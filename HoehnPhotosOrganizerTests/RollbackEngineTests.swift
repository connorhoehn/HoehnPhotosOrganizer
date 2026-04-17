import XCTest
import GRDB
import Combine
@testable import HoehnPhotosOrganizer

final class RollbackEngineTests: XCTestCase {

    var db: AppDatabase!
    var snapshotRepo: AdjustmentSnapshotRepository!
    var activityRepo: ActivityEventRepository!
    var activityService: ActivityEventService!
    var engine: RollbackEngine!
    var testPhotoId: String!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        snapshotRepo = AdjustmentSnapshotRepository(db: db)
        activityRepo = ActivityEventRepository(db: db)
        activityService = ActivityEventService(repo: activityRepo)
        // Insert a PhotoAsset for FK satisfaction
        let photoRepo = PhotoRepository(db: db)
        let photo = PhotoAsset.new(canonicalName: "rollback-test.ARW", role: .original, filePath: "/tmp/rollback.ARW", fileSize: 1000)
        try await photoRepo.upsert(photo)
        testPhotoId = photo.id
        // RollbackEngine is @MainActor — must init on main actor
        engine = await MainActor.run {
            RollbackEngine(snapshotRepo: snapshotRepo, activityService: activityService)
        }
    }

    func testRollbackRestoresSnapshotParameters() async throws {
        let adj = PhotoAdjustments()
        let json = String(data: try JSONEncoder().encode(adj), encoding: .utf8)!
        let snapshot = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "v1",
            adjustmentJSON: json,
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date()
        )
        try await snapshotRepo.saveSnapshot(snapshot)

        try await engine.rollback(to: snapshot, photoAssetId: testPhotoId)

        let published = await MainActor.run { engine.currentAdjustment.value }
        XCTAssertNotNil(published)
    }

    func testRollbackEmitsRollbackActivityEvent() async throws {
        let adj = PhotoAdjustments()
        let json = String(data: try JSONEncoder().encode(adj), encoding: .utf8)!
        let snapshot = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "v1",
            adjustmentJSON: json,
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date()
        )
        try await snapshotRepo.saveSnapshot(snapshot)

        try await engine.rollback(to: snapshot, photoAssetId: testPhotoId)

        // The emitRollback is fire-and-forget in a Task — give it a moment
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // Check activity_events table for rollback event
        let count = try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activity_events WHERE kind = 'rollback'") ?? 0
        }
        XCTAssertGreaterThanOrEqual(count, 1)
    }

    func testRollbackCreatesNewSnapshotFromRestored() async throws {
        let adj = PhotoAdjustments()
        let json = String(data: try JSONEncoder().encode(adj), encoding: .utf8)!
        let snapshot = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "original",
            adjustmentJSON: json,
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date()
        )
        try await snapshotRepo.saveSnapshot(snapshot)

        try await engine.rollback(to: snapshot, photoAssetId: testPhotoId)

        let allSnapshots = try await snapshotRepo.fetchSnapshots(forPhoto: testPhotoId)
        XCTAssertEqual(allSnapshots.count, 2, "Should have original + rollback-created snapshot")
        let restoredSnapshot = allSnapshots.last
        XCTAssertTrue(restoredSnapshot?.label?.starts(with: "Restored:") ?? false)
    }

    func testRollbackWithInvalidIdFails() async throws {
        let snapshot = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "bad",
            adjustmentJSON: "INVALID JSON",
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date()
        )
        try await snapshotRepo.saveSnapshot(snapshot)

        do {
            try await engine.rollback(to: snapshot, photoAssetId: testPhotoId)
            XCTFail("Expected RollbackError.invalidSnapshotJSON")
        } catch is RollbackEngine.RollbackError {
            // Expected
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
