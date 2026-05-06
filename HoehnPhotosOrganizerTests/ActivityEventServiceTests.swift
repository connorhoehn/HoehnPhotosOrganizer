import Testing
import Foundation
@testable import HoehnPhotosOrganizer

struct ActivityEventServiceTests {

    private func makeService() async throws -> (ActivityEventService, ActivityEventRepository, PhotoRepository) {
        let db = try AppDatabase.makeInMemory()
        let eventRepo = ActivityEventRepository(db: db)
        let photoRepo = PhotoRepository(db: db)
        let service = ActivityEventService(repo: eventRepo)
        return (service, eventRepo, photoRepo)
    }

    // MARK: - testEmitImportBatchEventCreatesRoot

    @Test
    func testEmitImportBatchEventCreatesRoot() async throws {
        let (service, repo, _) = try await makeService()

        let root = try await service.emitImportBatch(title: "SD Card import", fileCount: 42)

        let fetched = try await repo.fetchEvent(id: root.id)
        let e = try #require(fetched, "emitImportBatch must persist the event")
        #expect(e.kind == .importBatch)
        #expect(e.parentEventId == nil, "Import batch event must be a root (no parent)")
        #expect(e.title == "SD Card import")
        #expect(e.detail?.contains("42") == true, "detail must include file count")
    }

    // MARK: - testEmitFrameExtractionCreatesChildUnderImport

    @Test
    func testEmitFrameExtractionCreatesChildUnderImport() async throws {
        let (service, repo, photoRepo) = try await makeService()

        let asset = PhotoAsset.new(canonicalName: "frame.dng", role: .original,
                                   filePath: "/frame.dng", fileSize: 0)
        try await photoRepo.upsert(asset)

        let batch = try await service.emitImportBatch(title: "Roll 12", fileCount: 1)
        try await service.emitFrameExtraction(
            parentBatchId: batch.id,
            photoAssetId: asset.id,
            frameName: "frame.dng",
            success: true
        )

        let children = try await repo.fetchChildren(of: batch.id)
        #expect(children.count == 1, "Frame extraction must create a child event under the import batch")
        #expect(children.first?.kind == .frameExtraction)
        #expect(children.first?.parentEventId == batch.id)
    }

    // MARK: - testEmitAdjustmentCreatesChildUnderPhoto

    @Test
    func testEmitAdjustmentCreatesChildUnderPhoto() async throws {
        let (service, repo, photoRepo) = try await makeService()

        let asset = PhotoAsset.new(canonicalName: "portrait.dng", role: .original,
                                   filePath: "/portrait.dng", fileSize: 0)
        try await photoRepo.upsert(asset)

        let adj = try await service.emitAdjustment(
            photoAssetId: asset.id,
            description: "Lifted shadows +30, reduced highlights -20"
        )

        let fetched = try await repo.fetchEvent(id: adj.id)
        let e = try #require(fetched, "emitAdjustment must persist the event")
        #expect(e.kind == .adjustment)
        #expect(e.photoAssetId == asset.id, "Adjustment must be linked to the photo")
        #expect(e.detail?.contains("shadows") == true)
    }

    // MARK: - testEmitNoteCreatesChildUnderEvent

    @Test
    func testEmitNoteCreatesChildUnderEvent() async throws {
        let (service, repo, _) = try await makeService()

        let batch = try await service.emitImportBatch(title: "Summer 2024", fileCount: 5)
        try await service.emitNote(body: "Printed these at f8 for the exhibition.", parentEventId: batch.id)

        let children = try await repo.fetchChildren(of: batch.id)
        #expect(children.count == 1, "Note must create a child event under the parent")
        #expect(children.first?.kind == .note)
        #expect(children.first?.detail == "Printed these at f8 for the exhibition.")
    }

    // MARK: - testEmitRollbackCreatesRollbackEvent

    @Test
    func testEmitRollbackCreatesRollbackEvent() async throws {
        let (service, repo, photoRepo) = try await makeService()

        let asset = PhotoAsset.new(canonicalName: "negative.dng", role: .original,
                                   filePath: "/negative.dng", fileSize: 0)
        try await photoRepo.upsert(asset)

        try await service.emitRollback(
            photoAssetId: asset.id,
            restoredSnapshotId: "snap-001",
            description: "Reverted to base scan"
        )

        let events = try await repo.fetchEventsForPhoto(asset.id)
        let rollback = events.first { $0.kind == .rollback }
        #expect(rollback != nil, "emitRollback must persist a .rollback event")
        #expect(rollback?.photoAssetId == asset.id)
        #expect(rollback?.detail == "Reverted to base scan")
    }
}
