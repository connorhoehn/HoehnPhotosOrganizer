import Foundation
import GRDB

/// Caches Apple Vision segmentation results per photo to avoid re-running detection.
actor SegmentationCacheRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    /// Fetch cached segments for a photo. Returns nil on cache miss.
    func fetchSegments(forPhoto photoId: String) async throws -> String? {
        try await db.dbPool.read { db in
            try String.fetchOne(db,
                sql: "SELECT segments_json FROM segmentation_cache WHERE photo_asset_id = ?",
                arguments: [photoId])
        }
    }

    /// Store segmentation results for a photo (upsert).
    func storeSegments(forPhoto photoId: String, segmentsJSON: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO segmentation_cache (photo_asset_id, segments_json, created_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(photo_asset_id) DO UPDATE SET
                        segments_json = excluded.segments_json,
                        created_at = excluded.created_at
                    """,
                arguments: [photoId, segmentsJSON, Date()]
            )
        }
    }

    /// Invalidate cache for a photo (e.g., after re-import or crop).
    func invalidate(forPhoto photoId: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "DELETE FROM segmentation_cache WHERE photo_asset_id = ?",
                arguments: [photoId]
            )
        }
    }
}
