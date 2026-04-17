import Foundation
import GRDB

actor SyncStateRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Incremental Sync Tracking

    func getLastSyncTimestamp(for key: String = "lastSyncTimestamp") async throws -> Int64 {
        try await db.dbPool.read { db in
            let record = try SyncStateRecord.fetchOne(db, key: key)
            return Int64(record?.value ?? "0") ?? 0
        }
    }

    func setLastSyncTimestamp(_ timestamp: Int64, for key: String = "lastSyncTimestamp") async throws {
        try await db.dbPool.write { db in
            var record = SyncStateRecord(key: key, value: String(timestamp))
            try record.save(db, onConflict: .replace)
        }
    }

    // MARK: - Per-Photo Sync Status

    func updatePhotoSyncStatus(
        canonicalId: String,
        status: String,
        error: String? = nil
    ) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE photo_assets
                    SET sync_status = ?, sync_error = ?, last_synced_at = ?
                    WHERE canonical_name = ?
                    """,
                arguments: [
                    status,
                    error,
                    status == "synced" ? ISO8601DateFormatter().string(from: Date()) : nil,
                    canonicalId
                ]
            )
        }
    }

    func getPhotosModifiedSince(_ timestamp: Int64) async throws -> [PhotoAsset] {
        try await db.dbPool.read { db in
            let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
            let iso = ISO8601DateFormatter().string(from: date)
            return try PhotoAsset
                .filter(Column("updated_at") > iso)
                .fetchAll(db)
        }
    }

    func syncStatusCounts() async throws -> [String: Int] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT sync_status, COUNT(*) as count
                FROM photo_assets
                GROUP BY sync_status
                """)
            var counts: [String: Int] = [:]
            for row in rows {
                counts[row["sync_status"] as String] = row["count"] as Int
            }
            return counts
        }
    }

    func photosWithSyncErrors() async throws -> [PhotoAsset] {
        try await db.dbPool.read { db in
            try PhotoAsset
                .filter(Column("sync_status") == "error")
                .fetchAll(db)
        }
    }
}
