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
}
