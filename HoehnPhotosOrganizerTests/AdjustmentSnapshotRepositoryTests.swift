import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class AdjustmentSnapshotRepositoryTests: XCTestCase {
    var db: AppDatabase!
    var repo: AdjustmentSnapshotRepository!
    var photoRepo: PhotoRepository!
    var testPhotoId: String!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repo = AdjustmentSnapshotRepository(db: db)
        photoRepo = PhotoRepository(db: db)
        let photo = PhotoAsset.new(
            canonicalName: "test-\(UUID().uuidString).ARW",
            role: .original,
            filePath: "/tmp/test.ARW",
            fileSize: 1000
        )
        try await photoRepo.upsert(photo)
        testPhotoId = photo.id
    }

    func testInsertSnapshotPersists() async throws {
        let snapshot = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "Test",
            adjustmentJSON: "{}",
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date()
        )
        try await repo.saveSnapshot(snapshot)
        let fetched = try await repo.fetchCurrentSnapshot(forPhoto: testPhotoId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, snapshot.id)
    }

    func testFetchSnapshotsForPhotoReturnsOrdered() async throws {
        let older = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "v1",
            adjustmentJSON: "{}",
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        try await repo.saveSnapshot(older)
        let newer = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "v2",
            adjustmentJSON: "{}",
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date(timeIntervalSince1970: 2000)
        )
        try await repo.saveSnapshot(newer)
        let all = try await repo.fetchSnapshots(forPhoto: testPhotoId)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first?.label, "v1")
        XCTAssertEqual(all.last?.label, "v2")
    }

    func testFetchLatestSnapshotReturnsNewest() async throws {
        let s1 = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "first",
            adjustmentJSON: "{}",
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date(timeIntervalSince1970: 1000)
        )
        try await repo.saveSnapshot(s1)
        let s2 = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "second",
            adjustmentJSON: "{}",
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date(timeIntervalSince1970: 2000)
        )
        try await repo.saveSnapshot(s2)
        let current = try await repo.fetchCurrentSnapshot(forPhoto: testPhotoId)
        XCTAssertEqual(current?.id, s2.id)
        XCTAssertEqual(current?.isCurrentState, true)
    }

    func testDeleteSnapshotRemovesFromDB() async throws {
        let snapshot = AdjustmentSnapshot(
            id: UUID().uuidString,
            photoAssetId: testPhotoId,
            label: "doomed",
            adjustmentJSON: "{}",
            masksJSON: nil,
            thumbnailPath: nil,
            isCurrentState: true,
            createdAt: Date()
        )
        try await repo.saveSnapshot(snapshot)
        try await repo.deleteSnapshot(id: snapshot.id)
        let gone = try await repo.fetchSnapshot(id: snapshot.id)
        XCTAssertNil(gone)
    }
}
