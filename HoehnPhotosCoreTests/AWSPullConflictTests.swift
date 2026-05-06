import XCTest
import GRDB
@testable import HoehnPhotosCore

/// Tests for AWSPullCoordinator.decide() — the "don't clobber pending local edits" guarantee.
///
/// The function decides per-row whether to apply a remote write (.update) or skip it (.skip).
/// Rows that the user has edited locally since their last AWS push must win over the incoming
/// remote write so local changes aren't silently overwritten during offline use.
final class AWSPullConflictTests: XCTestCase {

    // Minimal schema: id, ts (updated_at or created_at), syn (aws_synced_at)
    private let testSQL = "SELECT ts, syn FROM test_rows WHERE id = ? LIMIT 1"

    private func makeDB() throws -> DatabaseQueue {
        let db = try DatabaseQueue()
        try db.write { db in
            try db.execute(sql: "CREATE TABLE test_rows (id TEXT PRIMARY KEY, ts TEXT, syn TEXT)")
        }
        return db
    }

    // MARK: - No local row

    func testNoLocalRowReturnsNil() throws {
        let db = try makeDB()
        let result = try db.read { db in
            try AWSPullCoordinator.decide(db: db, sql: testSQL, id: "x", remoteUpdatedAtISO: "2026-01-02T00:00:00Z")
        }
        XCTAssertNil(result, "Missing row should return nil so the caller inserts")
    }

    // MARK: - Remote newer (no pending local edit)

    func testRemoteNewerNoPendingLocalReturnsUpdate() throws {
        let db = try makeDB()
        try db.write { db in
            try db.execute(sql: "INSERT INTO test_rows VALUES (?, ?, ?)",
                           arguments: ["x", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"])
        }
        let result = try db.read { db in
            try AWSPullCoordinator.decide(db: db, sql: testSQL, id: "x", remoteUpdatedAtISO: "2026-01-02T00:00:00Z")
        }
        XCTAssertEqual(result, .update)
    }

    // MARK: - Pending local edit wins

    func testLocalNewerWithSyncedAtReturnsSkip() throws {
        let db = try makeDB()
        // local updated AFTER last sync, and remote is older than local
        try db.write { db in
            try db.execute(sql: "INSERT INTO test_rows VALUES (?, ?, ?)",
                           arguments: ["x", "2026-01-03T00:00:00Z", "2026-01-01T00:00:00Z"])
        }
        let result = try db.read { db in
            // remote brings "2026-01-02" but local is already "2026-01-03"
            try AWSPullCoordinator.decide(db: db, sql: testSQL, id: "x", remoteUpdatedAtISO: "2026-01-02T00:00:00Z")
        }
        XCTAssertEqual(result, .skip, "Pending local edit must not be overwritten by older remote write")
    }

    // MARK: - Never synced — remote wins

    func testLocalNewerButNeverSyncedReturnsUpdate() throws {
        let db = try makeDB()
        // aws_synced_at is NULL — this row was never pushed. Remote wins.
        try db.write { db in
            try db.execute(sql: "INSERT INTO test_rows VALUES (?, ?, ?)",
                           arguments: ["x", "2026-01-03T00:00:00Z", nil])
        }
        let result = try db.read { db in
            try AWSPullCoordinator.decide(db: db, sql: testSQL, id: "x", remoteUpdatedAtISO: "2026-01-02T00:00:00Z")
        }
        XCTAssertEqual(result, .update, "Row never synced — remote write should win")
    }

    func testLocalNewerButEmptySyncedAtReturnsUpdate() throws {
        let db = try makeDB()
        // aws_synced_at is empty string — treated same as nil
        try db.write { db in
            try db.execute(sql: "INSERT INTO test_rows VALUES (?, ?, ?)",
                           arguments: ["x", "2026-01-03T00:00:00Z", ""])
        }
        let result = try db.read { db in
            try AWSPullCoordinator.decide(db: db, sql: testSQL, id: "x", remoteUpdatedAtISO: "2026-01-02T00:00:00Z")
        }
        XCTAssertEqual(result, .update, "Empty aws_synced_at is treated as unsynced — remote wins")
    }

    // MARK: - Equal timestamps

    func testEqualTimestampsReturnsUpdate() throws {
        let db = try makeDB()
        let ts = "2026-01-02T00:00:00Z"
        try db.write { db in
            try db.execute(sql: "INSERT INTO test_rows VALUES (?, ?, ?)",
                           arguments: ["x", ts, ts])
        }
        let result = try db.read { db in
            try AWSPullCoordinator.decide(db: db, sql: testSQL, id: "x", remoteUpdatedAtISO: ts)
        }
        XCTAssertEqual(result, .update, "Equal timestamps should not trigger skip — remote wins on tie")
    }
}
