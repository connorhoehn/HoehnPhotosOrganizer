import Foundation
import GRDB

@MainActor
@Observable
final class LineageTimelineViewModel {
    var photoAssetId: String
    var nodes: [LineageNode] = []
    var selectedNodeId: String?

    /// Callback into the rollback engine (set by the host view or parent ViewModel).
    var onRollback: (AdjustmentSnapshot) async -> Void

    private let db: AppDatabase

    init(photoAssetId: String, db: AppDatabase, onRollback: @escaping (AdjustmentSnapshot) async -> Void = { _ in }) {
        self.photoAssetId = photoAssetId
        self.db = db
        self.onRollback = onRollback
    }

    // MARK: - Load

    func load() async {
        let repo = LineageRepository(db.dbPool)
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        do {
            nodes = try await repo.fetchLineage(forPhoto: photoAssetId, snapshotRepo: snapshotRepo)
            // Auto-select the current state node if none selected
            if selectedNodeId == nil {
                selectedNodeId = nodes.first(where: {
                    if case .adjustmentSnapshot(let s) = $0.kind { return s.isCurrentState }
                    return false
                })?.id
            }
        } catch {
            nodes = []
        }
    }

    // MARK: - Live updates

    /// Starts a long-running task that re-loads nodes whenever adjustment_snapshots changes.
    func observeSnapshots() async {
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        // Build the observation value on the actor, then start the async stream.
        let observation = await snapshotRepo.snapshotsObservation(forPhoto: photoAssetId)
        do {
            for try await _ in observation.values(in: db.dbPool) {
                await load()
            }
        } catch {
            // Observation ended — not a fatal condition
        }
    }
}
