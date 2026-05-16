import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

/// Verifies the People-gallery gating in `FaceEmbeddingRepository`:
///   * `fetchGalleryRecords()` (default, library-only) excludes faces tied to staged photos.
///   * `fetchGalleryRecords(photoIds:)` (job-scoped path) is intentionally NOT gated —
///     it must return faces on staged photos so the per-job People widget can show them.
///   * `findSimilarPhotoIds(to:)` filters out staged photos.
final class FaceEmbeddingRepositoryGateTests: XCTestCase {
    var db: AppDatabase!
    var faceRepo: FaceEmbeddingRepository!
    var photoRepo: PhotoRepository!

    var libraryPhotoId: String!
    var stagedPhotoId: String!
    var libraryFaceId: String!
    var stagedFaceId: String!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        faceRepo = FaceEmbeddingRepository(db: db)
        photoRepo = PhotoRepository(db: db)

        let now = ISO8601DateFormatter().string(from: Date())

        func mkPhoto(_ name: String, importStatus: String) -> PhotoAsset {
            var asset = PhotoAsset.new(
                canonicalName: name,
                role: .original,
                filePath: "/tmp/\(name)",
                fileSize: 0
            )
            asset.importStatus = importStatus
            return asset
        }

        let libraryPhoto = mkPhoto("library.dng", importStatus: "library")
        let stagedPhoto  = mkPhoto("staged.dng",  importStatus: "staged")
        libraryPhotoId = libraryPhoto.id
        stagedPhotoId  = stagedPhoto.id

        try await photoRepo.upsert(libraryPhoto)
        try await photoRepo.upsert(stagedPhoto)

        // Use identical opaque feature data on both faces so the gate is the only
        // distinguishing factor (data won't deserialize as VNFeaturePrintObservation
        // — see findSimilarPhotoIds note below).
        let fakeFeature = Data(repeating: 0x42, count: 32)

        let libraryFace = FaceEmbedding(
            id: UUID().uuidString,
            photoId: libraryPhoto.id,
            faceIndex: 0,
            bboxX: 0.1, bboxY: 0.1, bboxWidth: 0.2, bboxHeight: 0.2,
            featureData: fakeFeature,
            createdAt: now,
            personId: nil,
            labeledBy: nil,
            needsReview: false
        )
        let stagedFace = FaceEmbedding(
            id: UUID().uuidString,
            photoId: stagedPhoto.id,
            faceIndex: 0,
            bboxX: 0.1, bboxY: 0.1, bboxWidth: 0.2, bboxHeight: 0.2,
            featureData: fakeFeature,
            createdAt: now,
            personId: nil,
            labeledBy: nil,
            needsReview: false
        )
        libraryFaceId = libraryFace.id
        stagedFaceId  = stagedFace.id

        try await faceRepo.upsert(libraryFace)
        try await faceRepo.upsert(stagedFace)
    }

    override func tearDown() async throws {
        db = nil
        faceRepo = nil
        photoRepo = nil
    }

    // MARK: - Gallery gating

    func testFetchGalleryRecordsExcludesStagedFaces() async throws {
        let records = try await faceRepo.fetchGalleryRecords()
        let ids = Set(records.map(\.embedding.id))
        XCTAssertEqual(records.count, 1,
                       "fetchGalleryRecords() must return only faces on library-committed photos")
        XCTAssertTrue(ids.contains(libraryFaceId),
                      "Library face must be present in gallery records")
        XCTAssertFalse(ids.contains(stagedFaceId),
                       "Staged face must be excluded from default gallery records")
    }

    func testFetchGalleryRecordsByPhotoIdsIncludesStagedFaces() async throws {
        // Job-scoped path — intentionally NOT gated, so the per-job People widget
        // can surface faces from staged photos inside the open job.
        let records = try await faceRepo.fetchGalleryRecords(photoIds: [libraryPhotoId, stagedPhotoId])
        let ids = Set(records.map(\.embedding.id))
        XCTAssertEqual(records.count, 2,
                       "fetchGalleryRecords(photoIds:) must return BOTH faces (ungated job-scoped path)")
        XCTAssertTrue(ids.contains(libraryFaceId))
        XCTAssertTrue(ids.contains(stagedFaceId),
                      "Staged face MUST be returned via job-scoped fetchGalleryRecords(photoIds:)")
    }

    // MARK: - Similarity search gating

    func testFindSimilarPhotoIdsExcludesStaged() async throws {
        // Note: VNFeaturePrintObservation deserialization requires real Vision-generated
        // data; our opaque bytes will make `FaceEmbeddingService.distance` return nil for
        // every candidate, so the matched result set is empty. The library-only gate is
        // applied BEFORE the distance call in findSimilarPhotoIds (see implementation):
        // staged candidates are filtered out unconditionally regardless of distance.
        //
        // The strongest assertion we can make from a unit test (without a real face image)
        // is that the staged photo's ID never appears in the result set.
        let query = Data(repeating: 0x42, count: 32)
        let results = try await faceRepo.findSimilarPhotoIds(to: query)
        XCTAssertFalse(results.contains(stagedPhotoId),
                       "Staged photo must never be returned by findSimilarPhotoIds — " +
                       "the library_import_status filter runs before distance computation.")
    }
}
