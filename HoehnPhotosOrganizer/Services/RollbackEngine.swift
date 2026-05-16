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
        let masks = MaskLayerStore.decode(from: snapshot.masksJSON)

        // 2. Save a new snapshot FIRST so the rollback is durable on disk before we
        //    commit it to the live editor. Previously this published `currentAdjustment`
        //    before the DB write succeeded — if the write threw, the UI showed the
        //    restored state but the next launch would still see the old one.
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

        // 3. Now publish to the live editor — the persisted state and the in-memory
        //    state can no longer diverge on a failed write.
        currentAdjustment.send(adjustment)
        currentMasks.send(masks)

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
