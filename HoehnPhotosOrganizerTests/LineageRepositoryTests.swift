import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

final class LineageRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var lineageRepo: LineageRepository!
    var snapshotRepo: AdjustmentSnapshotRepository!
    var photoRepo: PhotoRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        lineageRepo = LineageRepository(db.dbPool)
        snapshotRepo = AdjustmentSnapshotRepository(db: db)
        photoRepo = PhotoRepository(db: db)
    }

    func testFetchLineageForPhotoReturnsAllNodes() async throws {
        let photo = PhotoAsset.new(canonicalName: "p1.ARW", role: .original, filePath: "/tmp/p1.ARW", fileSize: 1000)
        try await photoRepo.upsert(photo)
        let snapshot = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: photo.id,
            label: "v1", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: true, createdAt: Date())
        try await snapshotRepo.saveSnapshot(snapshot)
        let nodes = try await lineageRepo.fetchLineage(forPhoto: photo.id, snapshotRepo: snapshotRepo)
        XCTAssertGreaterThanOrEqual(nodes.count, 1)
        // At least the snapshot node should exist
        let snapshotNodes = nodes.filter {
            if case .adjustmentSnapshot = $0.kind { return true }
            return false
        }
        XCTAssertEqual(snapshotNodes.count, 1)
    }

    func testFetchSiblingsReturnsOtherChildrenOfParent() async throws {
        let parent = PhotoAsset.new(canonicalName: "scan.tif", role: .original, filePath: "/tmp/scan.tif", fileSize: 5000)
        try await photoRepo.upsert(parent)
        let child1 = PhotoAsset.new(canonicalName: "frame1.tif", role: .original, filePath: "/tmp/frame1.tif", fileSize: 1000)
        try await photoRepo.upsert(child1)
        let child2 = PhotoAsset.new(canonicalName: "frame2.tif", role: .original, filePath: "/tmp/frame2.tif", fileSize: 1000)
        try await photoRepo.upsert(child2)

        // Insert asset_lineage rows via raw SQL (no GRDB model)
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                INSERT INTO asset_lineage (id, parent_photo_id, child_photo_id, operation, frame_index, source_file_name, created_at)
                VALUES (?, ?, ?, 'frame_extraction', 0, 'scan.tif', datetime('now'))
            """, arguments: [UUID().uuidString, parent.id, child1.id])
            try conn.execute(sql: """
                INSERT INTO asset_lineage (id, parent_photo_id, child_photo_id, operation, frame_index, source_file_name, created_at)
                VALUES (?, ?, ?, 'frame_extraction', 1, 'scan.tif', datetime('now'))
            """, arguments: [UUID().uuidString, parent.id, child2.id])
        }

        let siblings = try await lineageRepo.fetchSiblings(for: child1.id)
        XCTAssertEqual(siblings.count, 1)
        XCTAssertEqual(siblings.first?.id, child2.id)
    }

    func testFetchParentReturnsDirectParent() async throws {
        let parent = PhotoAsset.new(canonicalName: "parent.tif", role: .original, filePath: "/tmp/parent.tif", fileSize: 5000)
        try await photoRepo.upsert(parent)
        let child = PhotoAsset.new(canonicalName: "child.tif", role: .original, filePath: "/tmp/child.tif", fileSize: 1000)
        try await photoRepo.upsert(child)

        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                INSERT INTO asset_lineage (id, parent_photo_id, child_photo_id, operation, frame_index, source_file_name, created_at)
                VALUES (?, ?, ?, 'frame_extraction', 0, 'parent.tif', datetime('now'))
            """, arguments: [UUID().uuidString, parent.id, child.id])
        }

        let fetchedParent = try await lineageRepo.fetchParent(for: child.id)
        XCTAssertNotNil(fetchedParent)
        XCTAssertEqual(fetchedParent?.id, parent.id)
    }

    func testLineageChainForDeepDerivative() async throws {
        let photo = PhotoAsset.new(canonicalName: "deep.ARW", role: .original, filePath: "/tmp/deep.ARW", fileSize: 1000)
        try await photoRepo.upsert(photo)
        let older = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: photo.id,
            label: "first", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: true, createdAt: Date(timeIntervalSince1970: 1000))
        try await snapshotRepo.saveSnapshot(older)
        let newer = AdjustmentSnapshot(id: UUID().uuidString, photoAssetId: photo.id,
            label: "second", adjustmentJSON: "{}", masksJSON: nil, thumbnailPath: nil,
            isCurrentState: true, createdAt: Date(timeIntervalSince1970: 2000))
        try await snapshotRepo.saveSnapshot(newer)

        let nodes = try await lineageRepo.fetchLineage(forPhoto: photo.id, snapshotRepo: snapshotRepo)
        let snapshotNodes = nodes.filter {
            if case .adjustmentSnapshot = $0.kind { return true }
            return false
        }
        XCTAssertEqual(snapshotNodes.count, 2)
        // Verify sorted by date (oldest first)
        XCTAssertTrue(nodes.first!.occurredAt <= nodes.last!.occurredAt)
    }
}
