import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

/// Verifies that `TriageJobRepository.computeAndUpdateCompleteness` still produces the
/// correct 4-dimension average after the recent consolidation into a single read
/// transaction. The expected value is captured as a "golden" snapshot so the test will
/// also catch regressions if any dimension's weighting changes.
final class TriageJobCompletenessTests: XCTestCase {
    var db: AppDatabase!
    var jobRepo: TriageJobRepository!
    var photoRepo: PhotoRepository!
    var faceRepo: FaceEmbeddingRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        jobRepo = TriageJobRepository(db: db)
        photoRepo = PhotoRepository(db: db)
        faceRepo = FaceEmbeddingRepository(db: db)

        // The completeness SQL references `development_versions`, which is created in
        // HoehnPhotosCore's schema but not in the macOS AppDatabase migrations. Create
        // it manually so the SELECT doesn't error in the in-memory test DB.
        try await db.dbPool.write { conn in
            try conn.execute(sql: """
                CREATE TABLE IF NOT EXISTS development_versions (
                    id TEXT NOT NULL PRIMARY KEY,
                    photo_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    adjustments_json TEXT NOT NULL,
                    masks_json TEXT,
                    is_published INTEGER NOT NULL DEFAULT 0,
                    is_default INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
            """)
        }
    }

    override func tearDown() async throws {
        db = nil
        jobRepo = nil
        photoRepo = nil
        faceRepo = nil
    }

    /// Golden test: build a 10-photo job whose dimensions are known by construction
    /// and assert the score matches the hand-calculated expected average.
    ///
    /// Construction:
    ///   - 10 photos total
    ///   - 5 keepers, 5 needs_review  → curation = 5/10 = 0.5
    ///   - 3 photos carry a face embedding, of which 1 is labeled to a named
    ///     person identity                       → people = 1/3
    ///   - 2 keeper photos have non-empty adjustments_json
    ///                                          → developed = 2/5 = 0.4
    ///   - 1 keeper photo has user_metadata_json with a "title" key
    ///                                          → metadata = 1/5 = 0.2
    ///
    ///   score = 0.25 · (0.5 + 1/3 + 0.4 + 0.2) ≈ 0.3583333…
    func testCompletenessScoreMatchesGoldenAverage() async throws {
        let now = ISO8601DateFormatter().string(from: Date())

        func mkPhoto(_ name: String,
                     curationState: CurationState,
                     userMetadata: String? = nil) -> PhotoAsset {
            var asset = PhotoAsset.new(
                canonicalName: name,
                role: .original,
                filePath: "/tmp/\(name)",
                fileSize: 0
            )
            asset.curationState = curationState.rawValue
            asset.userMetadataJson = userMetadata
            asset.importStatus = "library"
            return asset
        }

        // 5 keepers (k1…k5). k1+k2 have adjustments (set via SQL below).
        // k1 also has title metadata so it counts toward the metadata dimension.
        let k1 = mkPhoto("k1.dng", curationState: .keeper,
                         userMetadata: "{\"title\":\"Sunset\"}")
        let k2 = mkPhoto("k2.dng", curationState: .keeper)
        let k3 = mkPhoto("k3.dng", curationState: .keeper)
        let k4 = mkPhoto("k4.dng", curationState: .keeper)
        let k5 = mkPhoto("k5.dng", curationState: .keeper)

        // 5 needs_review (r1…r5)
        let r1 = mkPhoto("r1.dng", curationState: .needsReview)
        let r2 = mkPhoto("r2.dng", curationState: .needsReview)
        let r3 = mkPhoto("r3.dng", curationState: .needsReview)
        let r4 = mkPhoto("r4.dng", curationState: .needsReview)
        let r5 = mkPhoto("r5.dng", curationState: .needsReview)

        let allPhotos = [k1, k2, k3, k4, k5, r1, r2, r3, r4, r5]

        // Persist adjustments_json directly via SQL (PhotoAsset model doesn't expose it).
        try await db.dbPool.write { conn in
            for photo in allPhotos {
                var p = photo
                try p.insert(conn)
            }
            try conn.execute(
                sql: "UPDATE photo_assets SET adjustments_json = ? WHERE id = ?",
                arguments: ["{\"v\":1}", k1.id]
            )
            try conn.execute(
                sql: "UPDATE photo_assets SET adjustments_json = ? WHERE id = ?",
                arguments: ["{\"v\":1}", k2.id]
            )
        }

        // Insert a named person identity for the labeled face.
        let personId = UUID().uuidString
        try await db.dbPool.write { conn in
            let person = PersonIdentity(
                id: personId,
                name: "Test Person",
                coverFaceEmbeddingId: nil,
                createdAt: now
            )
            var p = person
            try p.insert(conn)
        }

        // 3 face embeddings on 3 different photos. The first is labeled, the other two
        // are unlabeled — yielding totalFaces=3, identifiedFaces=1.
        let labeledFace = FaceEmbedding(
            id: UUID().uuidString,
            photoId: k1.id,
            faceIndex: 0,
            bboxX: 0.1, bboxY: 0.1, bboxWidth: 0.2, bboxHeight: 0.2,
            featureData: nil,
            createdAt: now,
            personId: personId,
            labeledBy: "user",
            needsReview: false
        )
        let unlabeledFace1 = FaceEmbedding(
            id: UUID().uuidString,
            photoId: k2.id,
            faceIndex: 0,
            bboxX: 0.1, bboxY: 0.1, bboxWidth: 0.2, bboxHeight: 0.2,
            featureData: nil,
            createdAt: now,
            personId: nil,
            labeledBy: nil,
            needsReview: false
        )
        let unlabeledFace2 = FaceEmbedding(
            id: UUID().uuidString,
            photoId: r1.id,
            faceIndex: 0,
            bboxX: 0.1, bboxY: 0.1, bboxWidth: 0.2, bboxHeight: 0.2,
            featureData: nil,
            createdAt: now,
            personId: nil,
            labeledBy: nil,
            needsReview: false
        )
        try await faceRepo.upsert(labeledFace)
        try await faceRepo.upsert(unlabeledFace1)
        try await faceRepo.upsert(unlabeledFace2)

        // Create the job and attach all 10 photos.
        let job = TriageJob.newImportJob(title: "Completeness Test", photoCount: allPhotos.count)
        try await jobRepo.insert(job)
        try await jobRepo.addPhotos(jobId: job.id, photoIds: allPhotos.map(\.id))

        // Compute & assert.
        let computed = try await jobRepo.computeAndUpdateCompleteness(jobId: job.id)

        // Hand calculation:
        //   curation  = 5/10  = 0.5
        //   people    = 1/3
        //   developed = 2/5   = 0.4
        //   metadata  = 1/5   = 0.2
        //   score     = 0.25 · (0.5 + 1/3 + 0.4 + 0.2) ≈ 0.35833333333333334
        let curation  = 5.0 / 10.0
        let people    = 1.0 / 3.0
        let developed = 2.0 / 5.0
        let metadata  = 1.0 / 5.0
        let expected  = 0.25 * (curation + people + developed + metadata)

        XCTAssertEqual(computed, expected, accuracy: 1e-9,
                       "computeAndUpdateCompleteness must match the 4-dimension equal-weight average")

        // Golden snapshot — captured to detect any change in the weighting algorithm.
        XCTAssertEqual(computed, 0.35833333333333334, accuracy: 1e-9,
                       "Golden score regression: existing 4-dimension formula should yield ≈0.3583")

        // The score is also persisted on the job row (capped at 1).
        let updated = try await jobRepo.fetchById(job.id)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.completenessScore ?? 0, min(1.0, expected), accuracy: 1e-9,
                       "Persisted completenessScore must equal the clamped computed value")
    }
}
