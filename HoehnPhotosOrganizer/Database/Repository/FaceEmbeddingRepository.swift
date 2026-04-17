import Foundation
import GRDB

actor FaceEmbeddingRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func upsert(_ record: FaceEmbedding) async throws {
        try await db.dbPool.write { db in
            try record.upsert(db)
        }
    }

    func fetchAll() async throws -> [FaceEmbedding] {
        try await db.dbPool.read { db in
            try FaceEmbedding.fetchAll(db)
        }
    }

    func fetchByPhotoId(_ photoId: String) async throws -> [FaceEmbedding] {
        try await db.dbPool.read { db in
            try FaceEmbedding
                .filter(Column("photo_id") == photoId)
                .order(Column("face_index"))
                .fetchAll(db)
        }
    }

    /// Returns the photo IDs whose faces are similar to the given feature print.
    /// Uses Apple's calibrated computeDistance metric with a tight threshold.
    func findSimilarPhotoIds(to queryData: Data, excludingPhotoId: String? = nil) async throws -> [String] {
        let all = try await fetchAll()
        var seen = Set<String>()
        var results: [String] = []
        var distances: [(photoId: String, dist: Float)] = []

        for record in all {
            guard let featureData = record.featureData else { continue }
            if let exclude = excludingPhotoId, record.photoId == exclude { continue }
            if seen.contains(record.photoId) { continue }

            if let dist = FaceEmbeddingService.distance(queryData, featureData) {
                distances.append((record.photoId, dist))
                if dist <= FaceEmbeddingService.distanceThreshold {
                    seen.insert(record.photoId)
                    results.append(record.photoId)
                }
            }
        }

        // Log top-10 distances for threshold tuning
        let sorted = distances.sorted { $0.dist < $1.dist }.prefix(10)
        print("[FaceSearch] Top distances: \(sorted.map { String(format: "%.3f", $0.dist) }.joined(separator: ", ")) | threshold=\(FaceEmbeddingService.distanceThreshold) matched=\(results.count)")

        return results
    }

    /// Delete all face embeddings for a specific photo (e.g., after orientation correction).
    /// The next face-detection pass will re-detect faces on the corrected proxy.
    func deleteByPhotoId(_ photoId: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(sql: "DELETE FROM face_embeddings WHERE photo_id = ?", arguments: [photoId])
        }
    }

    /// Delete all face embeddings — used when re-indexing with a new embedding format.
    func deleteAll() async throws {
        try await db.dbPool.write { db in
            try db.execute(sql: "DELETE FROM face_embeddings")
        }
        print("[FaceEmbeddingRepository] All face embeddings deleted.")
    }

    /// Returns all distinct photo IDs that have at least one stored face embedding.
    func fetchDistinctPhotoIds() async throws -> [String] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT photo_id FROM face_embeddings")
            return rows.map { $0["photo_id"] as String }
        }
    }

    /// True if any face embedding exists for this photo (used to skip re-indexing).
    func hasEmbeddings(for photoId: String) async throws -> Bool {
        try await db.dbPool.read { db in
            try FaceEmbedding
                .filter(Column("photo_id") == photoId)
                .fetchCount(db) > 0
        }
    }

    // MARK: - Person labeling

    /// Assign a confirmed person identity to a set of face embeddings.
    func assignPerson(faceIds: [String], personId: String, labeledBy: String) async throws {
        guard !faceIds.isEmpty else { return }
        try await db.dbPool.write { db in
            for id in faceIds {
                try db.execute(sql: """
                    UPDATE face_embeddings
                    SET person_id = ?, labeled_by = ?, needs_review = 0
                    WHERE id = ?
                """, arguments: [personId, labeledBy, id])
            }
        }
    }

    /// Assign a tentative person identity (needs Claude review).
    func assignTentative(faceId: String, personId: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(sql: """
                UPDATE face_embeddings
                SET person_id = ?, labeled_by = NULL, needs_review = 1
                WHERE id = ?
            """, arguments: [personId, faceId])
        }
    }

    /// Remove person assignment from a face (mark unlabeled).
    func clearPerson(faceId: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(sql: """
                UPDATE face_embeddings
                SET person_id = NULL, labeled_by = NULL, needs_review = 0
                WHERE id = ?
            """, arguments: [faceId])
        }
    }

    /// All faces that have a confirmed person assignment (ground truth for auto-match).
    func fetchLabeled() async throws -> [FaceEmbedding] {
        try await db.dbPool.read { db in
            try FaceEmbedding
                .filter(Column("person_id") != nil && Column("needs_review") == false)
                .fetchAll(db)
        }
    }

    /// All faces without a person assignment (candidates for auto-match).
    func fetchUnlabeled() async throws -> [FaceEmbedding] {
        try await db.dbPool.read { db in
            try FaceEmbedding
                .filter(Column("person_id") == nil)
                .fetchAll(db)
        }
    }

    /// All faces with a tentative match pending Claude review.
    func fetchNeedsReview() async throws -> [FaceEmbedding] {
        try await db.dbPool.read { db in
            try FaceEmbedding
                .filter(Column("needs_review") == true)
                .fetchAll(db)
        }
    }

    /// All faces assigned to a specific person (confirmed only, not review queue).
    func fetchByPersonId(_ personId: String, confirmedOnly: Bool = false) async throws -> [FaceEmbedding] {
        try await db.dbPool.read { db in
            var query = FaceEmbedding.filter(Column("person_id") == personId)
            if confirmedOnly {
                query = query.filter(Column("needs_review") == false)
            }
            return try query.fetchAll(db)
        }
    }

    // MARK: - Gallery join queries

    /// Returns faces needing Claude review, joined with photo and person info.
    func fetchNeedsReviewGalleryRecords() async throws -> [FaceGalleryRecord] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fe.id, fe.photo_id, fe.face_index,
                    fe.bbox_x, fe.bbox_y, fe.bbox_width, fe.bbox_height,
                    fe.feature_data, fe.created_at,
                    fe.person_id, fe.labeled_by, fe.needs_review,
                    pa.canonical_name,
                    pi.name AS person_name
                FROM face_embeddings fe
                JOIN photo_assets pa ON fe.photo_id = pa.id
                LEFT JOIN person_identities pi ON fe.person_id = pi.id
                WHERE fe.needs_review = 1
                ORDER BY pa.canonical_name, fe.face_index
            """)
            return rows.map { Self.galleryRecord(from: $0) }
        }
    }

    /// Returns confirmed faces for a given person, joined with photo info.
    func fetchConfirmedGalleryRecords(for personId: String) async throws -> [FaceGalleryRecord] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fe.id, fe.photo_id, fe.face_index,
                    fe.bbox_x, fe.bbox_y, fe.bbox_width, fe.bbox_height,
                    fe.feature_data, fe.created_at,
                    fe.person_id, fe.labeled_by, fe.needs_review,
                    pa.canonical_name,
                    pi.name AS person_name
                FROM face_embeddings fe
                JOIN photo_assets pa ON fe.photo_id = pa.id
                LEFT JOIN person_identities pi ON fe.person_id = pi.id
                WHERE fe.person_id = ? AND fe.needs_review = 0
                ORDER BY pa.canonical_name, fe.face_index
                LIMIT 3
            """, arguments: [personId])
            return rows.map { Self.galleryRecord(from: $0) }
        }
    }

    /// True if any face embeddings exist (used for empty-state checks).
    func fetchHasAnyEmbeddings() async throws -> Bool {
        try await db.dbPool.read { db in
            try FaceEmbedding.fetchCount(db) > 0
        }
    }

    /// Returns one representative FaceGalleryRecord per labeled person (for browse chips).
    func fetchLabeledPersonRepresentatives() async throws -> [FaceGalleryRecord] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fe.id, fe.photo_id, fe.face_index,
                    fe.bbox_x, fe.bbox_y, fe.bbox_width, fe.bbox_height,
                    fe.feature_data, fe.created_at,
                    fe.person_id, fe.labeled_by, fe.needs_review,
                    pa.canonical_name,
                    pi.name AS person_name
                FROM face_embeddings fe
                JOIN photo_assets pa ON fe.photo_id = pa.id
                JOIN person_identities pi ON fe.person_id = pi.id
                WHERE fe.person_id IS NOT NULL AND fe.needs_review = 0
                GROUP BY fe.person_id
                ORDER BY pi.name ASC
            """)
            return rows.map { Self.galleryRecord(from: $0) }
        }
    }

    /// Returns distinct photo IDs for all confirmed faces of a given person.
    func fetchPhotoIds(forPersonId personId: String) async throws -> [String] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT photo_id FROM face_embeddings
                WHERE person_id = ? AND needs_review = 0
            """, arguments: [personId])
            return rows.map { $0["photo_id"] as String }
        }
    }

    /// Returns all face embeddings joined with photo canonical_name and person name.
    /// Fetch all face records for display. Excludes `feature_data` (embedding blob) since
    /// the gallery only needs bbox, name, and identity info — not the raw vectors.
    /// Distance-based operations (clustering, auto-match) use fetchUnlabeled/fetchLabeled
    /// which do include feature_data.
    func fetchGalleryRecords() async throws -> [FaceGalleryRecord] {
        try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fe.id, fe.photo_id, fe.face_index,
                    fe.bbox_x, fe.bbox_y, fe.bbox_width, fe.bbox_height,
                    fe.created_at,
                    fe.person_id, fe.labeled_by, fe.needs_review,
                    pa.canonical_name,
                    pi.name AS person_name
                FROM face_embeddings fe
                JOIN photo_assets pa ON fe.photo_id = pa.id
                LEFT JOIN person_identities pi ON fe.person_id = pi.id
                ORDER BY pi.name NULLS LAST, pa.canonical_name, fe.face_index
            """)
            return rows.map { Self.galleryRecord(from: $0) }
        }
    }

    /// Fetch gallery records scoped to specific photo IDs (for inline job widget).
    func fetchGalleryRecords(photoIds: [String]) async throws -> [FaceGalleryRecord] {
        guard !photoIds.isEmpty else { return [] }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ",")
        return try await db.dbPool.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fe.id, fe.photo_id, fe.face_index,
                    fe.bbox_x, fe.bbox_y, fe.bbox_width, fe.bbox_height,
                    fe.created_at,
                    fe.person_id, fe.labeled_by, fe.needs_review,
                    pa.canonical_name,
                    pi.name AS person_name
                FROM face_embeddings fe
                JOIN photo_assets pa ON fe.photo_id = pa.id
                LEFT JOIN person_identities pi ON fe.person_id = pi.id
                WHERE fe.photo_id IN (\(placeholders))
                ORDER BY pi.name NULLS LAST, pa.canonical_name, fe.face_index
            """, arguments: StatementArguments(photoIds))
            return rows.map { Self.galleryRecord(from: $0) }
        }
    }

    /// Fetch unlabeled embeddings (with feature vectors) scoped to specific photo IDs.
    func fetchUnlabeled(photoIds: [String]) async throws -> [FaceEmbedding] {
        guard !photoIds.isEmpty else { return [] }
        let placeholders = photoIds.map { _ in "?" }.joined(separator: ",")
        return try await db.dbPool.read { db in
            try FaceEmbedding
                .filter(sql: "photo_id IN (\(placeholders))", arguments: StatementArguments(photoIds))
                .filter(Column("person_id") == nil)
                .fetchAll(db)
        }
    }

    // MARK: - Private helpers

    private static func galleryRecord(from row: Row) -> FaceGalleryRecord {
        let embedding = FaceEmbedding(
            id: row["id"],
            photoId: row["photo_id"],
            faceIndex: row["face_index"],
            bboxX: row["bbox_x"],
            bboxY: row["bbox_y"],
            bboxWidth: row["bbox_width"],
            bboxHeight: row["bbox_height"],
            featureData: nil, // not fetched for display — saves loading embedding blobs
            createdAt: row["created_at"],
            personId: row["person_id"],
            labeledBy: row["labeled_by"],
            needsReview: (row["needs_review"] as Int?) == 1
        )
        return FaceGalleryRecord(
            embedding: embedding,
            canonicalName: row["canonical_name"],
            personName: row["person_name"]
        )
    }
}
