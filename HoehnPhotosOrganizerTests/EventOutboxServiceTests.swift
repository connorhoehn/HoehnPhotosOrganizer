import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class EventOutboxServiceTests: XCTestCase {

    var db: AppDatabase!
    var service: EventOutboxService!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        service = EventOutboxService(db: db)
    }

    // MARK: - Enqueue

    func testEnqueueCreatesPendingEntry() async throws {
        try await service.enqueue(kind: .importBatch, title: "Batch 1")
        let count = try await service.pendingCount()
        XCTAssertEqual(count, 1)
        let entries = try await service.fetchPending()
        XCTAssertEqual(entries.first?.status, .pending)
        XCTAssertEqual(entries.first?.title, "Batch 1")
        XCTAssertEqual(entries.first?.attempts, 0)
    }

    // MARK: - Claim

    func testClaimTransitionsToProcessingAndReturnsTrue() async throws {
        try await service.enqueue(kind: .adjustment, title: "Edit 1")
        let pending = try await service.fetchPending()
        let id = try XCTUnwrap(pending.first?.id)

        let claimed = try await service.claim(id: id)
        XCTAssertTrue(claimed, "claim must return true when entry was pending")

        // Entry should no longer appear in fetchPending (status is now processing)
        let afterClaim = try await service.fetchPending()
        XCTAssertFalse(afterClaim.contains { $0.id == id },
                       "Claimed entry must not appear in fetchPending")

        // Verify attempts incremented
        let row = try await db.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT attempts FROM event_outbox WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(row?["attempts"] as? Int, 1)
    }

    // MARK: - Mark done

    func testMarkDoneRemovesFromPendingAndFailed() async throws {
        try await service.enqueue(kind: .note, title: "Note event")
        let pending = try await service.fetchPending()
        let id = try XCTUnwrap(pending.first?.id)

        _ = try await service.claim(id: id)
        try await service.markDone(id: id)

        XCTAssertEqual(try await service.pendingCount(), 0)
        XCTAssertEqual(try await service.failedCount(), 0)

        let row = try await db.dbPool.read { db in
            try Row.fetchOne(db, sql: "SELECT status FROM event_outbox WHERE id = ?", arguments: [id])
        }
        XCTAssertEqual(row?["status"] as? String, "done")
    }

    // MARK: - Mark failed (below maxAttempts → retry)

    func testMarkFailedBelowMaxAttemptsReturnsToPending() async throws {
        try await service.enqueue(kind: .adjustment, title: "Will retry")
        let id = try XCTUnwrap((try await service.fetchPending()).first?.id)

        _ = try await service.claim(id: id)          // attempts becomes 1
        try await service.markFailed(id: id, error: "transient error")

        // 1 attempt < 5 maxAttempts → back to pending for retry
        XCTAssertEqual(try await service.pendingCount(), 1, "Entry below maxAttempts must return to pending")
        XCTAssertEqual(try await service.failedCount(), 0)
    }

    // MARK: - Mark failed (at maxAttempts → permanent failure) + resetFailed

    func testMarkFailedAtMaxAttemptsStaysFailedAndResetFailedRequeues() async throws {
        try await service.enqueue(kind: .importBatch, title: "Exhausted retries")
        let id = try XCTUnwrap((try await service.fetchPending()).first?.id)

        // Manually advance attempts to maxAttempts (5) and status to processing
        // so markFailed sees attempts >= maxAttempts.
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE event_outbox SET status = 'processing', attempts = ? WHERE id = ?",
                arguments: [EventOutboxService.maxAttempts, id]
            )
        }

        try await service.markFailed(id: id, error: "permanent error")

        XCTAssertEqual(try await service.failedCount(), 1,
                       "Entry at maxAttempts must permanently land in failed")
        XCTAssertEqual(try await service.pendingCount(), 0)

        // resetFailed should re-queue the entry
        let requeued = try await service.resetFailed()
        XCTAssertEqual(requeued, 1, "resetFailed must return count of re-queued entries")
        XCTAssertEqual(try await service.pendingCount(), 1, "Entry must be pending after resetFailed")
        XCTAssertEqual(try await service.failedCount(), 0)
    }
}
