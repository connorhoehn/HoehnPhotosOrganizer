import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

// MARK: - SimilaritySearchTests
// Requirement: SRCH-9 — Visual similarity search using stored embeddings and cosine distance

final class SimilaritySearchTests: XCTestCase {

    // MARK: - Helpers

    /// Create an in-memory AppDatabase with the full migration chain applied.
    private func makeTestDatabase() throws -> AppDatabase {
        return try AppDatabase.makeInMemory()
    }

    /// Insert a PhotoAsset row into the test database.
    private func insertPhoto(id: String, canonicalName: String, db: AppDatabase) async throws {
        try await db.dbPool.write { database in
            try database.execute(
                sql: """
                    INSERT OR IGNORE INTO photo_assets
                        (id, canonical_name, file_path, file_size, role,
                         curation_state, processing_state, sync_state,
                         created_at, updated_at)
                    VALUES (?, ?, ?, 0, 'original', 'needs_review', 'indexed', 'local_only', ?, ?)
                """,
                arguments: [id, canonicalName, "/fake/\(canonicalName)", "2026-01-01T00:00:00Z", "2026-01-01T00:00:00Z"]
            )
        }
    }

    // MARK: - Tests

    // SRCH-9: Querying with a seed vector returns the nearest-neighbor photo IDs in ranked order
    func testFindSimilarPhotos_returnsNearestNeighbors() async throws {
        let db = try makeTestDatabase()
        let embeddingRepo = EmbeddingRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        // Insert 5 photos with known embeddings.
        // Photo "ref" and "close1" are very similar (parallel vectors).
        // Photo "far1" is orthogonal to ref.
        let photoIds = ["ref", "close1", "close2", "far1", "far2"]
        for id in photoIds {
            try await insertPhoto(id: id, canonicalName: "\(id).jpg", db: db)
        }

        // Build known vectors: 4-dim for simplicity, normalised.
        let refVector: [Float]   = [1, 0, 0, 0]
        let close1: [Float]      = [0.99, 0.14, 0, 0]   // tiny angle from ref
        let close2: [Float]      = [0.95, 0.31, 0, 0]   // small angle from ref
        let far1: [Float]        = [0, 1, 0, 0]         // 90° from ref
        let far2: [Float]        = [0, 0, 1, 0]         // 90° from ref, different axis

        try await embeddingRepo.storeEmbedding(photoAssetId: "ref", embedding: refVector)
        try await embeddingRepo.storeEmbedding(photoAssetId: "close1", embedding: close1)
        try await embeddingRepo.storeEmbedding(photoAssetId: "close2", embedding: close2)
        try await embeddingRepo.storeEmbedding(photoAssetId: "far1", embedding: far1)
        try await embeddingRepo.storeEmbedding(photoAssetId: "far2", embedding: far2)

        let service = SimilaritySearchService(embeddingRepo: embeddingRepo, photoRepo: photoRepo)
        let results = try await service.findSimilarPhotos(to: "ref", limit: 4)

        // Reference photo must be excluded from its own results.
        XCTAssertFalse(results.map(\.id).contains("ref"), "Reference photo must not appear in results")

        // The two closest photos must appear before the two distant ones.
        let resultIds = results.map(\.id)
        let close1Idx = resultIds.firstIndex(of: "close1")
        let close2Idx = resultIds.firstIndex(of: "close2")
        let far1Idx   = resultIds.firstIndex(of: "far1")
        let far2Idx   = resultIds.firstIndex(of: "far2")

        XCTAssertNotNil(close1Idx, "close1 should be in results")
        XCTAssertNotNil(close2Idx, "close2 should be in results")
        if let c1 = close1Idx, let c2 = close2Idx, let f1 = far1Idx, let f2 = far2Idx {
            XCTAssertLessThan(c1, f1, "close1 should rank higher than far1")
            XCTAssertLessThan(c2, f2, "close2 should rank higher than far2")
        }
    }

    // SRCH-9: Cosine distance computation produces correctly ranked results for known vectors
    func testSimilaritySearch_cosineDistance_scoresCorrectly() async throws {
        let db = try makeTestDatabase()
        let embeddingRepo = EmbeddingRepository(db: db)
        let photoRepo = PhotoRepository(db: db)
        let service = SimilaritySearchService(embeddingRepo: embeddingRepo, photoRepo: photoRepo)

        // identical vectors → cosine similarity 1.0 → distance 0.0
        let v1: [Float] = [1, 2, 3, 4]
        let sameDistance = service.cosineDistance(v1: v1, v2: v1)
        XCTAssertEqual(sameDistance, 0.0, accuracy: 0.001, "Identical vectors must have cosine distance ≈ 0.0")

        // orthogonal vectors → cosine similarity 0.0 → distance 1.0
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let orthDistance = service.cosineDistance(v1: a, v2: b)
        XCTAssertEqual(orthDistance, 1.0, accuracy: 0.001, "Orthogonal vectors must have cosine distance ≈ 1.0")

        // opposite vectors → cosine similarity -1.0 → distance 2.0
        let c: [Float] = [1, 0]
        let d: [Float] = [-1, 0]
        let oppositeDistance = service.cosineDistance(v1: c, v2: d)
        XCTAssertEqual(oppositeDistance, 2.0, accuracy: 0.001, "Opposite vectors must have cosine distance ≈ 2.0")
    }

    // SRCH-9: Querying against a photo with no embedding returns an empty results array
    func testSimilaritySearch_emptyIndex_returnsEmptyResults() async throws {
        let db = try makeTestDatabase()
        let embeddingRepo = EmbeddingRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        // Insert a photo but store NO embedding for it.
        try await insertPhoto(id: "noEmbedding", canonicalName: "noEmbedding.jpg", db: db)

        let service = SimilaritySearchService(embeddingRepo: embeddingRepo, photoRepo: photoRepo)
        let results = try await service.findSimilarPhotos(to: "noEmbedding", limit: 20)

        XCTAssertTrue(results.isEmpty, "Should return empty array when reference photo has no embedding")
    }

    // SRCH-9: The topK / limit parameter is respected and no more than K results are returned
    func testSimilaritySearch_limitParameter_respectsTopK() async throws {
        let db = try makeTestDatabase()
        let embeddingRepo = EmbeddingRepository(db: db)
        let photoRepo = PhotoRepository(db: db)

        // Insert 10 photos all with similar embeddings.
        for i in 1...10 {
            let id = "photo\(i)"
            try await insertPhoto(id: id, canonicalName: "\(id).jpg", db: db)
            let vector: [Float] = [Float(i), 0, 0, 0]
            try await embeddingRepo.storeEmbedding(photoAssetId: id, embedding: vector)
        }

        // Use photo1 as reference (first photo) and ask for only 3 similar photos.
        let service = SimilaritySearchService(embeddingRepo: embeddingRepo, photoRepo: photoRepo)
        let results = try await service.findSimilarPhotos(to: "photo1", limit: 3)

        XCTAssertLessThanOrEqual(results.count, 3, "Result count must not exceed the specified limit")
    }
}
