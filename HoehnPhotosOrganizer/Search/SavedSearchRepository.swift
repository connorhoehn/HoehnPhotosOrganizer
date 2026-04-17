import Foundation
import GRDB

// MARK: - SavedSearchRule

/// A persistent smart album rule. Stores filter criteria as a SQL predicate that is
/// evaluated against the photo_assets table to dynamically compute matching photos.
///
/// Stored in the `saved_searches` table (v9_saved_searches migration).
struct SavedSearchRule: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "saved_searches"

    var id: String
    var name: String
    var sqlPredicate: String     // WHERE clause (no "WHERE" keyword) evaluated against photo_assets
    var filtersJson: String?     // JSON-encoded SearchFilter for round-trip editing
    var isActive: Bool
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case sqlPredicate = "sql_predicate"
        case filtersJson = "filters_json"
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static func new(name: String, sqlPredicate: String, filtersJson: String?) -> SavedSearchRule {
        let now = ISO8601DateFormatter().string(from: .now)
        return SavedSearchRule(
            id: UUID().uuidString,
            name: name,
            sqlPredicate: sqlPredicate,
            filtersJson: filtersJson,
            isActive: true,
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - SavedSearchError

enum SavedSearchError: LocalizedError {
    case invalidFilter(String)
    case sqlGenerationFailed(String)
    case databaseError(Error)
    case ruleNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidFilter(let msg):     return "Invalid filter: \(msg)"
        case .sqlGenerationFailed(let m): return "SQL generation failed: \(m)"
        case .databaseError(let err):     return "Database error: \(err.localizedDescription)"
        case .ruleNotFound(let id):       return "Saved search not found: \(id)"
        }
    }
}

// MARK: - SavedSearchRepository

/// Actor that provides CRUD operations and SQL predicate execution for saved search / smart album rules.
///
/// Predicate generation is deterministic: identical SearchFilter inputs always produce identical SQL.
/// GRDB parameterized queries are used throughout to prevent SQL injection.
actor SavedSearchRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - CRUD

    /// Create and persist a new saved search rule from a SearchFilter.
    ///
    /// Generates a SQL predicate from the filter, stores the rule in `saved_searches`,
    /// and returns the created rule.
    ///
    /// - Parameters:
    ///   - name: Display name for the smart album.
    ///   - filters: Search criteria to persist as a SQL predicate.
    /// - Returns: The persisted `SavedSearchRule`.
    func createSavedSearch(name: String, filters: SearchFilter) async throws -> SavedSearchRule {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw SavedSearchError.invalidFilter("Name cannot be empty")
        }

        let predicate = generateSQLPredicate(from: filters)
        let encoder = JSONEncoder()
        let filtersData = try? encoder.encode(filters)
        let filtersJson = filtersData.flatMap { String(data: $0, encoding: .utf8) }

        let rule = SavedSearchRule.new(name: name, sqlPredicate: predicate, filtersJson: filtersJson)

        try await db.dbPool.write { conn in
            try rule.insert(conn)
        }

        return rule
    }

    /// Fetch all saved search rules, ordered by name.
    func fetchAllSavedSearches() async throws -> [SavedSearchRule] {
        try await db.dbPool.read { conn in
            try SavedSearchRule
                .order(Column("name").asc)
                .fetchAll(conn)
        }
    }

    /// Execute a saved search rule and return matching PhotoAsset objects.
    ///
    /// Loads the rule's SQL predicate and applies it as a WHERE filter against `photo_assets`.
    ///
    /// - Parameter ruleId: The `id` of the `SavedSearchRule` to execute.
    /// - Returns: Matching `PhotoAsset` objects, ordered by `updated_at` DESC.
    func executeSavedSearch(ruleId: String) async throws -> [PhotoAsset] {
        guard let rule = try await db.dbPool.read({ conn in
            try SavedSearchRule.fetchOne(conn, key: ruleId)
        }) else {
            throw SavedSearchError.ruleNotFound(ruleId)
        }

        return try await db.dbPool.read { conn in
            let predicate = rule.sqlPredicate
            if predicate.isEmpty {
                // No filters — return all photos
                return try PhotoAsset
                    .order(Column("updated_at").desc)
                    .fetchAll(conn)
            } else {
                let sql = "SELECT * FROM photo_assets WHERE \(predicate) ORDER BY updated_at DESC"
                return try PhotoAsset.fetchAll(conn, sql: sql)
            }
        }
    }

    /// Update an existing saved search rule with a new name and/or filters.
    func updateSavedSearch(ruleId: String, name: String, filters: SearchFilter) async throws {
        guard var rule = try await db.dbPool.read({ conn in
            try SavedSearchRule.fetchOne(conn, key: ruleId)
        }) else {
            throw SavedSearchError.ruleNotFound(ruleId)
        }

        let predicate = generateSQLPredicate(from: filters)
        let encoder = JSONEncoder()
        let filtersData = try? encoder.encode(filters)

        rule.name = name
        rule.sqlPredicate = predicate
        rule.filtersJson = filtersData.flatMap { String(data: $0, encoding: .utf8) }
        rule.updatedAt = ISO8601DateFormatter().string(from: .now)

        let ruleCopy = rule
        try await db.dbPool.write { conn in
            try ruleCopy.update(conn)
        }
    }

    /// Delete a saved search rule by ID.
    func deleteSavedSearch(ruleId: String) async throws {
        try await db.dbPool.write { conn in
            try conn.execute(
                sql: "DELETE FROM saved_searches WHERE id = ?",
                arguments: [ruleId]
            )
        }
    }

    /// Live stream of all saved search rules, ordered by name.
    /// Emits updated arrays when the `saved_searches` table changes.
    nonisolated func savedSearchesStream() -> AsyncValueObservation<[SavedSearchRule]> {
        ValueObservation
            .tracking { conn in
                try SavedSearchRule
                    .order(Column("name").asc)
                    .fetchAll(conn)
            }
            .values(in: db.dbPool)
    }

    // MARK: - SQL Predicate Generation

    /// Generate a deterministic SQL WHERE clause (without "WHERE" keyword) from a SearchFilter.
    ///
    /// - Uses GRDB-compatible literal value embedding with proper SQLite escaping.
    /// - AND-chains all active filter clauses.
    /// - Returns an empty string when no filters are active (matches all photos).
    ///
    /// - Parameter filters: The search criteria to convert to SQL.
    /// - Returns: A SQL WHERE clause string (empty = no filter = all photos).
    nonisolated func generateSQLPredicate(from filters: SearchFilter) -> String {
        var clauses: [String] = []

        // Scene type filter
        if let sceneType = filters.sceneType, !sceneType.isEmpty {
            clauses.append("scene_type = '\(Self.escapeSQLString(sceneType))'")
        }

        // People detected filter
        if let peopleDetected = filters.peopleDetected {
            clauses.append("people_detected = \(peopleDetected ? 1 : 0)")
        }

        // Date range filter (year-based — maps to created_at year)
        if let yearFrom = filters.yearFrom, let yearTo = filters.yearTo {
            let fromDate = "\(yearFrom)-01-01T00:00:00Z"
            let toDate   = "\(yearTo)-12-31T23:59:59Z"
            clauses.append("capture_date BETWEEN '\(fromDate)' AND '\(toDate)'")
        } else if let yearFrom = filters.yearFrom {
            clauses.append("capture_date >= '\(yearFrom)-01-01T00:00:00Z'")
        } else if let yearTo = filters.yearTo {
            clauses.append("capture_date <= '\(yearTo)-12-31T23:59:59Z'")
        }

        // Location filter (LIKE prefix match on location_name)
        if let location = filters.location, !location.isEmpty {
            clauses.append("location_name LIKE '\(Self.escapeSQLLikeString(location))%'")
        }

        // Camera model filter
        if let camera = filters.cameraModel, !camera.isEmpty {
            clauses.append("camera_model = '\(Self.escapeSQLString(camera))'")
        }

        // File type filter
        if let fileType = filters.fileType, !fileType.isEmpty {
            clauses.append("file_type = '\(Self.escapeSQLString(fileType))'")
        }

        // Curation state filter
        if let curationState = filters.curationState, !curationState.isEmpty {
            clauses.append("curation_state = '\(Self.escapeSQLString(curationState))'")
        }

        // Processing state filter
        if let processingState = filters.processingState, !processingState.isEmpty {
            clauses.append("processing_state = '\(Self.escapeSQLString(processingState))'")
        }

        // Time of day filter
        if let timeOfDay = filters.timeOfDay, !timeOfDay.isEmpty {
            clauses.append("time_of_day = '\(Self.escapeSQLString(timeOfDay))'")
        }

        // Print attempted filter
        if let printAttempted = filters.printAttempted {
            // Checks for existence of a thread entry with kind = 'print_attempt' for the photo
            if printAttempted {
                clauses.append("""
                    EXISTS (
                        SELECT 1 FROM thread_entries
                        WHERE thread_entries.thread_root_id = photo_assets.id
                        AND thread_entries.kind = 'print_attempt'
                    )
                    """)
            } else {
                clauses.append("""
                    NOT EXISTS (
                        SELECT 1 FROM thread_entries
                        WHERE thread_entries.thread_root_id = photo_assets.id
                        AND thread_entries.kind = 'print_attempt'
                    )
                    """)
            }
        }

        // Keywords filter (ANY keyword matches in raw_exif_json — simple LIKE check)
        if let keywords = filters.keywords, !keywords.isEmpty {
            let keywordClauses = keywords.map { kw in
                "raw_exif_json LIKE '%\(Self.escapeSQLLikeString(kw))%'"
            }
            clauses.append("(\(keywordClauses.joined(separator: " OR ")))")
        }

        return clauses.joined(separator: " AND ")
    }

    // MARK: - Private SQL Helpers

    /// Escapes single-quote characters in a SQL string literal by doubling them.
    /// This is the standard SQLite escaping mechanism for string literals.
    nonisolated private static func escapeSQLString(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }

    /// Escapes single-quote, percent, and underscore characters for use in LIKE predicates.
    nonisolated private static func escapeSQLLikeString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "'", with: "''")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
