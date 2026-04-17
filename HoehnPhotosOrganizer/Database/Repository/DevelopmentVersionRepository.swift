import Foundation
import GRDB

actor DevelopmentVersionRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    // Fetch all versions for a photo
    func fetchVersions(photoId: String) async throws -> [DevelopmentVersion] {
        try await db.dbPool.read { conn in
            try DevelopmentVersion
                .filter(Column("photo_id") == photoId)
                .order(Column("created_at").asc)
                .fetchAll(conn)
        }
    }

    // Get the default version for a photo
    func fetchDefaultVersion(photoId: String) async throws -> DevelopmentVersion? {
        try await db.dbPool.read { conn in
            try DevelopmentVersion
                .filter(Column("photo_id") == photoId)
                .filter(Column("is_default") == true)
                .fetchOne(conn)
        }
    }

    // Create a new version
    func createVersion(_ version: DevelopmentVersion, activityService: ActivityEventService? = nil) async throws {
        try await db.dbPool.write { conn in
            var v = version
            try v.insert(conn)
        }
        // Emit activity event for the new version
        if let activityService {
            let versionNumber = Int(version.name.replacingOccurrences(of: "v", with: "")) ?? 1
            try? await activityService.emitVersionCreated(
                photoAssetId: version.photoId,
                versionName: version.name,
                versionNumber: versionNumber
            )
        }
    }

    // Update adjustments (and optionally masks) for a version
    func updateAdjustments(versionId: String, adjustmentsJson: String, masksJson: String? = nil) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                UPDATE development_versions
                SET adjustments_json = ?, masks_json = ?, updated_at = ?
                WHERE id = ?
            """, arguments: [adjustmentsJson, masksJson, now, versionId])
        }
    }

    // Publish a version (set is_published = true)
    func publishVersion(versionId: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                UPDATE development_versions
                SET is_published = 1, updated_at = ?
                WHERE id = ?
            """, arguments: [now, versionId])
        }
    }

    // Set a version as the default (and unset others for the same photo)
    func setDefault(versionId: String, photoId: String) async throws {
        try await db.dbPool.write { conn in
            // Unset all defaults for this photo
            try conn.execute(sql: """
                UPDATE development_versions SET is_default = 0 WHERE photo_id = ?
            """, arguments: [photoId])
            // Set the new default
            try conn.execute(sql: """
                UPDATE development_versions SET is_default = 1 WHERE id = ?
            """, arguments: [versionId])
        }
    }

    // Fetch photo IDs that have 2+ development versions
    func fetchMultiVersionPhotoIds() async throws -> Set<String> {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT photo_id FROM development_versions
                GROUP BY photo_id HAVING COUNT(*) >= 2
            """)
            return Set(rows.map { $0["photo_id"] as String })
        }
    }

    // Delete a version
    func deleteVersion(versionId: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(sql: "DELETE FROM development_versions WHERE id = ?", arguments: [versionId])
        }
    }

    // Toggle published state for a version
    func togglePublished(versionId: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                UPDATE development_versions
                SET is_published = CASE WHEN is_published = 1 THEN 0 ELSE 1 END, updated_at = ?
                WHERE id = ?
            """, arguments: [now, versionId])
        }
    }

    // Rename a version
    func renameVersion(versionId: String, newName: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                UPDATE development_versions SET name = ?, updated_at = ? WHERE id = ?
            """, arguments: [newName, now, versionId])
        }
    }

    // Count published versions for a set of photo IDs (for job progress tracking)
    func countPublishedVersions(photoIds: [String]) async throws -> Int {
        guard !photoIds.isEmpty else { return 0 }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ",")
        return try await db.dbPool.read { conn in
            try Int.fetchOne(conn, sql: """
                SELECT COUNT(DISTINCT photo_id) FROM development_versions
                WHERE photo_id IN (\(placeholders)) AND is_published = 1
            """, arguments: StatementArguments(photoIds)) ?? 0
        }
    }
}
