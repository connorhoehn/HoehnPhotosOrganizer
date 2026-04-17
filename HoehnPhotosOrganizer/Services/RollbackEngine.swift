import Foundation
import Combine

/// Restores a photo's adjustment state to any prior AdjustmentSnapshot.
/// After restoring, the engine:
///   1. Publishes the restored PhotoAdjustments + AdjustmentLayers to shared publishers
///   2. Saves a new snapshot (so the rollback itself becomes part of the history)
///   3. Emits a rollback ActivityEvent
@MainActor
class RollbackEngine: ObservableObject {
    private let snapshotRepo: AdjustmentSnapshotRepository
    private let activityService: ActivityEventService

    /// The shared publisher that AdjustmentPanelView observes.
    /// Emits restored PhotoAdjustments whenever rollback() is called.
    let currentAdjustment = CurrentValueSubject<PhotoAdjustments?, Never>(nil)

    /// Emits restored mask layers alongside adjustments.
    let currentMasks = CurrentValueSubject<[AdjustmentLayer]?, Never>(nil)

    init(
        snapshotRepo: AdjustmentSnapshotRepository,
        activityService: ActivityEventService
    ) {
        self.snapshotRepo = snapshotRepo
        self.activityService = activityService
    }

    func rollback(to snapshot: AdjustmentSnapshot, photoAssetId: String) async throws {
        // 1. Decode the stored JSON back to PhotoAdjustments
        guard let adjustment = PhotoAdjustments.decode(from: snapshot.adjustmentJSON) else {
            throw RollbackError.invalidSnapshotJSON
        }

        // 2. Publish to live editor
        currentAdjustment.send(adjustment)

        // 2b. Publish mask layers if present
        let masks = MaskLayerStore.decode(from: snapshot.masksJSON)
        currentMasks.send(masks)

        // 3. Save a new snapshot (the rollback result becomes the new current state)
        let rollbackSnapshot = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: photoAssetId,
            label: "Restored: \(snapshot.label ?? "previous state")",
            adjustmentJSON: snapshot.adjustmentJSON,
            masksJSON: snapshot.masksJSON,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date()
        )
        try await snapshotRepo.saveSnapshot(rollbackSnapshot)

        // 4. Emit activity event (fire and forget — don't block rollback on logging)
        Task {
            try? await activityService.emitRollback(
                photoAssetId: photoAssetId,
                restoredSnapshotId: snapshot.id,
                description: "Restored to: \(snapshot.label ?? snapshot.createdAt.formatted())"
            )
        }
    }

    enum RollbackError: Error {
        case invalidSnapshotJSON
    }
}
