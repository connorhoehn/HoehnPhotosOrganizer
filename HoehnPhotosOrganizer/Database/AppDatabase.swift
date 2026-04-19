import Foundation
import GRDB
import SwiftUI

// MARK: - AppDatabase

final class AppDatabase: Sendable {
    /// DatabaseWriter covers both DatabasePool (production) and DatabaseQueue (in-memory tests).
    let dbPool: any DatabaseWriter

    init(_ dbPool: any DatabaseWriter) {
        self.dbPool = dbPool
    }

    /// Production database in Application Support
    static func makeShared() throws -> AppDatabase {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let folder = appSupport.appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = folder.appendingPathComponent("Catalog.db")
        var config = Configuration()
        config.busyMode = .timeout(5)  // retry for up to 5s if another writer holds the lock
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = normal")
            try db.execute(sql: "PRAGMA temp_store = memory")
            try db.execute(sql: "PRAGMA mmap_size = 134217728")
            try db.execute(sql: "PRAGMA cache_size = -32000")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 1000")
        }
        let pool = try DatabasePool(path: dbURL.path, configuration: config)
        let db = AppDatabase(pool)
        try db.runMigrations()
        return db
    }

    /// In-memory database for unit tests. Uses DatabaseQueue because WAL mode
    /// is not supported for in-memory SQLite connections.
    static func makeInMemory() throws -> AppDatabase {
        let queue = try DatabaseQueue(path: ":memory:")
        let db = AppDatabase(queue)
        try db.runMigrations()
        return db
    }

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.create(table: "photo_assets") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("canonical_name", .text).notNull().unique()
                t.column("role", .text).notNull()
                t.column("file_path", .text).notNull()
                t.column("file_size", .integer).notNull().defaults(to: 0)
                t.column("date_modified", .text)
                t.column("raw_exif_json", .text)
                // user_metadata_json: user-edited fields, kept separate from raw EXIF (META-3)
                t.column("user_metadata_json", .text)
                // metadata_edits: append-only JSON array of {field, oldValue, newValue, editedAt}
                // records enabling full edit history and revert (META-4)
                t.column("metadata_edits", .text)
                t.column("processing_state", .text).notNull().defaults(to: "indexed")
                t.column("error_message", .text)
                t.column("curation_state", .text).notNull().defaults(to: "needs_review")
                t.column("sync_state", .text).notNull().defaults(to: "local_only")
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(table: "proxy_assets") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("file_path", .text).notNull()
                t.column("width", .integer).notNull()
                t.column("height", .integer).notNull()
                t.column("byte_size", .integer).notNull()
                t.column("created_at", .text).notNull()
            }
            try db.create(table: "drives") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("volume_label", .text).notNull().unique()
                t.column("mount_point", .text).notNull()
                t.column("total_bytes", .integer).notNull().defaults(to: 0)
                t.column("free_bytes", .integer).notNull().defaults(to: 0)
                t.column("last_seen", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(table: "activity_log") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("kind", .text).notNull()
                t.column("title", .text).notNull()
                t.column("detail", .text).notNull()
                t.column("photo_id", .text)
                    .references("photo_assets", onDelete: .setNull)
                t.column("timestamp", .text).notNull()
            }
        }

        migrator.registerMigration("v2_lineage") { db in
            try db.create(table: "asset_lineage") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("parent_photo_id", .text)
                    .references("photo_assets", onDelete: .setNull)
                t.column("child_photo_id", .text)
                    .references("photo_assets", onDelete: .cascade)
                t.column("operation", .text).notNull() // e.g. film_strip_extract, edit_export, proxy_generate
                t.column("frame_index", .integer)
                t.column("source_file_name", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("metadata_json", .text)
            }

            try db.create(index: "idx_asset_lineage_parent", on: "asset_lineage", columns: ["parent_photo_id"])
            try db.create(index: "idx_asset_lineage_child", on: "asset_lineage", columns: ["child_photo_id"])

            try db.create(table: "extraction_events") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("source_photo_id", .text)
                    .references("photo_assets", onDelete: .setNull)
                t.column("source_file_name", .text).notNull()
                t.column("orientation", .text).notNull()
                t.column("detector_method", .text).notNull()
                t.column("frame_count", .integer).notNull().defaults(to: 0)
                t.column("manifest_path", .text)
                t.column("created_at", .text).notNull()
            }
        }
        migrator.registerMigration("v3_collections") { db in
            try db.create(table: "collections") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("rules_json", .text)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(table: "collection_members") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("collection_id", .text).notNull()
                    .references("collections", onDelete: .cascade)
                t.column("photo_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("added_at", .text).notNull()
            }

            try db.create(index: "idx_collection_members_collection", on: "collection_members", columns: ["collection_id"])
            try db.create(index: "idx_collection_members_photo", on: "collection_members", columns: ["photo_id"])
            try db.create(index: "idx_photo_assets_curation_state", on: "photo_assets", columns: ["curation_state"])
        }

        migrator.registerMigration("v4_thread_entries") { db in
            try db.create(table: "thread_entries") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("thread_root_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("sequence_number", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("authored_by", .text).notNull()
                t.column("content_json", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("sync_state", .text).notNull().defaults(to: "local_only")
                t.uniqueKey(["thread_root_id", "sequence_number"])
            }

            try db.create(index: "idx_thread_entries_timeline", on: "thread_entries", columns: ["thread_root_id", "sequence_number"])
        }

        migrator.registerMigration("v4_print_attempts") { db in
            // v4_print_attempts assumes v4_thread_entries exists (same version)
            // Print attempts are stored as thread entries of kind "print_attempt"
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS idx_thread_entries_print_attempts
                ON thread_entries(thread_root_id, kind, sequence_number)
                WHERE kind = 'print_attempt'
            """)

            print("✓ v4_print_attempts migration applied: print attempt indexes created")
        }

        migrator.registerMigration("v4_pipelines") { db in
            try db.create(table: "pipeline_definitions") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("purpose", .text).notNull()
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(table: "pipeline_steps") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("pipeline_id", .text).notNull()
                    .references("pipeline_definitions", onDelete: .cascade)
                t.column("step_order", .integer).notNull()
                t.column("step_type", .text).notNull()
                t.column("params_json", .text)
            }
            try db.create(table: "pipeline_runs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("pipeline_id", .text)
                    .references("pipeline_definitions", onDelete: .setNull)
                t.column("source_photo_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("status", .text).notNull()
                t.column("started_at", .text).notNull()
                t.column("completed_at", .text)
                t.column("error_message", .text)
                t.column("output_photo_ids_json", .text)
            }
            try db.create(table: "pipeline_run_steps") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("run_id", .text).notNull()
                    .references("pipeline_runs", onDelete: .cascade)
                t.column("step_order", .integer).notNull()
                t.column("step_type", .text).notNull()
                t.column("status", .text).notNull()
                t.column("detail", .text)
                t.column("started_at", .text).notNull()
                t.column("completed_at", .text)
                t.column("params_json", .text)
            }
            try db.create(index: "idx_pipeline_steps_pipeline", on: "pipeline_steps", columns: ["pipeline_id"])
            try db.create(index: "idx_pipeline_runs_source", on: "pipeline_runs", columns: ["source_photo_id"])
            try db.create(index: "idx_pipeline_run_steps_run", on: "pipeline_run_steps", columns: ["run_id"])
        }

        migrator.registerMigration("v5_asset_technical_fields") { db in
            // AST-6: add technical image metadata fields to photo_assets
            // All columns nullable — existing rows get NULL, populated on next proxy/ingest pass
            try db.alter(table: "photo_assets") { t in
                t.add(column: "file_hash", .text)           // SHA-256 hex string, populated by IngestionActor
                t.add(column: "color_profile", .text)       // e.g. "sRGB", "Display P3", "Adobe RGB"
                t.add(column: "bit_depth", .integer)        // 8, 16, 32
                t.add(column: "dpi_x", .real)               // horizontal DPI from ImageIO
                t.add(column: "dpi_y", .real)               // vertical DPI from ImageIO
                t.add(column: "has_alpha", .boolean)        // SQLite stores as 0/1
                t.add(column: "is_grayscale", .boolean)     // SQLite stores as 0/1
            }
        }

        migrator.registerMigration("v7_embeddings") { db in
            // M7.1: Embedding storage for Ollama nomic-embed-text 768-dim vectors.
            //
            // Preferred approach: sqlite-vec VIRTUAL TABLE (vec0) for efficient vector indexing.
            // Fallback: regular table with JSON array column — allows CPU-based similarity search
            // when sqlite-vec extension is unavailable.
            //
            // We attempt the VIRTUAL TABLE creation. If sqlite-vec is not linked, we fall back
            // to a regular table. This ensures the app starts cleanly on machines without the
            // extension and allows graceful degradation to CPU-based similarity search.
            let sqliteVersion = try String.fetchOne(db, sql: "SELECT sqlite_version()") ?? "0"
            print("[v7_embeddings] SQLite version: \(sqliteVersion)")

            // Attempt sqlite-vec virtual table first (best case: fast vector indexing)
            let vecTableCreated: Bool
            do {
                try db.execute(sql: """
                    CREATE VIRTUAL TABLE IF NOT EXISTS embeddings
                    USING vec0(
                        photo_asset_id TEXT PRIMARY KEY,
                        embedding float[768]
                    )
                """)
                vecTableCreated = true
                print("[v7_embeddings] Created sqlite-vec virtual table (vec0) for embeddings")
            } catch {
                // sqlite-vec not available — fall back to regular table with JSON column
                vecTableCreated = false
                print("[v7_embeddings] sqlite-vec unavailable (\(error.localizedDescription)), using fallback table")
            }

            if !vecTableCreated {
                // Fallback: standard SQLite table with JSON-serialised vector
                // Similarity search runs as in-process Float distance computation (slower but correct)
                try db.create(table: "embeddings", ifNotExists: true) { t in
                    t.column("photo_asset_id", .text).notNull().primaryKey()
                    t.column("embedding_json", .text).notNull()  // JSON [Float] array, 768 elements
                    t.column("created_at", .text).notNull()
                }
                try db.create(
                    index: "idx_embeddings_photo_asset_id",
                    on: "embeddings",
                    columns: ["photo_asset_id"],
                    ifNotExists: true
                )
                print("[v7_embeddings] Created fallback embeddings table with JSON vector column")
            }
        }

        migrator.registerMigration("v8_scene_classification") { db in
            // AI-5/AI-6 (M7.6): Add scene classification and people detection fields.
            // All columns nullable — existing rows get NULL, populated by SceneClassificationService/PersonDetectionService.
            try db.alter(table: "photo_assets") { t in
                t.add(column: "scene_type", .text)                    // SceneType.rawValue: landscape, portrait, etc.
                t.add(column: "people_detected", .boolean)            // true if faces/bodies detected
                t.add(column: "scene_classification_metadata", .text) // JSON confidence/detail blob
            }

            // Indexes for smart album filtering: "photos with people", "landscape scenes", etc.
            try db.create(index: "idx_scene_type", on: "photo_assets", columns: ["scene_type"], ifNotExists: true)
            try db.create(index: "idx_people_detected", on: "photo_assets", columns: ["people_detected"], ifNotExists: true)

            print("[v8_scene_classification] Migration applied: scene_type, people_detected, scene_classification_metadata added to photo_assets")
        }

        migrator.registerMigration("v9_saved_searches") { db in
            // SRCH-7: Smart albums / saved searches — stores SQL predicate strings that are
            // evaluated dynamically against photo_assets as new photos arrive.
            try db.create(table: "saved_searches") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("sql_predicate", .text).notNull().defaults(to: "")  // WHERE clause (empty = all photos)
                t.column("filters_json", .text)   // JSON-encoded SearchFilter for round-trip editing
                t.column("is_active", .boolean).notNull().defaults(to: true)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }

            try db.create(index: "idx_saved_searches_name", on: "saved_searches", columns: ["name"])
            try db.create(index: "idx_saved_searches_is_active", on: "saved_searches", columns: ["is_active"])

            print("[v9_saved_searches] Migration applied: saved_searches table created for SRCH-7 smart albums")
        }

        migrator.registerMigration("v6_extraction_tool_logs") { db in
            // CP-1: Persist film extraction tool logs (PipelineToolRun) to database atomically
            // with ExtractionEvent. One row per tool-run step within a single extraction batch.
            try db.create(table: "extraction_tool_logs") { t in
                t.column("id", .text).notNull().primaryKey()             // UUID string
                t.column("extraction_id", .text).notNull()
                    .references("extraction_events", onDelete: .cascade) // FK → extraction_events.id
                t.column("tool_name", .text).notNull()                  // e.g. "VisionRectangles"
                t.column("status", .text).notNull()                      // PipelineToolStatus rawValue
                t.column("detail", .text).notNull()                      // diagnostic message
                t.column("tool_order", .integer).notNull()               // 0-based sequence within batch
                t.column("created_at", .text).notNull()                  // ISO8601
            }

            // Composite index on (extraction_id, tool_order) for fast ordered retrieval by batch.
            try db.create(
                index: "idx_extraction_tool_logs_batch",
                on: "extraction_tool_logs",
                columns: ["extraction_id", "tool_order"]
            )

            print("[v6_extraction_tool_logs] Migration applied: extraction_tool_logs table created for CP-1")
        }

        migrator.registerMigration("v10_background_jobs") { db in
            // OPS-8: Persistent background job state for resumable operations
            try db.create(table: "background_jobs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("type", .text).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("drive_id", .text)
                    .references("drives", onDelete: .setNull)
                t.column("cursor_json", .text)
                t.column("error_message", .text)
                t.column("created_at", .text).notNull()
                t.column("updated_at", .text).notNull()
            }
            try db.create(index: "idx_background_jobs_type_status",
                          on: "background_jobs", columns: ["type", "status"])

            // PRX-10: 300px thumbnail path stored alongside full proxy
            try db.alter(table: "proxy_assets") { t in
                t.add(column: "thumbnail_path", .text)
                t.add(column: "thumbnail_byte_size", .integer)
            }

            // ING-14: Near-duplicate detection columns for Vision feature print grouping
            try db.alter(table: "photo_assets") { t in
                t.add(column: "perceptual_hash_json", .text)
                t.add(column: "duplicate_group_id", .text)
            }
            try db.create(index: "idx_duplicate_group",
                          on: "photo_assets", columns: ["duplicate_group_id"],
                          ifNotExists: true)

            print("[v10_background_jobs] Migration applied: background_jobs table, thumbnail columns, duplicate detection columns")
        }

        migrator.registerMigration("v11_lineage_crop_rect") { db in
            try db.alter(table: "asset_lineage") { t in
                t.add(column: "crop_rect_x", .real)
                t.add(column: "crop_rect_y", .real)
                t.add(column: "crop_rect_w", .real)
                t.add(column: "crop_rect_h", .real)
            }
            print("[v11_lineage_crop_rect] Migration applied: crop rect columns added to asset_lineage")
        }

        migrator.registerMigration("v12_hidden_from_library") { db in
            // Parent scans extracted from film strips are kept forever in the catalog
            // but hidden from the main library grid. hidden_from_library = true marks
            // these source assets so they are reachable via lineage / RefineFrameSheet
            // without cluttering the photo library.
            try db.alter(table: "photo_assets") { t in
                t.add(column: "hidden_from_library", .boolean).notNull().defaults(to: false)
            }
            print("[v12_hidden_from_library] Migration applied: hidden_from_library column added to photo_assets")
        }

        migrator.registerMigration("v13_photo_adjustments") { db in
            // ADJ-1: Non-destructive adjustment state stored as JSON per photo.
            // The DB is the source of truth for slider state; DNG/XMP are export artifacts.
            // NULL means "no adjustments applied yet" (identity / all-zero).
            try db.alter(table: "photo_assets") { t in
                t.add(column: "adjustments_json", .text)
            }
            print("[v13_photo_adjustments] Migration applied: adjustments_json column added to photo_assets")
        }

        migrator.registerMigration("v14_adjustment_snapshots") { db in
            // SNAP-1: Immutable adjustment snapshot log for rollback support.
            // Every time the user saves adjustments, a new row is appended here.
            // Existing snapshots are never mutated — this is an append-only ledger.
            try db.create(table: "adjustment_snapshots", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_asset_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("label", .text)
                t.column("adjustment_json", .text).notNull()
                t.column("thumbnail_path", .text)
                t.column("is_current_state", .boolean).notNull().defaults(to: false)
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_adjustment_snapshots_photo",
                          on: "adjustment_snapshots", columns: ["photo_asset_id", "created_at"])
            print("[v14_adjustment_snapshots] Migration applied: adjustment_snapshots table created for SNAP-1")
        }

        migrator.registerMigration("v15_face_embeddings") { db in
            // FACE-1: Per-face feature prints for identity-based face search.
            // Each row is one detected face in one photo. feature_data holds raw Float32 bytes
            // from VNGenerateImageFeaturePrintRequest for cosine similarity queries.
            try db.create(table: "face_embeddings", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("face_index", .integer).notNull()
                t.column("bbox_x", .double).notNull()
                t.column("bbox_y", .double).notNull()
                t.column("bbox_width", .double).notNull()
                t.column("bbox_height", .double).notNull()
                t.column("feature_data", .blob)
                t.column("created_at", .text).notNull()
            }
            try db.create(index: "idx_face_embeddings_photo_id", on: "face_embeddings",
                          columns: ["photo_id"], ifNotExists: true)
            print("[v15_face_embeddings] Migration applied: face_embeddings table created")
        }

        migrator.registerMigration("v16_activity_threading") { db in
            // Phase 10: Threaded activity event log.
            // Replaces the flat activity_log (v1) with a fully typed, self-referencing event table.
            // The old activity_log table is left intact; this table is additive.
            try db.create(table: "activity_events", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("kind", .text).notNull()
                t.column("parent_event_id", .text).references("activity_events", onDelete: .cascade)
                t.column("photo_asset_id", .text).references("photo_assets", onDelete: .setNull)
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("metadata", .text)   // JSON blob for kind-specific data
                t.column("occurred_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
            }
            try db.create(index: "idx_activity_events_parent",
                          on: "activity_events", columns: ["parent_event_id"])
            try db.create(index: "idx_activity_events_photo",
                          on: "activity_events", columns: ["photo_asset_id", "occurred_at"])
            try db.create(index: "idx_activity_events_occurred",
                          on: "activity_events", columns: ["occurred_at"])

            // Phase 10: Per-photo todo list items.
            try db.create(table: "todo_items", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_asset_id", .text).notNull().references("photo_assets", onDelete: .cascade)
                t.column("body", .text).notNull()
                t.column("is_completed", .boolean).notNull().defaults(to: false)
                t.column("completed_at", .datetime)
                t.column("created_at", .datetime).notNull()
                t.column("sort_order", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_todo_items_photo",
                          on: "todo_items", columns: ["photo_asset_id", "sort_order"])

            print("[v16_activity_threading] Migration applied: activity_events and todo_items tables created")
        }

        migrator.registerMigration("v17_person_identities") { db in
            // FACE-2: Named person identities for face labeling.
            // person_identities: ground-truth named people.
            // face_embeddings gains person_id (FK), labeled_by, needs_review.
            try db.create(table: "person_identities", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("name", .text).notNull()
                t.column("cover_face_embedding_id", .text) // decorative FK, no cascade
                t.column("created_at", .text).notNull()
            }
            try db.create(index: "idx_person_identities_name",
                          on: "person_identities", columns: ["name"], ifNotExists: true)

            try db.alter(table: "face_embeddings") { t in
                t.add(column: "person_id", .text)        // FK → person_identities.id (no cascade needed)
                t.add(column: "labeled_by", .text)       // "user" | "embedding" | "claude" | nil
                t.add(column: "needs_review", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "idx_face_embeddings_person_id",
                          on: "face_embeddings", columns: ["person_id"], ifNotExists: true)
            try db.create(index: "idx_face_embeddings_needs_review",
                          on: "face_embeddings", columns: ["needs_review"], ifNotExists: true)

            print("[v17_person_identities] Migration applied: person_identities table + labeling columns on face_embeddings")
        }

        migrator.registerMigration("v18_event_outbox") { db in
            try db.create(table: "event_outbox", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("kind", .text).notNull()
                t.column("photo_asset_id", .text)
                t.column("parent_event_id", .text)
                t.column("title", .text).notNull()
                t.column("detail", .text)
                t.column("metadata", .text)
                t.column("occurred_at", .datetime).notNull()
                t.column("created_at", .datetime).notNull()
                t.column("status", .text).notNull().defaults(to: "pending")
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("last_error", .text)
                t.column("processed_at", .datetime)
            }
            try db.create(index: "idx_event_outbox_status",
                          on: "event_outbox", columns: ["status"], ifNotExists: true)
            try db.create(index: "idx_event_outbox_photo",
                          on: "event_outbox", columns: ["photo_asset_id"], ifNotExists: true)
            print("[v18_event_outbox] Migration applied: event_outbox table created for durable event delivery")
        }

        migrator.registerMigration("v19_face_indexed_at") { db in
            try db.alter(table: "photo_assets") { t in
                t.add(column: "face_indexed_at", .text)
            }
            print("[v19_face_indexed_at] Migration applied: face_indexed_at column on photo_assets")
        }

        migrator.registerMigration("v20_drive_proxy_fields") { db in
            try db.alter(table: "photo_assets") { t in
                t.add(column: "proxy_path", .text)
                t.add(column: "source_drive_uuid", .text)
                t.add(column: "source_drive_path", .text)
            }
            try db.create(index: "idx_photo_assets_source_drive_uuid",
                          on: "photo_assets", columns: ["source_drive_uuid"],
                          ifNotExists: true)
            print("[v20_drive_proxy_fields] Migration applied")
        }

        migrator.registerMigration("v21_mask_layers") { db in
            try db.alter(table: "photo_assets") { t in
                t.add(column: "masks_json", .text)
            }
            print("[v21_mask_layers] Migration applied: masks_json column added to photo_assets")
        }

        // v22: Cross-reference FKs connecting thread_entries ↔ activity_events ↔ saved_searches
        migrator.registerMigration("v22_cross_references") { db in
            // Link thread entries (print attempts, notes, etc.) to the activity event that created them
            try db.alter(table: "thread_entries") { t in
                t.add(column: "activity_event_id", .text)
            }
            // Link activity events to the saved search rule that triggered them
            try db.alter(table: "activity_events") { t in
                t.add(column: "saved_search_rule_id", .text)
            }
            try db.create(index: "idx_thread_entries_activity_event",
                          on: "thread_entries", columns: ["activity_event_id"],
                          ifNotExists: true)
            try db.create(index: "idx_activity_events_saved_search",
                          on: "activity_events", columns: ["saved_search_rule_id"],
                          ifNotExists: true)
            print("[v22_cross_references] Migration applied: activity_event_id on thread_entries, saved_search_rule_id on activity_events")
        }

        // v23: API call log table for cost tracking
        migrator.registerMigration("v23_api_call_logs") { db in
            try db.create(table: "api_call_logs") { t in
                t.column("id", .text).primaryKey()
                t.column("model", .text).notNull()
                t.column("label", .text).notNull()
                t.column("input_tokens", .integer).notNull().defaults(to: 0)
                t.column("output_tokens", .integer).notNull().defaults(to: 0)
                t.column("estimated_cost_usd", .double).notNull().defaults(to: 0)
                t.column("duration_ms", .integer).notNull().defaults(to: 0)
                t.column("called_at", .datetime).notNull()
            }
            try db.create(index: "idx_api_call_logs_called_at",
                          on: "api_call_logs", columns: ["called_at"],
                          ifNotExists: true)
            print("[v23_api_call_logs] Migration applied: api_call_logs table created")
        }

        // v24: Non-destructive editing — preserve original file path and store masks in snapshots
        migrator.registerMigration("v24_nondestructive_editing") { db in
            // Track the pristine original so bakes always start from untouched pixels
            try db.alter(table: "photo_assets") { t in
                t.add(column: "original_file_path", .text)
            }
            // Store mask state in each snapshot so rollback restores full editing state
            try db.alter(table: "adjustment_snapshots") { t in
                t.add(column: "masks_json", .text)
            }
            print("[v24_nondestructive_editing] Migration applied: original_file_path on photo_assets, masks_json on adjustment_snapshots")
        }

        // v25: Segmentation cache for auto-detect masks — avoids re-running Vision on revisit
        migrator.registerMigration("v25_segmentation_cache") { db in
            try db.create(table: "segmentation_cache", ifNotExists: true) { t in
                t.column("photo_asset_id", .text).notNull().primaryKey()
                t.column("segments_json", .text).notNull()
                t.column("created_at", .datetime).notNull()
            }
            print("[v25_segmentation_cache] Migration applied: segmentation_cache table created")
        }

        // v26: Triage jobs — hierarchical job queue for post-import photo triage
        migrator.registerMigration("v26_triage_jobs") { db in
            try db.create(table: "triage_jobs") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("parent_job_id", .text).references("triage_jobs", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "import_batch")
                t.column("status", .text).notNull().defaults(to: "open")
                t.column("inherited_metadata", .text)
                t.column("completeness_score", .double).notNull().defaults(to: 0.0)
                t.column("photo_count", .integer).notNull().defaults(to: 0)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("completed_at", .datetime)
            }
            try db.create(index: "idx_triage_jobs_parent", on: "triage_jobs", columns: ["parent_job_id"])
            try db.create(index: "idx_triage_jobs_status", on: "triage_jobs", columns: ["status"])

            try db.create(table: "triage_job_photos") { t in
                t.column("job_id", .text).notNull().references("triage_jobs", onDelete: .cascade)
                t.column("photo_id", .text).notNull().references("photo_assets", onDelete: .cascade)
                t.column("sort_order", .integer).notNull().defaults(to: 0)
                t.column("added_at", .datetime).notNull()
                t.primaryKey(["job_id", "photo_id"])
            }
            try db.create(index: "idx_triage_job_photos_photo", on: "triage_job_photos", columns: ["photo_id"])

            print("[v26_triage_jobs] Migration applied: triage_jobs + triage_job_photos tables created")
        }

        // v27: Sync state tracking — per-photo sync status + global incremental sync metadata
        migrator.registerMigration("v27_sync_state") { db in
            // Per-photo sync status tracking
            try db.alter(table: "photo_assets") { t in
                t.add(column: "sync_status", .text).notNull().defaults(to: "localOnly")
                t.add(column: "last_synced_at", .text)   // ISO8601, nil = never synced
                t.add(column: "sync_error", .text)        // nil = no error
            }

            // Global sync metadata table for incremental sync tracking
            try db.create(table: "sync_metadata", ifNotExists: true) { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
                t.column("updated_at", .text).notNull()  // ISO8601
            }

            print("[v27_sync_state] Migration applied")
        }

        // v28: Import staging — photos start as "staged", only visible in Library after job commit
        migrator.registerMigration("v28_import_status") { db in
            try db.alter(table: "photo_assets") { t in
                // Existing photos default to "library" — they're already in the user's library.
                // New imports will be set to "staged" until the job is committed.
                t.add(column: "import_status", .text).notNull().defaults(to: "library")
            }
            print("[v28_import_status] Migration applied")
        }

        // v29: Studio revisions — render metadata tied to source photo
        migrator.registerMigration("v29_studio_revisions") { db in
            try db.create(table: "studio_revisions") { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("photo_id", .text).notNull()
                    .references("photo_assets", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("medium", .text).notNull()
                t.column("brush_size", .double).notNull()
                t.column("detail", .double).notNull()
                t.column("texture", .double).notNull()
                t.column("color_saturation", .double).notNull()
                t.column("contrast", .double).notNull()
                t.column("created_at", .text).notNull()
                t.column("thumbnail_path", .text)
                t.column("full_res_path", .text)
            }
            try db.create(index: "idx_studio_revisions_photo_id",
                          on: "studio_revisions", columns: ["photo_id"])
            print("[v29_studio_revisions] Migration applied")
        }

        migrator.registerMigration("v30_cloudkit_sync_columns") { db in
            // Add ck_synced_at and ck_record_name to every synced table
            // for CloudKit change tracking (Phase A infrastructure).

            // photo_assets
            try db.execute(sql: "ALTER TABLE photo_assets ADD COLUMN ck_synced_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE photo_assets ADD COLUMN ck_record_name TEXT")

            // person_identities
            try db.execute(sql: "ALTER TABLE person_identities ADD COLUMN ck_synced_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE person_identities ADD COLUMN ck_record_name TEXT")

            // face_embeddings
            try db.execute(sql: "ALTER TABLE face_embeddings ADD COLUMN ck_synced_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE face_embeddings ADD COLUMN ck_record_name TEXT")

            // triage_jobs
            try db.execute(sql: "ALTER TABLE triage_jobs ADD COLUMN ck_synced_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE triage_jobs ADD COLUMN ck_record_name TEXT")

            // activity_events
            try db.execute(sql: "ALTER TABLE activity_events ADD COLUMN ck_synced_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE activity_events ADD COLUMN ck_record_name TEXT")

            // studio_revisions
            try db.execute(sql: "ALTER TABLE studio_revisions ADD COLUMN ck_synced_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE studio_revisions ADD COLUMN ck_record_name TEXT")

            // thread_entries
            try db.execute(sql: "ALTER TABLE thread_entries ADD COLUMN ck_synced_at TIMESTAMP")
            try db.execute(sql: "ALTER TABLE thread_entries ADD COLUMN ck_record_name TEXT")

            print("[v30_cloudkit_sync_columns] Migration applied — ck_synced_at + ck_record_name added to 7 tables")
        }

        // v31: Catalog sync columns — updated_at, last_synced_at, deleted_at for incremental sync
        migrator.registerMigration("v31_catalog_sync_columns") { db in
            // 1. Add updated_at to person_identities (backfill from created_at)
            try db.alter(table: "person_identities") { t in
                t.add(column: "updated_at", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE person_identities SET updated_at = created_at")

            // 2. Add updated_at to face_embeddings (backfill from created_at)
            try db.alter(table: "face_embeddings") { t in
                t.add(column: "updated_at", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE face_embeddings SET updated_at = created_at")

            // 3. Add updated_at to studio_revisions (backfill from created_at)
            try db.alter(table: "studio_revisions") { t in
                t.add(column: "updated_at", .text).notNull().defaults(to: "")
            }
            try db.execute(sql: "UPDATE studio_revisions SET updated_at = created_at")

            // 4. Add last_synced_at to synced tables
            try db.alter(table: "person_identities") { t in
                t.add(column: "last_synced_at", .text)
            }
            try db.alter(table: "face_embeddings") { t in
                t.add(column: "last_synced_at", .text)
            }
            try db.alter(table: "studio_revisions") { t in
                t.add(column: "last_synced_at", .text)
            }
            try db.alter(table: "triage_jobs") { t in
                t.add(column: "last_synced_at", .text)
            }

            // 5. Add deleted_at (soft-delete) to synced tables
            try db.alter(table: "photo_assets") { t in
                t.add(column: "deleted_at", .text)
            }
            try db.alter(table: "person_identities") { t in
                t.add(column: "deleted_at", .text)
            }
            try db.alter(table: "face_embeddings") { t in
                t.add(column: "deleted_at", .text)
            }
            try db.alter(table: "studio_revisions") { t in
                t.add(column: "deleted_at", .text)
            }
            try db.alter(table: "triage_jobs") { t in
                t.add(column: "deleted_at", .text)
            }

            print("[v31_catalog_sync_columns] Migration applied — updated_at, last_synced_at, deleted_at added")
        }

        // v32: AWS cloud-sync tracking columns — mirror of the Core
        // `ios_v2_aws_sync_columns` migration so the same CloudPushCoordinator
        // / AWSPullCoordinator can operate against the Mac's full GRDB schema.
        //
        // Each listed table gets:
        //   - aws_synced_at (TEXT, NULL = never synced)
        //   - aws_version   (INTEGER DEFAULT 0, bumped after every successful push)
        //
        // Kept orthogonal to v30_cloudkit_sync_columns (ck_synced_at) and v27
        // (last_synced_at, which is a different "sync path" marker). AWS uses
        // its own pair of columns so either path can advance without stomping
        // on the other's high-water mark.
        migrator.registerMigration("v32_aws_sync_columns") { db in
            let tables = [
                "photo_assets",
                "person_identities",
                "face_embeddings",
                "triage_jobs",
                "activity_events",
            ]
            for table in tables {
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN aws_synced_at TEXT")
                try db.execute(sql: "ALTER TABLE \(table) ADD COLUMN aws_version INTEGER DEFAULT 0")
            }
            print("[v32_aws_sync_columns] Migration applied — aws_synced_at + aws_version added to 5 tables")
        }

        try migrator.migrate(dbPool)
        validateMigrations()
    }

    /// Lightweight post-migration schema check. Logs a clear report so startup
    /// output immediately reveals any column / table drift on a live database.
    private func validateMigrations() {
        do {
            try dbPool.read { db in
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(photo_assets)")
                    .compactMap { $0["name"] as? String }

                let required = ["import_status", "curation_state", "sync_state",
                                "scene_type", "people_detected", "file_hash"]
                let missing = required.filter { !columns.contains($0) }
                if missing.isEmpty {
                    print("[AppDatabase] ✓ Schema validation passed — all required columns present")
                } else {
                    print("[AppDatabase] ✗ Schema validation FAILED — missing columns: \(missing.joined(separator: ", "))")
                }

                // v28 staging counts
                let staged  = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_assets WHERE import_status = 'staged'"))  ?? 0
                let library = (try? Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_assets WHERE import_status = 'library'")) ?? 0
                print("[AppDatabase] ✓ v28 import_status: \(library) library, \(staged) staged")
            }
        } catch {
            print("[AppDatabase] ✗ Schema validation error: \(error)")
        }
    }
}

// MARK: - SwiftUI environment key

private struct AppDatabaseKey: EnvironmentKey {
    static var defaultValue: AppDatabase? { nil }
}

extension EnvironmentValues {
    var appDatabase: AppDatabase? {
        get { self[AppDatabaseKey.self] }
        set { self[AppDatabaseKey.self] = newValue }
    }
}

private struct LibraryViewModelKey: EnvironmentKey {
    static var defaultValue: LibraryViewModel? { nil }
}

extension EnvironmentValues {
    var libraryViewModel: LibraryViewModel? {
        get { self[LibraryViewModelKey.self] }
        set { self[LibraryViewModelKey.self] = newValue }
    }
}
