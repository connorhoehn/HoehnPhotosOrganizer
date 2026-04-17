import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class LineageTimelineViewTests: XCTestCase {

    var db: AppDatabase!
    var testPhotoId: String!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        let photoRepo = PhotoRepository(db: db)
        let photo = PhotoAsset.new(canonicalName: "timeline-test.ARW", role: .original, filePath: "/tmp/timeline.ARW", fileSize: 1000)
        try await photoRepo.upsert(photo)
        testPhotoId = photo.id
    }

    func testViewModelLoadsAllSnapshots() async throws {
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let s1 = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: testPhotoId,
            label: "v1", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: false, createdAt: Date(timeIntervalSince1970: 1000))
        try await snapshotRepo.saveSnapshot(s1)
        let s2 = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: testPhotoId,
            label: "v2", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: true, createdAt: Date(timeIntervalSince1970: 2000))
        try await snapshotRepo.saveSnapshot(s2)

        let vm = await MainActor.run { LineageTimelineViewModel(photoAssetId: testPhotoId, db: db) }
        await vm.load()
        let nodeCount = await MainActor.run { vm.nodes.count }
        XCTAssertGreaterThanOrEqual(nodeCount, 2)
    }

    func testCurrentSnapshotIsMarked() async throws {
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let s1 = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: testPhotoId,
            label: "old", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: false, createdAt: Date(timeIntervalSince1970: 1000))
        try await snapshotRepo.saveSnapshot(s1)
        let s2Id = UUID().uuidString
        let s2 = AdjustmentSnapshot(id: s2Id, photoAssetId: testPhotoId,
            label: "current", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: true, createdAt: Date(timeIntervalSince1970: 2000))
        try await snapshotRepo.saveSnapshot(s2)

        let vm = await MainActor.run { LineageTimelineViewModel(photoAssetId: testPhotoId, db: db) }
        await vm.load()
        let selected = await MainActor.run { vm.selectedNodeId }
        // selectedNodeId should auto-select the current state node (s2)
        XCTAssertEqual(selected, s2Id)
    }

    func testSelectSnapshotUpdatesSelected() async throws {
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let s1 = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: testPhotoId,
            label: "only", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: true, createdAt: Date())
        try await snapshotRepo.saveSnapshot(s1)

        let vm = await MainActor.run { LineageTimelineViewModel(photoAssetId: testPhotoId, db: db) }
        await vm.load()
        let firstNodeId = await MainActor.run { vm.nodes.first?.id }
        XCTAssertNotNil(firstNodeId)
        await MainActor.run { vm.selectedNodeId = firstNodeId }
        let selected = await MainActor.run { vm.selectedNodeId }
        XCTAssertEqual(selected, firstNodeId)
    }

    func testRollbackCallsEngine() async throws {
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let snapshot = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: testPhotoId,
            label: "rollback-target", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: true, createdAt: Date())
        try await snapshotRepo.saveSnapshot(snapshot)

        var rollbackCalled = false
        let vm = await MainActor.run {
            LineageTimelineViewModel(photoAssetId: testPhotoId, db: db) { _ in
                rollbackCalled = true
            }
        }
        await vm.onRollback(snapshot)
        XCTAssertTrue(rollbackCalled)
    }
}
