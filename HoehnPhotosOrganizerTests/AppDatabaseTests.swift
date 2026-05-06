import Testing
import GRDB
@testable import HoehnPhotosOrganizer

struct AppDatabaseTests {

    @Test
    func testSchemaContainsRequiredColumns() async throws {
        // ING-3: after migrations run, photo_assets table contains
        // id, canonical_name, role, file_path, file_size, date_modified,
        // raw_exif_json, user_metadata_json, metadata_edits,
        // processing_state, error_message, curation_state, sync_state, created_at, updated_at
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let columns = try conn.columns(in: "photo_assets").map(\.name)
            let required = [
                "id", "canonical_name", "role", "file_path", "file_size",
                "date_modified", "raw_exif_json", "user_metadata_json", "metadata_edits",
                "processing_state", "error_message", "curation_state", "sync_state",
                "created_at", "updated_at"
            ]
            for col in required {
                #expect(columns.contains(col), "photo_assets missing column: \(col)")
            }
        }
    }

    @Test
    func testSchemaContainsDriveTable() async throws {
        // ING-3: after migrations run, drives table contains
        // id, volume_label, mount_point, total_bytes, free_bytes, last_seen columns
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let columns = try conn.columns(in: "drives").map(\.name)
            let required = ["id", "volume_label", "mount_point", "total_bytes", "free_bytes", "last_seen"]
            for col in required {
                #expect(columns.contains(col), "drives missing column: \(col)")
            }
        }
    }

    @Test
    func testSchemaContainsCollectionsTable() async throws {
        // CUR-1: v3_collections migration must create collections table with expected columns
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let columns = try conn.columns(in: "collections").map(\.name)
            let required = ["id", "name", "kind", "rules_json", "sort_order", "created_at", "updated_at"]
            for col in required {
                #expect(columns.contains(col), "collections missing column: \(col)")
            }
        }
    }

    @Test
    func testSchemaContainsCollectionMembersTable() async throws {
        // CUR-2: v3_collections migration must create collection_members table with expected columns
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let columns = try conn.columns(in: "collection_members").map(\.name)
            let required = ["id", "collection_id", "photo_id", "added_at"]
            for col in required {
                #expect(columns.contains(col), "collection_members missing column: \(col)")
            }
        }
    }

    @Test
    func testPhotoAssetUniqueConstraint() async throws {
        // canonical_name must be UNIQUE in photo_assets
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.write { conn in
            let asset1 = PhotoAsset.new(canonicalName: "IMG_0001.dng", role: .original,
                                        filePath: "/vol/IMG_0001.dng", fileSize: 10_000_000)
            try asset1.insert(conn)

            let asset2 = PhotoAsset.new(canonicalName: "IMG_0001.dng", role: .original,
                                        filePath: "/vol/IMG_0001.dng", fileSize: 10_000_000)
            #expect(throws: (any Error).self) {
                try asset2.insert(conn)
            }
        }
    }

    // MARK: - v10 migration tests (OPS-8, PRX-10, ING-14)

    @Test
    func testV10BackgroundJobsTableExists() async throws {
        // OPS-8: v10_background_jobs migration must create background_jobs table
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let columns = try conn.columns(in: "background_jobs").map(\.name)
            let required = ["id", "type", "status", "drive_id", "cursor_json",
                            "error_message", "created_at", "updated_at"]
            for col in required {
                #expect(columns.contains(col), "background_jobs missing column: \(col)")
            }
        }
    }

    @Test
    func testV10ProxyAssetsGainsThumbnailColumns() async throws {
        // PRX-10: v10 migration must add thumbnail_path and thumbnail_byte_size to proxy_assets
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let columns = try conn.columns(in: "proxy_assets").map(\.name)
            #expect(columns.contains("thumbnail_path"), "proxy_assets missing thumbnail_path")
            #expect(columns.contains("thumbnail_byte_size"), "proxy_assets missing thumbnail_byte_size")
        }
    }

    @Test
    func testV10PhotoAssetsGainsHashColumns() async throws {
        // ING-14: v10 migration must add perceptual_hash_json and duplicate_group_id to photo_assets
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let columns = try conn.columns(in: "photo_assets").map(\.name)
            #expect(columns.contains("perceptual_hash_json"), "photo_assets missing perceptual_hash_json")
            #expect(columns.contains("duplicate_group_id"), "photo_assets missing duplicate_group_id")
        }
    }

    @Test
    func testAllPriorMigrationsStillPass() async throws {
        // Regression: makeInMemory() must run all migrations v1–v10 without error
        // If this throws, a migration is broken.
        #expect(throws: Never.self) {
            _ = try AppDatabase.makeInMemory()
        }
    }

    // MARK: - v34: aws_sync_cursors (durable pull cursor)

    @Test
    func testV34AwsSyncCursorsTableExists() async throws {
        // v34_pull_cursor: the aws_sync_cursors table must exist so
        // AWSPullCoordinator can persist its cursor across app reinstalls.
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let tables = try String.fetchAll(conn,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='aws_sync_cursors'")
            #expect(tables.count == 1, "aws_sync_cursors table must exist after v34 migration")
        }
    }

    @Test
    func testV34AwsSyncCursorsUpsertRoundTrip() async throws {
        // Verify the table schema supports ON CONFLICT(key) DO UPDATE used by storeLastPulledAt.
        let db = try AppDatabase.makeInMemory()
        let key = "aws.pull.lastPulledAt"
        let value1 = "2026-01-01T00:00:00Z"
        let value2 = "2026-06-01T00:00:00Z"

        try await db.dbPool.write { conn in
            try conn.execute(sql: "INSERT INTO aws_sync_cursors(key, value) VALUES (?, ?)",
                             arguments: [key, value1])
            try conn.execute(sql: """
                INSERT INTO aws_sync_cursors(key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value2])
        }
        let stored = try await db.dbPool.read { conn in
            try String.fetchOne(conn,
                sql: "SELECT value FROM aws_sync_cursors WHERE key = ?",
                arguments: [key])
        }
        #expect(stored == value2, "Upsert must overwrite the existing cursor value")
    }

    // MARK: - v35: photo_assets_fts (FTS5 keyword search)

    @Test
    func testV35FTS5VirtualTableExists() async throws {
        // v35_fts5_search: the photo_assets_fts virtual table must be created
        // by the migration so FTS5 keyword search is available.
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let tables = try String.fetchAll(conn,
                sql: "SELECT name FROM sqlite_master WHERE type='table' AND name='photo_assets_fts'")
            #expect(tables.count == 1, "photo_assets_fts virtual table must exist after v35 migration")
        }
    }

    @Test
    func testV35FTS5TriggersExist() async throws {
        // The three sync triggers (insert / update / delete) must be present so
        // the FTS5 index stays in sync with photo_assets without manual calls.
        let db = try AppDatabase.makeInMemory()
        try await db.dbPool.read { conn in
            let triggers = try String.fetchAll(conn,
                sql: "SELECT name FROM sqlite_master WHERE type='trigger' AND name LIKE 'photo_assets_fts_%'")
            let names = Set(triggers)
            #expect(names.contains("photo_assets_fts_insert"), "INSERT trigger must exist")
            #expect(names.contains("photo_assets_fts_update"), "UPDATE trigger must exist")
            #expect(names.contains("photo_assets_fts_delete"), "DELETE trigger must exist")
        }
    }
}
