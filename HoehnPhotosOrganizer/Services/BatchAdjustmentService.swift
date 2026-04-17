import Foundation
import GRDB

actor BatchAdjustmentService {
    private let db: AppDatabase
    private let snapshotRepo: AdjustmentSnapshotRepository
    private let activityService: ActivityEventService
    private let lineageRepo: LineageRepository

    init(
        db: AppDatabase,
        snapshotRepo: AdjustmentSnapshotRepository,
        activityService: ActivityEventService,
        lineageRepo: LineageRepository
    ) {
        self.db = db
        self.snapshotRepo = snapshotRepo
        self.activityService = activityService
        self.lineageRepo = lineageRepo
    }

    /// Apply a source adjustment to multiple target photos.
    /// Creates a snapshot per photo and logs a batch activity event with child events.
    func applyToPhotos(
        sourceAdjustment: PhotoAdjustments,
        targetPhotoIds: [String],
        operationDescription: String
    ) async throws {
        guard !targetPhotoIds.isEmpty else { return }

        guard let json = sourceAdjustment.encodeToJSON() else { return }
        let now = ISO8601DateFormatter().string(from: Date())

        // Emit parent batch event
        let batchEvent = try await activityService.emitBatchTransform(
            title: "Paste adjustments",
            photoCount: targetPhotoIds.count,
            operationDescription: operationDescription
        )

        for photoId in targetPhotoIds {
            do {
                // Write adjustments_json to photo_assets
                try await db.dbPool.write { d in
                    try d.execute(
                        sql: "UPDATE photo_assets SET adjustments_json = ?, updated_at = ? WHERE id = ?",
                        arguments: [json, now, photoId]
                    )
                }

                // Save snapshot for rollback history
                let snapshot = AdjustmentSnapshot(
                    id: UUID().uuidString,
                    photoAssetId: photoId,
                    label: "Batch paste",
                    adjustmentJSON: json,
                    thumbnailPath: nil,
                    isCurrentState: true,
                    createdAt: Date()
                )
                try await snapshotRepo.saveSnapshot(snapshot)

                // Emit child event
                _ = try await activityService.emitAdjustment(
                    photoAssetId: photoId,
                    parentEventId: batchEvent.id,
                    description: operationDescription,
                    snapshotId: snapshot.id
                )
            } catch {
                // Log failure but continue with other photos
                try? await activityService.emitNote(
                    body: "Batch paste failed for \(photoId): \(error.localizedDescription)",
                    photoAssetId: photoId,
                    parentEventId: batchEvent.id
                )
            }
        }
    }

    /// Sync adjustments from a reference photo to all sibling frames (same parent scan).
    func syncFromReference(
        referencePhotoId: String,
        referenceAdjustment: PhotoAdjustments,
        options: PasteOptions,
        clipboard: AdjustmentClipboard
    ) async throws {
        let siblings = try await lineageRepo.fetchSiblings(for: referencePhotoId)
        guard !siblings.isEmpty else { return }

        let siblingIds = siblings.map(\.id)
        let filtered = clipboard.buildAdjustment(for: referenceAdjustment, options: options) ?? referenceAdjustment

        try await applyToPhotos(
            sourceAdjustment: filtered,
            targetPhotoIds: siblingIds,
            operationDescription: "Sync from reference frame"
        )
    }
}
