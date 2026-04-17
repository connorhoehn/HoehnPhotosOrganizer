import Foundation
import GRDB

// MARK: - Month Grouping Types

/// Month key string in "YYYY-MM" format, used for bento section grouping.
public typealias MonthKey = String

/// A group of photos belonging to the same calendar month.
public struct MonthSection: Identifiable {
    public var id: String { monthKey }
    public let monthKey: MonthKey        // "2024-03"
    public let displayLabel: String      // "March 2024"
    public var photos: [PhotoAsset]
    public var photoCount: Int { photos.count }
}

// MARK: - MobilePhotoRepository

/// Lightweight photo repository for the iOS companion app.
/// Reads from the same GRDB catalog as macOS.
public actor MobilePhotoRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    public func fetchAll(limit: Int = 500) async throws -> [PhotoAsset] {
        try await db.dbPool.read { conn in
            try PhotoAsset
                .filter(Column("hidden_from_library") == false || Column("hidden_from_library") == nil)
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Paginated fetch with optional curation filter and import_status control.
    public func fetchLibraryPhotos(
        curationFilter: CurationState? = nil,
        showStaged: Bool = false,
        limit: Int = 200,
        offset: Int = 0
    ) async throws -> [PhotoAsset] {
        try await db.dbPool.read { conn in
            var query = PhotoAsset
                .filter(Column("import_status") == (showStaged ? "staged" : "library"))
                .filter(Column("hidden_from_library") == false || Column("hidden_from_library") == nil)
                .order(Column("created_at").desc)
                .limit(limit, offset: offset)
            if let filter = curationFilter {
                query = query.filter(Column("curation_state") == filter.rawValue)
            }
            return try query.fetchAll(conn)
        }
    }

    public func fetchById(_ id: String) async throws -> PhotoAsset? {
        try await db.dbPool.read { conn in
            try PhotoAsset.fetchOne(conn, key: id)
        }
    }

    public func updateCurationState(id: String, state: CurationState) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: "UPDATE photo_assets SET curation_state = ?, updated_at = ? WHERE id = ?",
                arguments: [state.rawValue, ISO8601DateFormatter().string(from: Date()), id]
            )
        }
    }

    public func search(query: String, limit: Int = 100) async throws -> [PhotoAsset] {
        let pattern = "%\(query)%"
        return try await db.dbPool.read { conn in
            try PhotoAsset.fetchAll(conn, sql: """
                SELECT * FROM photo_assets
                WHERE canonical_name LIKE ?
                   OR raw_exif_json LIKE ?
                   OR user_metadata_json LIKE ?
                ORDER BY created_at DESC
                LIMIT ?
            """, arguments: [pattern, pattern, pattern, limit])
        }
    }

    /// Extended search with optional filter parameters applied at the SQL level.
    public func search(
        query: String,
        curationStates: Set<CurationState> = [],
        grayscaleOnly: Bool = false,
        yearRange: ClosedRange<Int>? = nil,
        sortNewestFirst: Bool = true,
        limit: Int = 200
    ) async throws -> [PhotoAsset] {
        let pattern = "%\(query)%"
        return try await db.dbPool.read { conn in
            var sql = """
                SELECT * FROM photo_assets
                WHERE (canonical_name LIKE ?
                       OR raw_exif_json LIKE ?
                       OR user_metadata_json LIKE ?)
            """
            var args: [any DatabaseValueConvertible] = [pattern, pattern, pattern]

            if !curationStates.isEmpty {
                let placeholders = curationStates.map { _ in "?" }.joined(separator: ", ")
                sql += " AND curation_state IN (\(placeholders))"
                args.append(contentsOf: curationStates.map { $0.rawValue })
            }

            if grayscaleOnly {
                sql += " AND is_grayscale = 1"
            }

            if let range = yearRange {
                sql += " AND CAST(substr(date_modified, 1, 4) AS INTEGER) >= ?"
                sql += " AND CAST(substr(date_modified, 1, 4) AS INTEGER) <= ?"
                args.append(range.lowerBound)
                args.append(range.upperBound)
            }

            sql += sortNewestFirst
                ? " ORDER BY created_at DESC"
                : " ORDER BY created_at ASC"
            sql += " LIMIT ?"
            args.append(limit)

            return try PhotoAsset.fetchAll(conn, sql: sql, arguments: StatementArguments(args))
        }
    }

    /// Fetch all library photos grouped by calendar month (newest month first).
    /// Returns an ordered array of MonthSection values, each with a YYYY-MM key,
    /// a display label like "March 2024", and the photos for that month.
    ///
    /// NOTE: No pagination — month grouping requires the full sorted set.
    /// dateModified is used as the primary date; falls back to createdAt if nil.
    public func fetchLibraryPhotosGroupedByMonth(
        curationFilter: CurationState? = nil,
        showStaged: Bool = false,
        monthLimit: Int? = nil
    ) async throws -> [MonthSection] {
        let allPhotos = try await db.dbPool.read { conn in
            var query = PhotoAsset
                .filter(Column("import_status") == (showStaged ? "staged" : "library"))
                .filter(Column("hidden_from_library") == false || Column("hidden_from_library") == nil)
                .order(Column("date_modified").desc, Column("created_at").desc)
            if let filter = curationFilter {
                query = query.filter(Column("curation_state") == filter.rawValue)
            }
            return try query.fetchAll(conn)
        }
        let sections = Self.groupByMonth(allPhotos)
        if let limit = monthLimit {
            return Array(sections.prefix(limit))
        }
        return sections
    }

    /// Groups a pre-sorted (newest-first) array of photos into MonthSection values.
    /// Photos are expected to be sorted by date descending so streaming group logic
    /// naturally preserves month order (newest month first).
    private static func groupByMonth(_ photos: [PhotoAsset]) -> [MonthSection] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let isoFormatterNoFrac = ISO8601DateFormatter()
        isoFormatterNoFrac.formatOptions = [.withInternetDateTime]

        let yearMonthFormatter = DateFormatter()
        yearMonthFormatter.locale = Locale(identifier: "en_US_POSIX")
        yearMonthFormatter.dateFormat = "yyyy-MM"

        let displayFormatter = DateFormatter()
        displayFormatter.locale = Locale(identifier: "en_US_POSIX")
        displayFormatter.dateFormat = "MMMM yyyy"

        var grouped: [(key: String, label: String, photos: [PhotoAsset])] = []
        var currentKey: String?
        var currentLabel: String?
        var currentPhotos: [PhotoAsset] = []

        for photo in photos {
            let dateString = photo.dateModified ?? photo.createdAt
            let date = isoFormatter.date(from: dateString)
                ?? isoFormatterNoFrac.date(from: dateString)
                ?? Date()
            let key = yearMonthFormatter.string(from: date)
            let label = displayFormatter.string(from: date)

            if key != currentKey {
                if let k = currentKey, let l = currentLabel {
                    grouped.append((key: k, label: l, photos: currentPhotos))
                }
                currentKey = key
                currentLabel = label
                currentPhotos = [photo]
            } else {
                currentPhotos.append(photo)
            }
        }
        if let k = currentKey, let l = currentLabel {
            grouped.append((key: k, label: l, photos: currentPhotos))
        }

        return grouped.map { MonthSection(monthKey: $0.key, displayLabel: $0.label, photos: $0.photos) }
    }
}

// MARK: - MobileJobRepository

public actor MobileJobRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    public func fetchAll() async throws -> [TriageJob] {
        try await db.dbPool.read { conn in
            try TriageJob
                .order(Column("created_at").desc)
                .fetchAll(conn)
        }
    }

    public func fetchPhotos(jobId: String) async throws -> [PhotoAsset] {
        try await db.dbPool.read { conn in
            try PhotoAsset.fetchAll(conn, sql: """
                SELECT pa.* FROM photo_assets pa
                JOIN triage_job_photos tjp ON tjp.photo_id = pa.id
                WHERE tjp.job_id = ?
                ORDER BY tjp.sort_order
            """, arguments: [jobId])
        }
    }

    public func markComplete(jobId: String) async throws {
        try await db.dbPool.write { conn in
            let now = Date()
            try conn.execute(
                sql: "UPDATE triage_jobs SET status = ?, completed_at = ?, updated_at = ? WHERE id = ?",
                arguments: [TriageJobStatus.complete.rawValue, now, now, jobId]
            )
        }
    }

    public func fetchPeopleProgress(jobId: String) async throws -> (identified: Int, total: Int) {
        try await db.dbPool.read { conn in
            let total = try Int.fetchOne(conn, sql: """
                SELECT COUNT(DISTINCT tjp.photo_id)
                FROM triage_job_photos tjp
                JOIN face_embeddings fe ON fe.photo_id = tjp.photo_id
                WHERE tjp.job_id = ?
            """, arguments: [jobId]) ?? 0

            let identified = try Int.fetchOne(conn, sql: """
                SELECT COUNT(DISTINCT tjp.photo_id)
                FROM triage_job_photos tjp
                JOIN face_embeddings fe ON fe.photo_id = tjp.photo_id
                WHERE tjp.job_id = ? AND fe.person_id IS NOT NULL
            """, arguments: [jobId]) ?? 0

            return (identified, total)
        }
    }

    public func fetchDevelopProgress(jobId: String) async throws -> (developed: Int, total: Int) {
        try await db.dbPool.read { conn in
            let keeperCount = try Int.fetchOne(conn, sql: """
                SELECT COUNT(*)
                FROM triage_job_photos tjp
                JOIN photo_assets pa ON pa.id = tjp.photo_id
                WHERE tjp.job_id = ? AND pa.curation_state = ?
            """, arguments: [jobId, CurationState.keeper.rawValue]) ?? 0

            let developedCount = try Int.fetchOne(conn, sql: """
                SELECT COUNT(DISTINCT tjp.photo_id)
                FROM triage_job_photos tjp
                JOIN photo_assets pa ON pa.id = tjp.photo_id
                JOIN development_versions dv ON dv.photo_id = tjp.photo_id
                WHERE tjp.job_id = ? AND pa.curation_state = ?
            """, arguments: [jobId, CurationState.keeper.rawValue]) ?? 0

            return (developedCount, keeperCount)
        }
    }
}

// MARK: - MobileStudioRepository

public actor MobileStudioRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// Fetch all revisions across all photos, newest first.
    public func fetchAllRevisions(limit: Int = 200) async throws -> [StudioRevision] {
        try await db.dbPool.read { conn in
            try StudioRevision
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }

    /// Fetch revisions for a specific photo.
    public func fetchRevisions(photoId: String) async throws -> [StudioRevision] {
        try await db.dbPool.read { conn in
            try StudioRevision
                .filter(Column("photo_id") == photoId)
                .order(Column("created_at").desc)
                .fetchAll(conn)
        }
    }

    /// Fetch revisions grouped by medium (for filter chips).
    /// Returns a dictionary keyed by StudioMedium raw value.
    public func fetchGroupedByMedium() async throws -> [String: [StudioRevision]] {
        let all = try await fetchAllRevisions(limit: 500)
        return Dictionary(grouping: all) { $0.medium }
    }

    /// Fetch distinct mediums that have at least one revision (for filter chip visibility).
    public func fetchAvailableMediums() async throws -> [String] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT DISTINCT medium FROM studio_revisions ORDER BY medium
            """)
            return rows.compactMap { $0["medium"] as? String }
        }
    }
}

// MARK: - MobilePrintRepository

public actor MobilePrintRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    /// Summary struct for list display (avoids decoding full content_json).
    public struct PrintAttemptSummary: Identifiable, Sendable, Hashable {
        public let id: String              // thread_entry.id
        public let photoId: String         // thread_root_id
        public let printType: String       // from content_json
        public let paper: String           // from content_json
        public let outcome: String         // from content_json
        public let outcomeNotes: String    // from content_json
        public let createdAt: String       // ISO 8601
        public let calibrationTemplate: String?  // e.g. "Calibration Strip 4×2"
        public let iccProfileName: String?       // e.g. "HahnemuleLuster"
    }

    /// Fetch all print attempts across all photos, newest first.
    public func fetchAll(limit: Int = 100) async throws -> [PrintAttemptSummary] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, thread_root_id, content_json, created_at
                FROM thread_entries
                WHERE kind = 'print_attempt'
                ORDER BY created_at DESC
                LIMIT ?
            """, arguments: [limit])

            return rows.compactMap { row -> PrintAttemptSummary? in
                guard let id = row["id"] as? String,
                      let photoId = row["thread_root_id"] as? String,
                      let jsonStr = row["content_json"] as? String,
                      let createdAt = row["created_at"] as? String,
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }

                return PrintAttemptSummary(
                    id: id,
                    photoId: photoId,
                    printType: json["print_type"] as? String ?? "unknown",
                    paper: json["paper"] as? String ?? "Unknown",
                    outcome: json["outcome"] as? String ?? "unknown",
                    outcomeNotes: json["outcome_notes"] as? String ?? "",
                    createdAt: createdAt,
                    calibrationTemplate: json["calibration_template"] as? String,
                    iccProfileName: json["icc_profile_name"] as? String
                )
            }
        }
    }

    /// Fetch print attempts for a specific photo.
    public func fetchForPhoto(photoId: String) async throws -> [PrintAttemptSummary] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, thread_root_id, content_json, created_at
                FROM thread_entries
                WHERE kind = 'print_attempt' AND thread_root_id = ?
                ORDER BY created_at DESC
            """, arguments: [photoId])

            return rows.compactMap { row -> PrintAttemptSummary? in
                guard let id = row["id"] as? String,
                      let photoId = row["thread_root_id"] as? String,
                      let jsonStr = row["content_json"] as? String,
                      let createdAt = row["created_at"] as? String,
                      let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }

                return PrintAttemptSummary(
                    id: id,
                    photoId: photoId,
                    printType: json["print_type"] as? String ?? "unknown",
                    paper: json["paper"] as? String ?? "Unknown",
                    outcome: json["outcome"] as? String ?? "unknown",
                    outcomeNotes: json["outcome_notes"] as? String ?? "",
                    createdAt: createdAt,
                    calibrationTemplate: json["calibration_template"] as? String,
                    iccProfileName: json["icc_profile_name"] as? String
                )
            }
        }
    }
}

// MARK: - MobileActivityRepository

public actor MobileActivityRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    public func fetchRecent(limit: Int = 50) async throws -> [ActivityEvent] {
        try await db.dbPool.read { conn in
            try ActivityEvent
                .order(Column("created_at").desc)
                .limit(limit)
                .fetchAll(conn)
        }
    }
}

// MARK: - MobilePeopleRepository

public actor MobilePeopleRepository {
    public let db: AppDatabase

    public init(db: AppDatabase) { self.db = db }

    public struct PersonSummary: Identifiable {
        public let id: String
        public let name: String
        public let faceCount: Int
        /// ID of a representative face embedding for thumbnail generation.
        public let representativeFaceId: String?
        /// Photo ID for the representative face (used to build proxy URL).
        public let representativePhotoId: String?
    }

    public func fetchPeople() async throws -> [PersonSummary] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT pi.id, pi.name, COUNT(fe.id) as cnt,
                       (SELECT fe2.id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_face_id,
                       (SELECT fe2.photo_id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_photo_id
                FROM person_identities pi
                JOIN face_embeddings fe ON fe.person_id = pi.id
                WHERE pi.name IS NOT NULL AND pi.name != ''
                GROUP BY pi.id, pi.name
                ORDER BY cnt DESC
            """)
            return rows.map {
                PersonSummary(
                    id: $0["id"] as String,
                    name: $0["name"] as String,
                    faceCount: $0["cnt"] as Int,
                    representativeFaceId: $0["rep_face_id"] as String?,
                    representativePhotoId: $0["rep_photo_id"] as String?
                )
            }
        }
    }

    /// Fetch one representative face embedding for a person (used for thumbnail crop).
    public func fetchFaceForPerson(personId: String) async throws -> FaceEmbedding? {
        try await db.dbPool.read { conn in
            try FaceEmbedding.fetchOne(conn, sql: """
                SELECT * FROM face_embeddings WHERE person_id = ? LIMIT 1
            """, arguments: [personId])
        }
    }

    /// Fetch all photos for a person (via face_embeddings join), ordered newest first.
    public func fetchPhotosForPerson(personId: String) async throws -> [PhotoAsset] {
        try await db.dbPool.read { conn in
            try PhotoAsset.fetchAll(conn, sql: """
                SELECT DISTINCT pa.* FROM photo_assets pa
                JOIN face_embeddings fe ON fe.photo_id = pa.id
                WHERE fe.person_id = ?
                ORDER BY pa.created_at DESC
            """, arguments: [personId])
        }
    }
}
