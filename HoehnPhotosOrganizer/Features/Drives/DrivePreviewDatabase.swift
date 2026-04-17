import Foundation
import GRDB

// MARK: - DrivePreviewDatabase

/// Lightweight per-drive SQLite stored in Application Support, keyed to the volume UUID.
/// Path: ~/Library/Application Support/HoehnPhotosOrganizer/driveIndexes/{uuid}/index.db
final class DrivePreviewDatabase {

    let dbPool: DatabasePool
    let volumeUUID: String

    // MARK: - Directory layout

    static func baseDirectory() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("HoehnPhotosOrganizer/driveIndexes")
    }

    static func indexURL(for uuid: String) -> URL {
        baseDirectory().appendingPathComponent(uuid).appendingPathComponent("index.db")
    }

    static func thumbsURL(for uuid: String) -> URL {
        baseDirectory().appendingPathComponent(uuid).appendingPathComponent("thumbs")
    }

    /// Returns the UUIDs of all drives that have an existing index on disk.
    static func allIndexedUUIDs() -> [String] {
        let base = baseDirectory()
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return items.compactMap { url -> String? in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { return nil }
            let indexFile = url.appendingPathComponent("index.db")
            return FileManager.default.fileExists(atPath: indexFile.path) ? url.lastPathComponent : nil
        }
    }

    // MARK: - Init

    init(volumeUUID: String) throws {
        self.volumeUUID = volumeUUID
        let dbURL = DrivePreviewDatabase.indexURL(for: volumeUUID)
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        dbPool = try DatabasePool(path: dbURL.path)
        try migrate()
    }

    // MARK: - Schema

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "drive_photos", ifNotExists: true) { t in
                t.column("id",             .text).primaryKey().notNull()
                t.column("relative_path",  .text).unique().notNull()
                t.column("filename",       .text).notNull()
                t.column("file_size",      .integer).notNull().defaults(to: 0)
                t.column("capture_date",   .text)
                t.column("width",          .integer)
                t.column("height",         .integer)
                t.column("is_raw",         .integer).notNull().defaults(to: 0)
                t.column("thumbnail_path", .text)
                t.column("indexed_at",     .text).notNull()
                t.column("modified_at",    .text).notNull()
            }
            try db.create(table: "drive_meta", ifNotExists: true) { t in
                t.column("key",   .text).primaryKey().notNull()
                t.column("value", .text).notNull()
            }
            try db.create(
                index: "drive_photos_by_capture_date",
                on: "drive_photos", columns: ["capture_date"]
            )
        }
        migrator.registerMigration("v2_duplicate_groups") { db in
            try db.alter(table: "drive_photos") { t in
                t.add(column: "duplicate_group_id", .text)
            }
            try db.create(
                index: "drive_photos_by_dup_group",
                on: "drive_photos", columns: ["duplicate_group_id"], ifNotExists: true
            )
        }
        migrator.registerMigration("v3_workflow_annotations") { db in
            try db.alter(table: "drive_photos") { t in
                t.add(column: "orientation_degrees", .integer)
                t.add(column: "scene_label",         .text)
                t.add(column: "face_count",          .integer)
                t.add(column: "film_frame_count",    .integer)
                t.add(column: "workflows_run",       .text)
            }
        }
        migrator.registerMigration("v5_film_frame_rects") { db in
            try db.alter(table: "drive_photos") { t in
                t.add(column: "film_frame_rects_json", .text)
            }
        }
        migrator.registerMigration("v6_imported_at") { db in
            try db.alter(table: "drive_photos") { t in
                t.add(column: "imported_at", .text)
            }
        }
        migrator.registerMigration("v7_gps") { db in
            try db.alter(table: "drive_photos") { t in
                t.add(column: "gps_latitude",  .double)
                t.add(column: "gps_longitude", .double)
            }
        }
        // Composite indexes used by the duplicate-detection correlated subqueries.
        // Without these the two UPDATE statements do full-table scans on every row.
        migrator.registerMigration("v4_duplicate_detection_indexes") { db in
            try db.create(
                index: "drive_photos_dup_by_date",
                on: "drive_photos",
                columns: ["filename", "capture_date"],
                ifNotExists: true
            )
            try db.create(
                index: "drive_photos_dup_by_size",
                on: "drive_photos",
                columns: ["filename", "file_size"],
                ifNotExists: true
            )
        }
        try migrator.migrate(dbPool)
    }

    // MARK: - Security-scoped bookmark persistence

    /// Persists a security-scoped bookmark so the sandbox survives app restarts.
    func saveBookmarkData(_ data: Data) async throws {
        try await setMeta(key: "security_bookmark", value: data.base64EncodedString())
    }

    func loadBookmarkData() async -> Data? {
        guard let b64 = await getMeta(key: "security_bookmark") else { return nil }
        return Data(base64Encoded: b64)
    }

    // MARK: - Duplicate detection

    /// Groups files by (filename + captureDate) when EXIF is present, or (filename + fileSize)
    /// when it is not, then stamps each member of a group with a shared `duplicate_group_id`.
    func markDuplicates() async throws {
        try await dbPool.write { db in
            // Clear previous pass
            try db.execute(sql: "UPDATE drive_photos SET duplicate_group_id = NULL")

            // Files WITH an EXIF date — group by filename + capture_date
            try db.execute(sql: """
                UPDATE drive_photos
                SET duplicate_group_id = (
                    SELECT MIN(id) FROM drive_photos d2
                    WHERE d2.filename     = drive_photos.filename
                      AND d2.capture_date = drive_photos.capture_date
                )
                WHERE capture_date IS NOT NULL
                  AND (
                    SELECT COUNT(*) FROM drive_photos d2
                    WHERE d2.filename     = drive_photos.filename
                      AND d2.capture_date = drive_photos.capture_date
                  ) > 1
                """)

            // Files WITHOUT an EXIF date — group by filename + file_size
            try db.execute(sql: """
                UPDATE drive_photos
                SET duplicate_group_id = (
                    SELECT MIN(id) FROM drive_photos d2
                    WHERE d2.filename    = drive_photos.filename
                      AND d2.file_size   = drive_photos.file_size
                      AND d2.capture_date IS NULL
                )
                WHERE capture_date IS NULL
                  AND (
                    SELECT COUNT(*) FROM drive_photos d2
                    WHERE d2.filename    = drive_photos.filename
                      AND d2.file_size   = drive_photos.file_size
                      AND d2.capture_date IS NULL
                  ) > 1
                """)
        }
    }

    func duplicateCount() async -> Int {
        (try? await dbPool.read { db in
            try DrivePhotoRecord
                .filter(Column("duplicate_group_id") != nil)
                .fetchCount(db)
        }) ?? 0
    }

    // MARK: - Meta helpers

    func setMeta(key: String, value: String) async throws {
        try await dbPool.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO drive_meta (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    func getMeta(key: String) async -> String? {
        try? await dbPool.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT value FROM drive_meta WHERE key = ?", arguments: [key]
            )
            return row?["value"]
        }
    }

    // MARK: - Queries

    /// Live stream of all indexed photos ordered by capture date descending.
    /// Includes photos without thumbnails so the grid is browsable immediately after
    /// indexing — cells show a placeholder until thumbnail generation fills them in.
    /// RAW/JPEG sibling deduplication is handled in the view layer (deduplicatedPhotos).
    func allPhotosStream() -> AsyncValueObservation<[DrivePhotoRecord]> {
        ValueObservation
            .tracking { db in
                try DrivePhotoRecord
                    .order(Column("capture_date").desc, Column("modified_at").desc)
                    .fetchAll(db)
            }
            .values(in: dbPool)
    }

    func totalCount() async -> Int {
        (try? await dbPool.read { db in try DrivePhotoRecord.fetchCount(db) }) ?? 0
    }

    func indexedCount() async -> Int {
        (try? await dbPool.read { db in
            try DrivePhotoRecord.filter(Column("thumbnail_path") != nil).fetchCount(db)
        }) ?? 0
    }

    func deleteIndex() throws {
        let url = DrivePreviewDatabase.indexURL(for: volumeUUID)
        try FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
