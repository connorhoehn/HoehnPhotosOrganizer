import Foundation
import GRDB
import HoehnPhotosCore

// MARK: - SimilarPhotoFinder
//
// Sibling read helper to MobilePhotoRepository. Lives on iOS so we don't
// touch the shared MobileRepositories.swift while another agent is editing
// it. Pure read access against AppDatabase.dbPool.

enum SimilarPhotoFinder {

    /// Find up to `limit` photos similar to `photo`, excluding the photo
    /// itself. Similarity is defined as ANY of:
    ///   - Captured within ±1 day of `photo.createdAt`.
    ///   - Same `scene_type`.
    ///   - Same camera (Make + Model substring in raw_exif_json).
    ///
    /// The query is ranked roughly by "how many criteria matched" so the
    /// strongest matches appear first.
    static func findSimilar(
        to photo: PhotoAsset,
        in db: AppDatabase,
        limit: Int = 12
    ) async throws -> [PhotoAsset] {
        let created = photo.createdAt
        let dayBefore = shift(created, byDays: -1)
        let dayAfter = shift(created, byDays: 1)

        // Derive camera make/model from EXIF for a LIKE match against
        // raw_exif_json. Any single token is enough to fall into the bucket.
        let cameraToken = photo.cameraMakeModel?
            .trimmingCharacters(in: .whitespaces)
            .split(separator: " ")
            .first
            .map(String.init)

        let cameraPattern = cameraToken.map { "%\"\($0)%" } // loose LIKE

        let scene = photo.sceneType

        return try await db.dbPool.read { conn -> [PhotoAsset] in
            var clauses: [String] = []
            var args: [DatabaseValueConvertible] = []

            // Same-day bucket
            clauses.append("(created_at >= ? AND created_at <= ?)")
            args.append(dayBefore)
            args.append(dayAfter)

            if let scene, !scene.isEmpty {
                clauses.append("scene_type = ?")
                args.append(scene)
            }

            if let cameraPattern {
                clauses.append("raw_exif_json LIKE ?")
                args.append(cameraPattern)
            }

            let whereUnion = clauses.joined(separator: " OR ")

            // Rank by how many bucket conditions match — pure SQL so we can
            // ORDER BY it. Each CASE adds 1 when hit.
            var rankParts: [String] = []
            var rankArgs: [DatabaseValueConvertible] = []
            rankParts.append("(CASE WHEN created_at >= ? AND created_at <= ? THEN 1 ELSE 0 END)")
            rankArgs.append(dayBefore); rankArgs.append(dayAfter)
            if let scene, !scene.isEmpty {
                rankParts.append("(CASE WHEN scene_type = ? THEN 1 ELSE 0 END)")
                rankArgs.append(scene)
            }
            if let cameraPattern {
                rankParts.append("(CASE WHEN raw_exif_json LIKE ? THEN 1 ELSE 0 END)")
                rankArgs.append(cameraPattern)
            }
            let rankExpr = rankParts.joined(separator: " + ")

            let sql = """
                SELECT *, (\(rankExpr)) AS match_rank
                FROM photo_assets
                WHERE id != ?
                  AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                  AND import_status = 'library'
                  AND (\(whereUnion))
                ORDER BY match_rank DESC, created_at DESC
                LIMIT ?
            """

            // Final arg order: rank args, then id, then WHERE args, then limit.
            var finalArgs: [DatabaseValueConvertible] = []
            finalArgs.append(contentsOf: rankArgs)
            finalArgs.append(photo.id)
            finalArgs.append(contentsOf: args)
            finalArgs.append(limit)

            return try PhotoAsset.fetchAll(conn, sql: sql, arguments: StatementArguments(finalArgs))
        }
    }

    // MARK: - Date helpers

    private static func shift(_ iso: String, byDays days: Int) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else {
            // Fall back to lexical shift on the date portion if parse fails.
            return iso
        }
        let shifted = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: days, to: date) ?? date
        return formatter.string(from: shifted)
    }
}
