import Foundation
import GRDB
import SwiftUI

// MARK: - AppDatabase (Shared Core)

/// Shared database access layer for both macOS and iOS targets.
/// On macOS: creates/migrates the production database.
/// On iOS: opens a synced copy of the catalog database (read-write).
public final class AppDatabase: @unchecked Sendable {
    public private(set) var dbPool: any DatabaseWriter

    public init(_ dbPool: any DatabaseWriter) {
        self.dbPool = dbPool
    }

    /// Re-open the database connection (e.g. after sync replaces the file).
    /// On iOS, checks for a staged sync file and swaps it in safely.
    public func reload() throws {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        #if os(iOS)
        let folder = appSupport.appendingPathComponent("HoehnPhotos", isDirectory: true)
        #else
        let folder = appSupport.appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
        #endif
        let dbURL = folder.appendingPathComponent("Catalog.db")

        #if os(iOS)
        // Check for staged sync file — swap it in atomically
        let syncedURL = folder.appendingPathComponent("Catalog-synced.db")
        if fm.fileExists(atPath: syncedURL.path) {
            // Close current connection first (release file handles)
            // GRDB DatabasePool doesn't have an explicit close, but replacing dbPool drops the old one
            print("[AppDatabase] Found synced DB, swapping in...")

            // Remove old DB + WAL/SHM files
            for ext in ["", "-wal", "-shm"] {
                let file = dbURL.path + ext
                try? fm.removeItem(atPath: file)
            }
            // Move synced file into place
            try fm.moveItem(at: syncedURL, to: dbURL)
            // Clean up any WAL from synced file
            for ext in ["-wal", "-shm"] {
                let syncWal = syncedURL.path + ext
                try? fm.removeItem(atPath: syncWal)
            }
            print("[AppDatabase] Swapped synced DB into place")
        }
        #endif

        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = normal")
            try db.execute(sql: "PRAGMA temp_store = memory")
        }
        let newPool = try DatabasePool(path: dbURL.path, configuration: config)
        self.dbPool = newPool
        print("[AppDatabase] Reloaded connection to \(dbURL.path)")
    }

    /// Production database path. Platform-specific.
    public static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)

        #if os(iOS)
        let folder = appSupport.appendingPathComponent("HoehnPhotos", isDirectory: true)
        #else
        let folder = appSupport.appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
        #endif

        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = folder.appendingPathComponent("Catalog.db")

        var config = Configuration()
        config.busyMode = .timeout(5)
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = normal")
            try db.execute(sql: "PRAGMA temp_store = memory")
        }

        let pool = try DatabasePool(path: dbURL.path, configuration: config)

        #if os(iOS)
        // On iOS, ensure minimal tables exist for the app to function
        // even before a sync brings the full catalog
        let db = AppDatabase(pool)
        try db.ensureMinimalSchema()
        return db
        #else
        // macOS runs full migrations (defined in the macOS target's AppDatabase extension)
        return AppDatabase(pool)
        #endif
    }

    public static func makeInMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(path: ":memory:")
        let db = AppDatabase(queue)
        try db.ensureMinimalSchema()
        return db
    }

    /// Minimal schema for iOS — creates tables if they don't exist.
    /// When syncing from macOS, the full schema arrives with the database file.
    private func ensureMinimalSchema() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("ios_v1_minimal") { db in
            // photo_assets
            try db.create(table: "photo_assets", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("canonical_name", .text).notNull()
                t.column("role", .text).notNull()
                t.column("file_path", .text).notNull()
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("date_modified", .text)
                t.column("raw_exif_json", .text)
                t.column("user_metadata_json", .text)
                t.column("metadata_edits", .text)
                t.column("processing_state", .text).notNull().defaults(to: "indexed")
                t.column("error_message", .text)
                t.column("curation_state", .text).notNull().defaults(to: "needs_review")
                t.column("sync_state", .text).notNull().defaults(to: "local_only")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
                t.column("file_hash", .text)
                t.column("color_profile", .text)
                t.column("bit_depth", .integer)
                t.column("dpi_x", .real)
                t.column("dpi_y", .real)
                t.column("has_alpha", .boolean)
                t.column("is_grayscale", .boolean)
                t.column("scene_type", .text)
                t.column("people_detected", .boolean)
                t.column("scene_classification_metadata", .text)
                t.column("hidden_from_library", .boolean).defaults(to: false)
                t.column("face_indexed_at", .text)
                t.column("proxy_path", .text)
                t.column("source_drive_uuid", .text)
                t.column("source_drive_path", .text)
                t.column("import_status", .text).defaults(to: "staged")
            }

            // triage_jobs
            try db.create(table: "triage_jobs", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("parent_job_id", .text)
                t.column("title", .text).notNull()
                t.column("source", .text).notNull()
                t.column("status", .text).notNull()
                t.column("inherited_metadata", .text)
                t.column("completeness_score", .real).notNull().defaults(to: 0)
                t.column("photo_count", .integer).notNull().defaults(to: 0)
                t.column("current_milestone", .text).notNull().defaults(to: "triage")
                t.column("triage_completed_at", .text)
                t.column("develop_completed_at", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("completed_at", .datetime)
            }

            // triage_job_photos
            try db.create(table: "triage_job_photos", ifNotExists: true) { t in
                t.column("job_id", .text).notNull()
                t.column("photo_id", .text).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("added_at", .datetime).notNull()
                t.primaryKey(["job_id", "photo_id"])
            }

            // activity_events
            try db.create(table: "activity_events", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("kind", .text).notNull()
                t.column("parent_event_id", .text)
                t.column("photo_asset_id", .text)
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("metadata", .text)
                t.column("occurred_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("saved_search_rule_id", .text)
            }

            // person_identities
            try db.create(table: "person_identities", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
            }

            // studio_revisions
            try db.create(table: "studio_revisions", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_id", .text).notNull()
                t.column("name", .text).notNull()
                t.column("medium", .text).notNull()
                t.column("params_json", .text).notNull().defaults(to: "{}")
                t.column("created_at", .text).notNull()
                t.column("thumbnail_path", .text)
                t.column("full_res_path", .text)
            }

            // face_embeddings
            try db.create(table: "face_embeddings", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_id", .text).notNull()
                t.column("face_index", .integer).notNull()
                t.column("bbox_x", .real).notNull()
                t.column("bbox_y", .real).notNull()
                t.column("bbox_width", .real).notNull()
                t.column("bbox_height", .real).notNull()
                t.column("feature_data", .blob)
                t.column("created_at", .text).notNull()
                t.column("person_id", .text)
                t.column("labeled_by", .text)
                t.column("needs_review", .boolean).defaults(to: false)
            }

            // development_versions
            try db.create(table: "development_versions", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("adjustments_json", .text).notNull()
                t.column("masks_json", .text)
                t.column("is_published", .boolean).notNull().defaults(to: false)
                t.column("is_default", .boolean).notNull().defaults(to: false)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
        }

        try migrator.migrate(dbPool)
    }
}

// MARK: - SwiftUI Environment

private struct AppDatabaseKey: EnvironmentKey {
    public static let defaultValue: AppDatabase? = nil
}

public extension EnvironmentValues {
    public var appDatabase: AppDatabase? {
        get { self[AppDatabaseKey.self] }
        set { self[AppDatabaseKey.self] = newValue }
    }
}
