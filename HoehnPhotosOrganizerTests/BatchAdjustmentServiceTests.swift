import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct BatchAdjustmentServiceTests {

    // MARK: - Helpers

    private func makeService(db: AppDatabase) -> BatchAdjustmentService {
        let eventRepo = ActivityEventRepository(db: db)
        let activityService = ActivityEventService(repo: eventRepo)
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)
        let lineageRepo = LineageRepository(db.dbPool)
        return BatchAdjustmentService(
            db: db,
            snapshotRepo: snapshotRepo,
            activityService: activityService,
            lineageRepo: lineageRepo
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
        let repo = PhotoRepository(db: db)
        try await repo.bulkUpsert([asset])
    }

    private func makeSource() -> PhotoAdjustments {
        var adj = PhotoAdjustments()
        adj.exposure = 1.5
        adj.contrast = 20
        adj.saturation = 15
        return adj
    }

    // MARK: - Tests

    @Test
    func testApplyToSelectedCreatesSnapshotPerPhoto() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-A", in: db)
        try await seedPhoto(id: "photo-B", in: db)
        let service = makeService(db: db)
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)

        try await service.applyToPhotos(
            sourceAdjustment: makeSource(),
            targetPhotoIds: ["photo-A", "photo-B"],
            operationDescription: "Paste look"
        )

        let snapshotsA = try await snapshotRepo.fetchSnapshots(forPhoto: "photo-A")
        let snapshotsB = try await snapshotRepo.fetchSnapshots(forPhoto: "photo-B")
        #expect(snapshotsA.count == 1, "photo-A should have 1 snapshot")
        #expect(snapshotsB.count == 1, "photo-B should have 1 snapshot")
    }

    @Test
    func testBatchApplyEmitsBatchActivityEvent() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-C", in: db)
        try await seedPhoto(id: "photo-D", in: db)
        try await seedPhoto(id: "photo-E", in: db)
        let service = makeService(db: db)
        let eventRepo = ActivityEventRepository(db: db)

        try await service.applyToPhotos(
            sourceAdjustment: makeSource(),
            targetPhotoIds: ["photo-C", "photo-D", "photo-E"],
            operationDescription: "Paste look"
        )

        let rootEvents = try await eventRepo.fetchRootEvents()
        #expect(rootEvents.count == 1, "Exactly 1 root batch event expected")
        let batchEvent = try #require(rootEvents.first)
        #expect(batchEvent.kind == .batchTransform)
    }

    @Test
    func testBatchApplyEmitsChildEventPerPhoto() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "photo-F", in: db)
        try await seedPhoto(id: "photo-G", in: db)
        let service = makeService(db: db)
        let eventRepo = ActivityEventRepository(db: db)

        try await service.applyToPhotos(
            sourceAdjustment: makeSource(),
            targetPhotoIds: ["photo-F", "photo-G"],
            operationDescription: "Paste look"
        )

        let rootEvents = try await eventRepo.fetchRootEvents()
        let batchEvent = try #require(rootEvents.first)
        let children = try await eventRepo.fetchChildren(of: batchEvent.id)
        #expect(children.count == 2, "One child event per target photo")
        #expect(children.allSatisfy { $0.parentEventId == batchEvent.id })
    }

    @Test
    func testApplyToEmptySelectionDoesNothing() async throws {
        let db = try AppDatabase.makeInMemory()
        let service = makeService(db: db)
        let eventRepo = ActivityEventRepository(db: db)
        let snapshotRepo = AdjustmentSnapshotRepository(db: db)

        try await service.applyToPhotos(
            sourceAdjustment: makeSource(),
            targetPhotoIds: [],
            operationDescription: "Paste look"
        )

        let rootEvents = try await eventRepo.fetchRootEvents()
        #expect(rootEvents.isEmpty, "Empty selection must not emit any events")
    }
}
