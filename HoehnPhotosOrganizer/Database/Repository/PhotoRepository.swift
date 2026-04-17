import Foundation
import GRDB

actor PhotoRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Live stream

    /// Live stream of all photos ordered by updated_at DESC.
    /// Emits a new value on every DB change via GRDB ValueObservation.
    /// Returns an AsyncValueObservation which is an AsyncSequence that throws on error.
    func allPhotosStream() -> AsyncValueObservation<[PhotoAsset]> {
        ValueObservation
            .tracking { db in
                try PhotoAsset
                    .filter(Column("hidden_from_library") == false)
                    .filter(Column("import_status") == "library")
                    .order(Column("updated_at").desc)
                    .fetchAll(db)
            }
            .values(in: db.dbPool)
    }

    /// Promotes photos from staging into the library so they appear in the main grid.
    func commitToLibrary(ids: Set<String>) async throws {
        guard !ids.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { conn in
            for id in ids {
                try conn.execute(
                    sql: "UPDATE photo_assets SET import_status = 'library', updated_at = ? WHERE id = ?",
                    arguments: [now, id]
                )
            }
        }
    }

    // MARK: - Writes

    /// Insert or replace on canonical_name conflict (upsert).
    /// Sets updated_at to now on every call.
    func upsert(_ asset: PhotoAsset) async throws {
        var updated = asset
        updated.updatedAt = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            // upsert() generates INSERT ... ON CONFLICT DO UPDATE SET which handles
            // conflicts on any uniqueness constraint, including the canonical_name UNIQUE
            // constraint. This ensures no duplicate rows are created for the same file.
            try updated.upsert(db)
        }
    }

    /// Bulk update `user_metadata_json` for multiple photos in a single transaction.
    /// `updates` maps photo ID → JSON string.
    func bulkUpdateUserMetadata(_ updates: [String: String]) async throws {
        guard !updates.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            for (id, json) in updates {
                try db.execute(
                    sql: "UPDATE photo_assets SET user_metadata_json = ?, updated_at = ? WHERE id = ?",
                    arguments: [json, now, id]
                )
            }
        }
    }

    /// Bump updated_at to trigger GRDB ValueObservation (e.g. after rotating a proxy on disk).
    func touchUpdatedAt(id: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE photo_assets SET updated_at = ? WHERE id = ?",
                arguments: [now, id]
            )
        }
    }

    /// Mark a photo as face-indexed with current timestamp.
    func markFaceIndexed(id: String) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE photo_assets SET face_indexed_at = ?, updated_at = ? WHERE id = ?",
                arguments: [now, now, id]
            )
        }
    }

    /// Clear face_indexed_at for all photos (used before full re-index).
    func clearAllFaceIndexed() async throws {
        try await db.dbPool.write { db in
            try db.execute(sql: "UPDATE photo_assets SET face_indexed_at = NULL")
        }
    }

    /// Fetch photos that have proxies ready but have never been face-indexed.
    func fetchNeedingFaceIndex() async throws -> [PhotoAsset] {
        try await db.dbPool.read { db in
            try PhotoAsset
                .filter(Column("processing_state") == ProcessingState.proxyReady.rawValue)
                .filter(Column("face_indexed_at") == nil)
                .fetchAll(db)
        }
    }

    /// Targeted processing-state update without loading the full record.
    func updateProcessingState(id: String, state: ProcessingState, errorMessage: String? = nil) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE photo_assets
                    SET processing_state = ?, error_message = ?, updated_at = ?
                    WHERE id = ?
                """,
                arguments: [state.rawValue, errorMessage, now, id]
            )
        }
    }

    /// Stamp proxy path and source drive fields on a PhotoAsset after proxy generation.
    func stampProxyFields(id: String, proxyPath: String, sourceDriveUUID: String?, sourceDrivePath: String?) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE photo_assets SET proxy_path = ?, source_drive_uuid = ?, source_drive_path = ?, updated_at = ? WHERE id = ?",
                arguments: [proxyPath, sourceDriveUUID, sourceDrivePath, now, id]
            )
        }
    }

    // MARK: - Reads

    func fetchAll() async throws -> [PhotoAsset] {
        try await db.dbPool.read { db in
            try PhotoAsset
                .filter(Column("hidden_from_library") == false)
                .order(Column("updated_at").desc)
                .fetchAll(db)
        }
    }

    func fetchById(_ id: String) async throws -> PhotoAsset? {
        try await db.dbPool.read { db in
            try PhotoAsset.fetchOne(db, key: id)
        }
    }

    /// Fetch multiple PhotoAsset records by their IDs in a single read transaction.
    /// Preserves no particular order — caller is responsible for re-ranking if needed.
    func fetchByIds(_ ids: [String]) async throws -> [PhotoAsset] {
        guard !ids.isEmpty else { return [] }
        return try await db.dbPool.read { database -> [PhotoAsset] in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let sql = "SELECT * FROM photo_assets WHERE id IN (\(placeholders))"
            return try PhotoAsset.fetchAll(database, sql: sql, arguments: StatementArguments(ids))
        }
    }

    /// Lookup by canonical_name — the camera-assigned filename.
    ///
    /// Used by IngestionActor's resume skip check (ING-4): when iterating a drive
    /// we know the canonical name before we know the internal UUID, so this is
    /// the right key for "have we already indexed this file?" queries.
    func fetchByCanonicalName(_ name: String) async throws -> PhotoAsset? {
        try await db.dbPool.read { db in
            try PhotoAsset
                .filter(Column("canonical_name") == name)
                .fetchOne(db)
        }
    }

    /// Fetch all assets with a given processing state.
    ///
    /// Used by ProxyGenerationActor to pick up proxyPending items and by
    /// IngestionActor to resume interrupted batches.
    func fetchByProcessingState(_ state: ProcessingState) async throws -> [PhotoAsset] {
        try await db.dbPool.read { db in
            try PhotoAsset
                .filter(Column("processing_state") == state.rawValue)
                .fetchAll(db)
        }
    }

    // MARK: - Curation state mutations

    /// Targeted curation-state update for a single photo.
    /// Updates updated_at so observers and sort orders reflect the change.
    func updateCurationState(id: String, state: CurationState) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: """
                    UPDATE photo_assets SET curation_state = ?, updated_at = ? WHERE id = ?
                """,
                arguments: [state.rawValue, now, id]
            )
        }
    }

    /// Remove photo records from the database and move their source files to the Finder Trash.
    /// Proxy/thumbnail files are also trashed if they exist.
    /// Call only after the user confirms — this is not easily undoable from within the app.
    func permanentlyDelete(ids: Set<String>) async throws {
        // Fetch file paths before deleting records
        let assets = try await db.dbPool.read { conn in
            try PhotoAsset.filter(ids.contains(Column("id"))).fetchAll(conn)
        }
        // Delete DB records
        try await db.dbPool.write { conn in
            for id in ids {
                try conn.execute(sql: "DELETE FROM photo_assets WHERE id = ?", arguments: [id])
            }
        }
        // Move source files + proxies to Trash (best-effort)
        for asset in assets {
            let sourceURL = URL(fileURLWithPath: asset.filePath)
            try? FileManager.default.trashItem(at: sourceURL, resultingItemURL: nil)
            let baseName = (asset.canonicalName as NSString).deletingPathExtension
            let proxyURL = ProxyGenerationActor.proxiesDirectory()
                .appendingPathComponent(baseName + ".jpg")
            try? FileManager.default.trashItem(at: proxyURL, resultingItemURL: nil)
        }
    }

    /// Bulk curation-state update — applies the same state to all IDs in a single write transaction.
    /// Efficient for multi-select operations in the review UI.
    func bulkUpdateCurationState(ids: Set<String>, state: CurationState) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { conn in
            for id in ids {
                try conn.execute(
                    sql: """
                        UPDATE photo_assets SET curation_state = ?, updated_at = ? WHERE id = ?
                    """,
                    arguments: [state.rawValue, now, id]
                )
            }
        }
    }

    /// Returns per-state photo counts via a GROUP BY query.
    /// Uses the idx_photo_assets_curation_state index added in v3_collections for efficiency.
    func curationCounts() async throws -> CurationCounts {
        try await db.dbPool.read { conn in
            let rows = try Row.fetchAll(
                conn,
                sql: "SELECT curation_state, COUNT(*) as cnt FROM photo_assets WHERE import_status = 'library' GROUP BY curation_state"
            )
            var keeper = 0, archive = 0, needsReview = 0, rejected = 0, deleted = 0
            for row in rows {
                let stateRaw: String = row["curation_state"]
                let count: Int = row["cnt"]
                switch stateRaw {
                case CurationState.keeper.rawValue:       keeper = count
                case CurationState.archive.rawValue:      archive = count
                case CurationState.needsReview.rawValue:  needsReview = count
                case CurationState.rejected.rawValue:     rejected = count
                case CurationState.deleted.rawValue:      deleted = count
                default: break
                }
            }
            return CurationCounts(keeper: keeper, archive: archive,
                                   needsReview: needsReview, rejected: rejected, deleted: deleted)
        }
    }

    // MARK: - Search

    // MARK: - Search

    /// Shared filter → SQL condition builder used by search, searchCount, and searchPreview.
    private static func buildSearchConditions(
        filter: SearchFilter
    ) -> (conditions: [String], arguments: [DatabaseValueConvertible]) {
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible] = []

        if let loc = filter.location, !loc.isEmpty {
            conditions.append("user_metadata_json LIKE ?")
            arguments.append("%\(loc)%")
        }
        if let yearFrom = filter.yearFrom {
            conditions.append("raw_exif_json LIKE ?")
            arguments.append("%\(yearFrom)%")
        }
        if let yearTo = filter.yearTo {
            conditions.append("raw_exif_json LIKE ?")
            arguments.append("%\(yearTo)%")
        }
        if let cm = filter.cameraModel, !cm.isEmpty {
            conditions.append("(raw_exif_json LIKE ? OR user_metadata_json LIKE ?)")
            arguments.append("%\(cm)%")
            arguments.append("%\(cm)%")
        }
        if let ft = filter.fileType, !ft.isEmpty {
            conditions.append("canonical_name LIKE ?")
            arguments.append("%.\(ft)%")
        }
        if let cs = filter.curationState, !cs.isEmpty {
            conditions.append("curation_state = ?")
            arguments.append(cs)
        }
        if let ps = filter.processingState, !ps.isEmpty {
            conditions.append("processing_state = ?")
            arguments.append(ps)
        }
        if let tod = filter.timeOfDay, !tod.isEmpty {
            conditions.append("user_metadata_json LIKE ?")
            arguments.append("%\(tod)%")
        }
        if let scene = filter.sceneType, !scene.isEmpty {
            conditions.append("scene_type = ?")
            arguments.append(scene)
        }
        if let people = filter.peopleDetected {
            conditions.append("people_detected = ?")
            arguments.append(people ? 1 : 0)
        }
        if let printed = filter.printAttempted {
            if printed {
                conditions.append("EXISTS (SELECT 1 FROM thread_entries WHERE thread_root_id = photo_assets.id AND kind = 'print_attempt')")
            } else {
                conditions.append("NOT EXISTS (SELECT 1 FROM thread_entries WHERE thread_root_id = photo_assets.id AND kind = 'print_attempt')")
            }
        }
        if let kws = filter.keywords, !kws.isEmpty {
            for kw in kws {
                // Split into tokens on non-alphanumeric chars AND camelCase boundaries,
                // then join with % wildcards for fuzzy matching.
                // "TMax 400" → ["T", "Max", "400"] → "%T%Max%400%" matches "Kodak T-Max 400"
                var tokens: [String] = []
                for word in kw.components(separatedBy: CharacterSet.alphanumerics.inverted) where !word.isEmpty {
                    // Split camelCase: "TMax" → ["T", "Max"]
                    var current = ""
                    for (i, char) in word.enumerated() {
                        if char.isUppercase && i > 0 {
                            if !current.isEmpty { tokens.append(current) }
                            current = String(char)
                        } else {
                            current.append(char)
                        }
                    }
                    if !current.isEmpty { tokens.append(current) }
                }
                guard !tokens.isEmpty else { continue }
                let fuzzy = tokens.joined(separator: "%")
                conditions.append("(canonical_name LIKE ? OR raw_exif_json LIKE ? OR user_metadata_json LIKE ?)")
                arguments.append("%\(fuzzy)%")
                arguments.append("%\(fuzzy)%")
                arguments.append("%\(fuzzy)%")
            }
        }

        conditions.append("hidden_from_library = 0")
        conditions.append("import_status = 'library'")
        return (conditions, arguments)
    }

    /// Search photos using a SearchFilter. Optional limit for preview queries.
    func search(filter: SearchFilter, limit: Int? = nil) async throws -> [PhotoAsset] {
        try await db.dbPool.read { db in
            let (conditions, arguments) = Self.buildSearchConditions(filter: filter)
            let limitClause = limit.map { " LIMIT \($0)" } ?? ""
            let sql = "SELECT * FROM photo_assets WHERE \(conditions.joined(separator: " AND ")) ORDER BY updated_at DESC\(limitClause)"
            return try PhotoAsset.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
        }
    }

    /// Lightweight count-only search for conversational feedback.
    func searchCount(filter: SearchFilter) async throws -> Int {
        try await db.dbPool.read { db in
            let (conditions, arguments) = Self.buildSearchConditions(filter: filter)
            let sql = "SELECT COUNT(*) FROM photo_assets WHERE \(conditions.joined(separator: " AND "))"
            return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
        }
    }

    // MARK: - Library stats (for search context)

    /// Aggregate library statistics for injecting into search prompts.
    func libraryStats() async throws -> (
        totalPhotos: Int,
        curationBreakdown: [String: Int],
        dateRange: (earliest: String, latest: String)?,
        sceneDistribution: [(scene: String, count: Int)],
        printJobCount: Int
    ) {
        try await db.dbPool.read { db in
            let totalPhotos = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_assets WHERE hidden_from_library = 0 AND import_status = 'library'") ?? 0

            // Curation breakdown (reuses existing index)
            var curationBreakdown: [String: Int] = [:]
            let curationRows = try Row.fetchAll(db, sql: "SELECT curation_state, COUNT(*) as cnt FROM photo_assets WHERE hidden_from_library = 0 AND import_status = 'library' GROUP BY curation_state")
            for row in curationRows {
                let state: String = row["curation_state"]
                let count: Int = row["cnt"]
                curationBreakdown[state] = count
            }

            // Date range from date_modified
            let dateRange: (String, String)? = {
                guard let row = try? Row.fetchOne(db, sql: "SELECT MIN(date_modified) as earliest, MAX(date_modified) as latest FROM photo_assets WHERE hidden_from_library = 0 AND import_status = 'library' AND date_modified IS NOT NULL"),
                      let earliest: String = row["earliest"],
                      let latest: String = row["latest"] else { return nil }
                // Extract just the year portion
                let earlyYear = String(earliest.prefix(4))
                let lateYear = String(latest.prefix(4))
                return (earlyYear, lateYear)
            }()

            // Scene type distribution
            var sceneDistribution: [(String, Int)] = []
            let sceneRows = try Row.fetchAll(db, sql: "SELECT scene_type, COUNT(*) as cnt FROM photo_assets WHERE hidden_from_library = 0 AND import_status = 'library' AND scene_type IS NOT NULL GROUP BY scene_type ORDER BY cnt DESC")
            for row in sceneRows {
                let scene: String = row["scene_type"]
                let count: Int = row["cnt"]
                sceneDistribution.append((scene, count))
            }

            // Print job count
            let printJobCount = try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT thread_root_id) FROM thread_entries WHERE kind = 'print_attempt'") ?? 0

            return (totalPhotos, curationBreakdown, dateRange, sceneDistribution, printJobCount)
        }
    }
}
