import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct SyncFromReferenceTests {

    // MARK: - Helpers

    private func makeService(db: AppDatabase) -> BatchAdjustmentService {
        BatchAdjustmentService(
            db: db,
            snapshotRepo: AdjustmentSnapshotRepository(db: db),
            activityService: ActivityEventService(repo: ActivityEventRepository(db: db)),
            lineageRepo: LineageRepository(db.dbPool)
        )
    }

    private func seedPhoto(id: String, in db: AppDatabase) async throws {
        var asset = PhotoAsset.new(
            canonicalName: "\(id).dng",
            role: .original,
            filePath: "/tmp/\(id).dng",
            fileSize: 1024
        )
        asset.id = id
        try await PhotoRepository(db: db).bulkUpsert([asset])
    }

    private func seedLineage(parentId: String, childId: String, frameIndex: Int, in db: AppDatabase) async throws {
        let row = AssetLineage(
            id: UUID().uuidString,
            parentPhotoId: parentId,
            childPhotoId: childId,
            operation: "film_strip_extract",
            frameIndex: frameIndex,
            sourceFileName: "scan.tif",
            createdAt: ISO8601DateFormatter().string(from: Date()),
            metadataJson: nil,
            cropRectX: nil, cropRectY: nil, cropRectW: nil, cropRectH: nil
        )
        try await db.dbPool.write { db in try row.insert(db) }
    }

    private func makeSource() -> PhotoAdjustments {
        var adj = PhotoAdjustments()
        adj.exposure = 0.7
        adj.contrast = 10
        return adj
    }

    // MARK: - Tests

    @Test
    func testSyncFromReferenceFindsAllSiblings() async throws {
        let db = try AppDatabase.makeInMemory()
        // parent + 3 siblings
        try await seedPhoto(id: "parent-1", in: db)
        try await seedPhoto(id: "ref-A", in: db)
        try await seedPhoto(id: "sib-B", in: db)
        try await seedPhoto(id: "sib-C", in: db)
        try await seedLineage(parentId: "parent-1", childId: "ref-A", frameIndex: 0, in: db)
        try await seedLineage(parentId: "parent-1", childId: "sib-B", frameIndex: 1, in: db)
        try await seedLineage(parentId: "parent-1", childId: "sib-C", frameIndex: 2, in: db)

        let service = makeService(db: db)
        let clipboard = AdjustmentClipboard()
        try await service.syncFromReference(
            referencePhotoId: "ref-A",
            referenceAdjustment: makeSource(),
            options: .all,
            clipboard: clipboard
        )

        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let snapsB = try await snapshotRepo.fetchSnapshots(forPhoto: "sib-B")
        let snapsC = try await snapshotRepo.fetchSnapshots(forPhoto: "sib-C")
        // Both siblings should have received a snapshot
        #expect(snapsB.count == 1, "sib-B must have 1 snapshot after sync")
        #expect(snapsC.count == 1, "sib-C must have 1 snapshot after sync")
        // Reference itself should NOT appear in snapshots (applyToPhotos targets siblings only)
        let snapsRef = try await snapshotRepo.fetchSnapshots(forPhoto: "ref-A")
        #expect(snapsRef.isEmpty, "reference photo must not be in target list")
    }

    @Test
    func testSyncFromReferenceAppliesReferenceAdjustmentToSiblings() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "parent-2", in: db)
        try await seedPhoto(id: "ref-D", in: db)
        try await seedPhoto(id: "sib-E", in: db)
        try await seedLineage(parentId: "parent-2", childId: "ref-D", frameIndex: 0, in: db)
        try await seedLineage(parentId: "parent-2", childId: "sib-E", frameIndex: 1, in: db)

        let service = makeService(db: db)
        let clipboard = AdjustmentClipboard()
        try await service.syncFromReference(
            referencePhotoId: "ref-D",
            referenceAdjustment: makeSource(),
            options: .all,
            clipboard: clipboard
        )

        // Verify sibling's adjustment_json was written (non-nil after UPDATE)
        let adjustmentsJson: String? = try await db.dbPool.read { d in
            try String.fetchOne(d, sql: "SELECT adjustments_json FROM photo_assets WHERE id = ?", arguments: ["sib-E"])
        }
        // adjustments_json should now contain the serialised source adjustment
        let json = try #require(adjustmentsJson, "sib-E must have adjustments_json written by sync")
        #expect(json.contains("exposure"), "adjustments JSON must include exposure field")
    }

    @Test
    func testSyncFromReferenceExcludesNonSiblings() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "parent-3", in: db)
        try await seedPhoto(id: "ref-F", in: db)
        try await seedPhoto(id: "sib-G", in: db)
        try await seedPhoto(id: "unrelated-H", in: db)  // no lineage row
        try await seedLineage(parentId: "parent-3", childId: "ref-F", frameIndex: 0, in: db)
        try await seedLineage(parentId: "parent-3", childId: "sib-G", frameIndex: 1, in: db)

        let service = makeService(db: db)
        let clipboard = AdjustmentClipboard()
        try await service.syncFromReference(
            referencePhotoId: "ref-F",
            referenceAdjustment: makeSource(),
            options: .all,
            clipboard: clipboard
        )

        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let snapsH = try await snapshotRepo.fetchSnapshots(forPhoto: "unrelated-H")
        #expect(snapsH.isEmpty, "unrelated photo must not receive any snapshots")
    }

    @Test
    func testSyncFromReferenceEmitsBatchEvent() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "parent-4", in: db)
        try await seedPhoto(id: "ref-I", in: db)
        try await seedPhoto(id: "sib-J", in: db)
        try await seedPhoto(id: "sib-K", in: db)
        try await seedLineage(parentId: "parent-4", childId: "ref-I", frameIndex: 0, in: db)
        try await seedLineage(parentId: "parent-4", childId: "sib-J", frameIndex: 1, in: db)
        try await seedLineage(parentId: "parent-4", childId: "sib-K", frameIndex: 2, in: db)

        let service = makeService(db: db)
        let clipboard = AdjustmentClipboard()
        try await service.syncFromReference(
            referencePhotoId: "ref-I",
            referenceAdjustment: makeSource(),
            options: .all,
            clipboard: clipboard
        )

        let eventRepo = ActivityEventRepository(db: db)
        let rootEvents = try await eventRepo.fetchRootEvents()
        #expect(rootEvents.count == 1, "Exactly 1 root batch event expected")
        let batchEvent = try #require(rootEvents.first)
        #expect(batchEvent.kind == .batchTransform)

        let children = try await eventRepo.fetchChildren(of: batchEvent.id)
        #expect(children.count == 2, "One child event per sibling (sib-J and sib-K)")
    }
}
