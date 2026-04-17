import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class BackgroundJobCoordinatorTests: XCTestCase {
    var db: AppDatabase!
    var coordinator: BackgroundJobCoordinator!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        coordinator = BackgroundJobCoordinator(db: db)
    }

    func testCreateJobWritesRowToDatabase() async throws {
        let job = try await coordinator.startOrResume(type: .ingestion)
        XCTAssertEqual(job.type, "ingestion")
        XCTAssertEqual(job.status, "running")
        let fetched = try await db.dbPool.read { try BackgroundJob.fetchOne($0, key: job.id) }
        XCTAssertNotNil(fetched)
    }

    func testStartOrResumeReturnsExistingRunningRow() async throws {
        let job1 = try await coordinator.startOrResume(type: .duplicateScan)
        let job2 = try await coordinator.startOrResume(type: .duplicateScan)
        XCTAssertEqual(job1.id, job2.id, "Should return same job, not create a duplicate")
    }

    func testCheckpointUpdatesCursorJson() async throws {
        let job = try await coordinator.startOrResume(type: .catalogExport)
        try await coordinator.checkpoint(job, cursorJson: "{\"processedCount\":42}")
        let updated = try await db.dbPool.read { try BackgroundJob.fetchOne($0, key: job.id) }
        XCTAssertEqual(updated?.cursorJson, "{\"processedCount\":42}")
    }

    func testDoubleLaunchGuardResetsInterruptedStatus() async throws {
        // Simulate a crash: manually insert a status=running row
        let crashedJob = BackgroundJob.new(type: .proxyGeneration)
        // Already status=running from .new()
        try await db.dbPool.write { try crashedJob.insert($0) }
        // On launch, coordinator resets running -> interrupted
        try await coordinator.resetInterruptedJobs()
        let after = try await db.dbPool.read { try BackgroundJob.fetchOne($0, key: crashedJob.id) }
        XCTAssertEqual(after?.status, "interrupted")
    }

    func testCompleteJobMarksStatusCompleted() async throws {
        let job = try await coordinator.startOrResume(type: .ingestion)
        try await coordinator.complete(jobId: job.id)
        let updated = try await db.dbPool.read { try BackgroundJob.fetchOne($0, key: job.id) }
        XCTAssertEqual(updated?.status, "completed")
    }
}
