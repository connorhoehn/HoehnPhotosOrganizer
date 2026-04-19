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

    // MARK: - Scope-aware search (Phase 3)

    /// Wrapper around the existing broad LIKE search; kept so the Search tab can use
    /// a single dispatch path for `SearchScope.all`.
    public func searchAll(query: String, limit: Int = 200) async throws -> [PhotoAsset] {
        if query.isEmpty {
            return try await fetchAll(limit: limit)
        }
        return try await search(query: query, limit: limit)
    }

    /// Photos where a NAMED person's face is present AND the person name matches `query`
    /// (case-insensitive substring). When `query` is empty, returns photos for any named person.
    public func searchPeople(query: String, limit: Int = 200) async throws -> [PhotoAsset] {
        return try await db.dbPool.read { conn in
            if query.isEmpty {
                return try PhotoAsset.fetchAll(conn, sql: """
                    SELECT DISTINCT pa.* FROM photo_assets pa
                    JOIN face_embeddings fe ON fe.photo_id = pa.id
                    JOIN person_identities pi ON pi.id = fe.person_id
                    WHERE pi.name IS NOT NULL AND pi.name != ''
                      AND (pa.hidden_from_library = 0 OR pa.hidden_from_library IS NULL)
                    ORDER BY pa.created_at DESC
                    LIMIT ?
                """, arguments: [limit])
            }
            let pattern = "%\(query)%"
            return try PhotoAsset.fetchAll(conn, sql: """
                SELECT DISTINCT pa.* FROM photo_assets pa
                JOIN face_embeddings fe ON fe.photo_id = pa.id
                JOIN person_identities pi ON pi.id = fe.person_id
                WHERE pi.name IS NOT NULL AND pi.name != ''
                  AND pi.name LIKE ?
                  AND (pa.hidden_from_library = 0 OR pa.hidden_from_library IS NULL)
                ORDER BY pa.created_at DESC
                LIMIT ?
            """, arguments: [pattern, limit])
        }
    }

    /// A named person summary alongside matching count — used to drive the People scope grid.
    public struct PersonMatch: Identifiable, Sendable {
        public let id: String          // person_identities.id
        public let name: String
        public let faceCount: Int
        public let representativeFaceId: String?
        public let representativePhotoId: String?
    }

    /// People whose names match `query`, with their total photo counts.
    /// Returns all named people when `query` is empty.
    public func searchPeopleGrouped(query: String, limit: Int = 100) async throws -> [PersonMatch] {
        return try await db.dbPool.read { conn in
            let sql: String
            let args: StatementArguments
            if query.isEmpty {
                sql = """
                    SELECT pi.id, pi.name, COUNT(fe.id) as cnt,
                           (SELECT fe2.id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_face_id,
                           (SELECT fe2.photo_id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_photo_id
                    FROM person_identities pi
                    JOIN face_embeddings fe ON fe.person_id = pi.id
                    WHERE pi.name IS NOT NULL AND pi.name != ''
                    GROUP BY pi.id, pi.name
                    ORDER BY cnt DESC
                    LIMIT ?
                """
                args = [limit]
            } else {
                sql = """
                    SELECT pi.id, pi.name, COUNT(fe.id) as cnt,
                           (SELECT fe2.id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_face_id,
                           (SELECT fe2.photo_id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_photo_id
                    FROM person_identities pi
                    JOIN face_embeddings fe ON fe.person_id = pi.id
                    WHERE pi.name IS NOT NULL AND pi.name != '' AND pi.name LIKE ?
                    GROUP BY pi.id, pi.name
                    ORDER BY cnt DESC
                    LIMIT ?
                """
                args = ["%\(query)%", limit]
            }
            let rows = try Row.fetchAll(conn, sql: sql, arguments: args)
            return rows.map {
                PersonMatch(
                    id: $0["id"] as String,
                    name: $0["name"] as String,
                    faceCount: $0["cnt"] as Int,
                    representativeFaceId: $0["rep_face_id"] as String?,
                    representativePhotoId: $0["rep_photo_id"] as String?
                )
            }
        }
    }

    /// Photos that have GPS in EXIF. When `query` is non-empty, further filters to photos
    /// where the EXIF JSON blob mentions the query as a substring (acts as a place-name filter
    /// since reverse-geocoded names are often stored there).
    public func searchPlaces(query: String, limit: Int = 500) async throws -> [PhotoAsset] {
        return try await db.dbPool.read { conn in
            // raw_exif_json that contains GPS coordinates (heuristic LIKE match is fine —
            // the view layer re-parses with the GPS helper to drop any false positives).
            if query.isEmpty {
                return try PhotoAsset.fetchAll(conn, sql: """
                    SELECT * FROM photo_assets
                    WHERE (raw_exif_json LIKE '%GPSLatitude%' OR raw_exif_json LIKE '%GPSLongitude%')
                      AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                    ORDER BY created_at DESC
                    LIMIT ?
                """, arguments: [limit])
            }
            let pattern = "%\(query)%"
            return try PhotoAsset.fetchAll(conn, sql: """
                SELECT * FROM photo_assets
                WHERE (raw_exif_json LIKE '%GPSLatitude%' OR raw_exif_json LIKE '%GPSLongitude%')
                  AND raw_exif_json LIKE ?
                  AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                ORDER BY created_at DESC
                LIMIT ?
            """, arguments: [pattern, limit])
        }
    }

    /// A camera make/model aggregate row for the Cameras scope list.
    public struct CameraMatch: Identifiable, Sendable {
        public let id: String              // model (used as stable id)
        public let make: String?
        public let model: String
        public let photoCount: Int
    }

    /// Return camera make/model aggregates. Names are extracted from `raw_exif_json` in-memory
    /// because EXIF key casing varies and SQLite has no JSON_EXTRACT guarantee across builds.
    public func searchCameras(query: String, limit: Int = 5000) async throws -> [CameraMatch] {
        // Pull the EXIF JSON column for candidate photos and aggregate in Swift.
        let rows: [(make: String?, model: String)] = try await db.dbPool.read { conn in
            let sql: String
            let args: StatementArguments
            if query.isEmpty {
                sql = """
                    SELECT raw_exif_json FROM photo_assets
                    WHERE raw_exif_json IS NOT NULL
                      AND (raw_exif_json LIKE '%Make%' OR raw_exif_json LIKE '%Model%')
                      AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                    LIMIT ?
                """
                args = [limit]
            } else {
                sql = """
                    SELECT raw_exif_json FROM photo_assets
                    WHERE raw_exif_json IS NOT NULL
                      AND raw_exif_json LIKE ?
                      AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                    LIMIT ?
                """
                args = ["%\(query)%", limit]
            }
            let raw = try Row.fetchAll(conn, sql: sql, arguments: args)
            return raw.compactMap { row -> (make: String?, model: String)? in
                guard let json = row["raw_exif_json"] as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return nil }
                let make = Self.firstString(in: dict, keys: ["Make", "make", "CameraMake", "camera_make"])
                guard let model = Self.firstString(in: dict, keys: ["Model", "model", "CameraModel", "camera_model"]),
                      !model.isEmpty
                else { return nil }
                return (make: make, model: model)
            }
        }

        // If a query is provided, narrow to models that actually contain the query substring
        // (EXIF JSON may match via serial number etc.; this restricts to real matches).
        let needle = query.lowercased()
        let filtered = query.isEmpty
            ? rows
            : rows.filter { ($0.model + " " + ($0.make ?? "")).lowercased().contains(needle) }

        let grouped = Dictionary(grouping: filtered) { $0.model }
        return grouped
            .map { (model, values) -> CameraMatch in
                let make = values.first?.make
                return CameraMatch(id: model, make: make, model: model, photoCount: values.count)
            }
            .sorted { $0.photoCount > $1.photoCount }
    }

    /// Return photos taken with a specific camera model (match against EXIF JSON substring).
    public func photosForCameraModel(_ model: String, limit: Int = 500) async throws -> [PhotoAsset] {
        let pattern = "%\(model)%"
        return try await db.dbPool.read { conn in
            try PhotoAsset.fetchAll(conn, sql: """
                SELECT * FROM photo_assets
                WHERE raw_exif_json LIKE ?
                  AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                ORDER BY created_at DESC
                LIMIT ?
            """, arguments: [pattern, limit])
        }
    }

    /// Photos within an explicit date range (inclusive). Matches against `date_modified` first,
    /// falling back to `created_at` semantics via DESC order. Uses ISO-8601 string comparison
    /// because dates are stored as strings in this schema.
    public func searchDates(startISO: String, endISO: String, limit: Int = 500) async throws -> [PhotoAsset] {
        return try await db.dbPool.read { conn in
            try PhotoAsset.fetchAll(conn, sql: """
                SELECT * FROM photo_assets
                WHERE (COALESCE(date_modified, created_at) >= ?
                       AND COALESCE(date_modified, created_at) <= ?)
                  AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                ORDER BY COALESCE(date_modified, created_at) DESC
                LIMIT ?
            """, arguments: [startISO, endISO, limit])
        }
    }

    /// A date-bucket row for the Dates scope list (year-month grouping).
    public struct DateBucket: Identifiable, Sendable {
        public let id: String        // "YYYY-MM"
        public let year: Int
        public let month: Int        // 1-12
        public let photoCount: Int
    }

    /// Year/month buckets across the library (newest first), optionally constrained by a
    /// pre-parsed date range. When `startISO`/`endISO` are nil, returns all buckets.
    public func dateBuckets(startISO: String? = nil, endISO: String? = nil, limit: Int = 240) async throws -> [DateBucket] {
        return try await db.dbPool.read { conn in
            let sql: String
            let args: StatementArguments
            if let s = startISO, let e = endISO {
                sql = """
                    SELECT substr(COALESCE(date_modified, created_at), 1, 7) AS ym, COUNT(*) AS cnt
                    FROM photo_assets
                    WHERE COALESCE(date_modified, created_at) >= ?
                      AND COALESCE(date_modified, created_at) <= ?
                      AND (hidden_from_library = 0 OR hidden_from_library IS NULL)
                    GROUP BY ym
                    ORDER BY ym DESC
                    LIMIT ?
                """
                args = [s, e, limit]
            } else {
                sql = """
                    SELECT substr(COALESCE(date_modified, created_at), 1, 7) AS ym, COUNT(*) AS cnt
                    FROM photo_assets
                    WHERE (hidden_from_library = 0 OR hidden_from_library IS NULL)
                    GROUP BY ym
                    ORDER BY ym DESC
                    LIMIT ?
                """
                args = [limit]
            }
            let rows = try Row.fetchAll(conn, sql: sql, arguments: args)
            return rows.compactMap { row in
                guard let ym = row["ym"] as? String,
                      ym.count >= 7
                else { return nil }
                let year = Int(ym.prefix(4)) ?? 0
                let month = Int(ym.suffix(2)) ?? 0
                guard year > 0, month > 0 else { return nil }
                return DateBucket(id: ym, year: year, month: month, photoCount: row["cnt"] as Int)
            }
        }
    }

    /// Locate the first present value for any of `keys` in `dict`, returning a non-empty String.
    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for k in keys {
            if let s = dict[k] as? String, !s.isEmpty { return s }
        }
        // Case-insensitive fallback (merge collisions — keep first non-empty).
        var lowered: [String: Any] = [:]
        for (k, v) in dict { lowered[k.lowercased()] = v }
        for k in keys {
            if let s = lowered[k.lowercased()] as? String, !s.isEmpty { return s }
        }
        return nil
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

// MARK: - Dirty rows for AWS sync (rows where aws_synced_at < updated_at)

/// Lightweight DTO surfaced to the AWS sync client for the `photo_assets` table.
/// Only the columns actually needed for a push payload are exposed; the full
/// `PhotoAsset` record is available via `fetchById` if more fields are needed later.
public struct DirtyPhotoRow: Sendable {
    public let id: String
    public let updatedAt: String
    public let curationState: String
    public let rawExifJson: String?
    public let userMetadataJson: String?
    public let isGrayscale: Bool?
    public let sceneType: String?

    public init(
        id: String,
        updatedAt: String,
        curationState: String,
        rawExifJson: String?,
        userMetadataJson: String?,
        isGrayscale: Bool?,
        sceneType: String?
    ) {
        self.id = id
        self.updatedAt = updatedAt
        self.curationState = curationState
        self.rawExifJson = rawExifJson
        self.userMetadataJson = userMetadataJson
        self.isGrayscale = isGrayscale
        self.sceneType = sceneType
    }
}

extension MobilePhotoRepository {
    /// Rows whose local `updated_at` is newer than the last successful AWS push
    /// (or that have never been pushed). Ordered oldest-change-first so the sync
    /// client drains a FIFO queue.
    public func fetchDirtyPhotosForAWS(limit: Int = 200) async throws -> [DirtyPhotoRow] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, updated_at, curation_state,
                       raw_exif_json, user_metadata_json, is_grayscale, scene_type
                FROM photo_assets
                WHERE aws_synced_at IS NULL OR aws_synced_at < updated_at
                ORDER BY updated_at ASC
                LIMIT ?
            """, arguments: [limit])
            return rows.map { row in
                DirtyPhotoRow(
                    id: row["id"] as String,
                    updatedAt: row["updated_at"] as String,
                    curationState: row["curation_state"] as String,
                    rawExifJson: row["raw_exif_json"] as String?,
                    userMetadataJson: row["user_metadata_json"] as String?,
                    isGrayscale: (row["is_grayscale"] as Int?).map { $0 == 1 },
                    sceneType: row["scene_type"] as String?
                )
            }
        }
    }

    /// Mark the given photo ids as successfully synced to AWS and bump their version counter.
    /// No-op for an empty id list.
    public func markPhotosAWSSynced(ids: [String], syncedAt: String) async throws {
        guard !ids.isEmpty else { return }
        try await db.dbPool.write { conn in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            var args: [any DatabaseValueConvertible] = [syncedAt]
            args.append(contentsOf: ids)
            try conn.execute(
                sql: """
                    UPDATE photo_assets
                       SET aws_synced_at = ?, aws_version = aws_version + 1
                     WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(args)
            )
        }
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

    // MARK: - Face/Person review reads

    public struct UnnamedCluster: Identifiable, Sendable {
        public let id: String               // person_identities.id
        public let faceCount: Int
        public let representativeFaceId: String?
        public let representativePhotoId: String?
    }

    /// Clusters that exist but have no name yet. Largest clusters first.
    public func fetchUnnamedClusters(limit: Int = 50) async throws -> [UnnamedCluster] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT pi.id, COUNT(fe.id) as cnt,
                       (SELECT fe2.id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_face_id,
                       (SELECT fe2.photo_id FROM face_embeddings fe2 WHERE fe2.person_id = pi.id LIMIT 1) as rep_photo_id
                FROM person_identities pi
                JOIN face_embeddings fe ON fe.person_id = pi.id
                WHERE pi.name IS NULL OR pi.name = ''
                GROUP BY pi.id
                ORDER BY cnt DESC
                LIMIT ?
            """, arguments: [limit])
            return rows.map {
                UnnamedCluster(
                    id: $0["id"] as String,
                    faceCount: $0["cnt"] as Int,
                    representativeFaceId: $0["rep_face_id"] as String?,
                    representativePhotoId: $0["rep_photo_id"] as String?
                )
            }
        }
    }

    /// Face embeddings flagged for human review (tentative auto-assignments).
    public func fetchFacesNeedingReview(limit: Int = 100) async throws -> [FaceEmbedding] {
        try await db.dbPool.read { conn in
            try FaceEmbedding.fetchAll(conn, sql: """
                SELECT * FROM face_embeddings
                WHERE needs_review = 1
                ORDER BY created_at DESC
                LIMIT ?
            """, arguments: [limit])
        }
    }

    /// All face embeddings assigned to a given cluster.
    public func fetchFacesForCluster(personId: String, limit: Int = 200) async throws -> [FaceEmbedding] {
        try await db.dbPool.read { conn in
            try FaceEmbedding.fetchAll(conn, sql: """
                SELECT * FROM face_embeddings
                WHERE person_id = ?
                ORDER BY created_at DESC
                LIMIT ?
            """, arguments: [personId, limit])
        }
    }

    /// Faces detected in a specific photo, joined with any assigned person name.
    public struct PhotoFace: Identifiable, Sendable {
        public let id: String               // face_embeddings.id
        public let photoId: String
        public let bboxX: Double
        public let bboxY: Double
        public let bboxWidth: Double
        public let bboxHeight: Double
        public let personId: String?
        public let personName: String?      // nil or empty = unknown
        public let needsReview: Bool
    }

    public func fetchFacesForPhoto(photoId: String) async throws -> [PhotoFace] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT fe.id, fe.photo_id, fe.bbox_x, fe.bbox_y, fe.bbox_width, fe.bbox_height,
                       fe.person_id, fe.needs_review, pi.name as person_name
                FROM face_embeddings fe
                LEFT JOIN person_identities pi ON pi.id = fe.person_id
                WHERE fe.photo_id = ?
                ORDER BY fe.face_index ASC
            """, arguments: [photoId])
            return rows.map {
                PhotoFace(
                    id: $0["id"] as String,
                    photoId: $0["photo_id"] as String,
                    bboxX: $0["bbox_x"] as Double,
                    bboxY: $0["bbox_y"] as Double,
                    bboxWidth: $0["bbox_width"] as Double,
                    bboxHeight: $0["bbox_height"] as Double,
                    personId: $0["person_id"] as String?,
                    personName: $0["person_name"] as String?,
                    needsReview: ($0["needs_review"] as Int?) == 1
                )
            }
        }
    }

    // MARK: - Face/Person mutations (local DB only — caller enqueues PeopleSyncDelta)

    /// Rename an existing person cluster. Local write only.
    public func renamePerson(id: String, name: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: "UPDATE person_identities SET name = ? WHERE id = ?",
                arguments: [name, id]
            )
        }
    }

    /// Insert a new named person. Returns the new id (UUID).
    /// Caller should use the matching PeopleSyncDelta.createPerson factory to enqueue.
    public func createPerson(id: String, name: String, coverFaceId: String?, createdAt: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: """
                    INSERT OR IGNORE INTO person_identities
                        (id, name, cover_face_embedding_id, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [id, name, coverFaceId, createdAt, createdAt]
            )
        }
    }

    /// Delete a person cluster. Null-outs face assignments first (no cascade), then removes the identity.
    public func deletePerson(id: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: "UPDATE face_embeddings SET person_id = NULL, labeled_by = NULL WHERE person_id = ?",
                arguments: [id]
            )
            try conn.execute(
                sql: "DELETE FROM person_identities WHERE id = ?",
                arguments: [id]
            )
        }
    }

    /// Merge `source` into `target`: reassign all faces, then delete source identity.
    public func mergePeople(sourceId: String, targetId: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: "UPDATE face_embeddings SET person_id = ? WHERE person_id = ?",
                arguments: [targetId, sourceId]
            )
            try conn.execute(
                sql: "DELETE FROM person_identities WHERE id = ?",
                arguments: [sourceId]
            )
        }
    }

    /// Assign a face to a person (user-labeled by default).
    public func assignFace(faceId: String, personId: String, labeledBy: String = "user") async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: """
                    UPDATE face_embeddings
                       SET person_id = ?, labeled_by = ?, needs_review = 0
                     WHERE id = ?
                """,
                arguments: [personId, labeledBy, faceId]
            )
        }
    }

    /// Remove a face's assignment to any person.
    public func unassignFace(faceId: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: """
                    UPDATE face_embeddings
                       SET person_id = NULL, labeled_by = NULL, needs_review = 0
                     WHERE id = ?
                """,
                arguments: [faceId]
            )
        }
    }
}

// MARK: - Dirty rows for AWS sync — people + faces

/// Lightweight DTO for a `person_identities` row that needs pushing to AWS.
public struct DirtyPersonRow: Sendable {
    public let id: String
    public let name: String?
    public let coverFaceEmbeddingId: String?
    public let updatedAt: String

    public init(id: String, name: String?, coverFaceEmbeddingId: String?, updatedAt: String) {
        self.id = id
        self.name = name
        self.coverFaceEmbeddingId = coverFaceEmbeddingId
        self.updatedAt = updatedAt
    }
}

/// Lightweight DTO for a `face_embeddings` row that needs pushing to AWS.
/// `face_embeddings` has no `updated_at` column in the iOS minimal schema, so
/// `createdAt` doubles as the freshness marker; the sync client treats any row
/// with `aws_synced_at IS NULL OR aws_synced_at < created_at` as dirty.
public struct DirtyFaceRow: Sendable {
    public let id: String
    public let photoId: String
    public let personId: String?
    public let labeledBy: String?
    public let needsReview: Bool
    public let createdAt: String

    public init(
        id: String,
        photoId: String,
        personId: String?,
        labeledBy: String?,
        needsReview: Bool,
        createdAt: String
    ) {
        self.id = id
        self.photoId = photoId
        self.personId = personId
        self.labeledBy = labeledBy
        self.needsReview = needsReview
        self.createdAt = createdAt
    }
}

extension MobilePeopleRepository {
    /// People clusters whose local `updated_at` is newer than the last AWS push
    /// (or that have never been pushed). Ordered oldest-change-first.
    public func fetchDirtyPeopleForAWS(limit: Int = 200) async throws -> [DirtyPersonRow] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, name, cover_face_embedding_id, updated_at
                FROM person_identities
                WHERE aws_synced_at IS NULL OR aws_synced_at < updated_at
                ORDER BY updated_at ASC
                LIMIT ?
            """, arguments: [limit])
            return rows.map { row in
                DirtyPersonRow(
                    id: row["id"] as String,
                    name: row["name"] as String?,
                    coverFaceEmbeddingId: row["cover_face_embedding_id"] as String?,
                    updatedAt: row["updated_at"] as String
                )
            }
        }
    }

    /// Face embedding rows that have never been pushed to AWS, or that were created
    /// more recently than their last successful push. (`face_embeddings` has no
    /// `updated_at`, so `created_at` is used as the freshness marker.)
    public func fetchDirtyFacesForAWS(limit: Int = 500) async throws -> [DirtyFaceRow] {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(conn, sql: """
                SELECT id, photo_id, person_id, labeled_by, needs_review, created_at
                FROM face_embeddings
                WHERE aws_synced_at IS NULL OR aws_synced_at < created_at
                ORDER BY created_at ASC
                LIMIT ?
            """, arguments: [limit])
            return rows.map { row in
                DirtyFaceRow(
                    id: row["id"] as String,
                    photoId: row["photo_id"] as String,
                    personId: row["person_id"] as String?,
                    labeledBy: row["labeled_by"] as String?,
                    needsReview: (row["needs_review"] as Int?) == 1,
                    createdAt: row["created_at"] as String
                )
            }
        }
    }

    /// Mark the given person ids as successfully synced to AWS.
    public func markPeopleAWSSynced(ids: [String], syncedAt: String) async throws {
        guard !ids.isEmpty else { return }
        try await db.dbPool.write { conn in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            var args: [any DatabaseValueConvertible] = [syncedAt]
            args.append(contentsOf: ids)
            try conn.execute(
                sql: """
                    UPDATE person_identities
                       SET aws_synced_at = ?, aws_version = aws_version + 1
                     WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(args)
            )
        }
    }

    /// Mark the given face ids as successfully synced to AWS.
    public func markFacesAWSSynced(ids: [String], syncedAt: String) async throws {
        guard !ids.isEmpty else { return }
        try await db.dbPool.write { conn in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            var args: [any DatabaseValueConvertible] = [syncedAt]
            args.append(contentsOf: ids)
            try conn.execute(
                sql: """
                    UPDATE face_embeddings
                       SET aws_synced_at = ?, aws_version = aws_version + 1
                     WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(args)
            )
        }
    }
}
