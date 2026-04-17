import Foundation
import GRDB

actor AdjustmentSnapshotRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    /// Persist a new snapshot and mark it as current state.
    /// Clears isCurrentState on all previous snapshots for this photo first.
    func saveSnapshot(_ snapshot: AdjustmentSnapshot) async throws {
        try await db.dbPool.write { db in
            // Clear previous current flag
            try db.execute(
                sql: "UPDATE adjustment_snapshots SET is_current_state = 0 WHERE photo_asset_id = ?",
                arguments: [snapshot.photoAssetId]
            )
            var s = snapshot
            s.isCurrentState = true
            try s.insert(db)
        }
    }

    /// Fetch all snapshots for a photo, oldest first (for timeline display).
    func fetchSnapshots(forPhoto photoId: String) async throws -> [AdjustmentSnapshot] {
        try await db.dbPool.read { db in
            try AdjustmentSnapshot
                .filter(AdjustmentSnapshot.Columns.photoAssetId == photoId)
                .order(AdjustmentSnapshot.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }

    /// Fetch the current (latest) snapshot for a photo.
    func fetchCurrentSnapshot(forPhoto photoId: String) async throws -> AdjustmentSnapshot? {
        try await db.dbPool.read { db in
            try AdjustmentSnapshot
                .filter(AdjustmentSnapshot.Columns.photoAssetId == photoId)
                .filter(AdjustmentSnapshot.Columns.isCurrentState == true)
                .fetchOne(db)
        }
    }

    /// Fetch a single snapshot by ID.
    func fetchSnapshot(id: String) async throws -> AdjustmentSnapshot? {
        try await db.dbPool.read { db in
            try AdjustmentSnapshot.fetchOne(db, key: id)
        }
    }

    /// Delete a specific snapshot by ID.
    /// Returns the deleted snapshot (if found) so callers can clean up associated files.
    @discardableResult
    func deleteSnapshot(id: String) async throws -> AdjustmentSnapshot? {
        try await db.dbPool.write { db in
            let snapshot = try AdjustmentSnapshot.fetchOne(db, key: id)
            _ = try AdjustmentSnapshot.deleteOne(db, key: id)
            return snapshot
        }
    }

    /// Update the thumbnail path for a snapshot.
    func updateThumbnailPath(id: String, path: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE adjustment_snapshots SET thumbnail_path = ? WHERE id = ?",
                arguments: [path, id]
            )
        }
    }

    /// Rename a snapshot's label.
    func renameSnapshot(id: String, newLabel: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE adjustment_snapshots SET label = ? WHERE id = ?",
                arguments: [newLabel, id]
            )
        }
    }

    /// Create an auto-checkpoint snapshot for all photos with adjustments in the given set.
    /// Used before committing staged photos to the library.
    func autoCheckpoint(photoIds: Set<String>, label: String = "Before Library Commit") async throws {
        try await db.dbPool.write { db in
            for photoId in photoIds {
                // Only checkpoint photos that have adjustments
                guard let adjJSON = try String.fetchOne(
                    db,
                    sql: "SELECT adjustments_json FROM photo_assets WHERE id = ?",
                    arguments: [photoId]
                ), !adjJSON.isEmpty else { continue }

                // Read masks too
                let masksJSON = try String.fetchOne(
                    db,
                    sql: "SELECT masks_json FROM photo_assets WHERE id = ?",
                    arguments: [photoId]
                )

                // Clear previous current flag
                try db.execute(
                    sql: "UPDATE adjustment_snapshots SET is_current_state = 0 WHERE photo_asset_id = ?",
                    arguments: [photoId]
                )

                // Insert checkpoint
                var snapshot = AdjustmentSnapshot(
                    id: UUID().uuidString,
                    photoAssetId: photoId,
                    label: label,
                    adjustmentJSON: adjJSON,
                    masksJSON: masksJSON,
                    thumbnailPath: nil,
                    isCurrentState: true,
                    createdAt: Date()
                )
                try snapshot.insert(db)
            }
        }
    }

    /// Live-updating observation of all snapshots for a photo (oldest first).
    /// Use `.values(in:)` to drive SwiftUI or async for-await loops.
    func snapshotsObservation(forPhoto photoId: String) -> ValueObservation<ValueReducers.Fetch<[AdjustmentSnapshot]>> {
        ValueObservation.tracking { db in
            try AdjustmentSnapshot
                .filter(AdjustmentSnapshot.Columns.photoAssetId == photoId)
                .order(AdjustmentSnapshot.Columns.createdAt.asc)
                .fetchAll(db)
        }
    }
}
