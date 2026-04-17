import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

// MARK: - EmbeddingRepositoryTests
// Requirement: M7.1 — Local embedding storage and retrieval via SQLite virtual table (sqlite-vec)

final class EmbeddingRepositoryTests: XCTestCase {

    var db: AppDatabase!
    var repository: EmbeddingRepository!

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        repository = EmbeddingRepository(db: db)
    }

    override func tearDown() async throws {
        repository = nil
        db = nil
    }

    // MARK: - Helpers

    private func makeTestVector(value: Float = 0.5) -> [Float] {
        Array(repeating: value, count: 768)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for (x, y) in zip(a, b) {
            dot += x * y
            normA += x * x
            normB += y * y
        }
        let denom = normA.squareRoot() * normB.squareRoot()
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    // MARK: - Tests

    // M7.1: Storing a float vector with an associated photo ID persists the embedding row
    func testStoreEmbedding_storesVectorWithPhotoId() async throws {
        let photoId = UUID().uuidString
        let vector = makeTestVector()

        try await repository.storeEmbedding(photoAssetId: photoId, embedding: vector)

        let exists = try await repository.embeddingExists(photoAssetId: photoId)
        XCTAssertTrue(exists, "Stored embedding should exist in the database")
    }

    // M7.1: Fetching by photo ID returns the previously stored float vector
    func testFetchEmbedding_retrievesStoredVector() async throws {
        let photoId = UUID().uuidString
        let vector = makeTestVector(value: 0.3)

        try await repository.storeEmbedding(photoAssetId: photoId, embedding: vector)
        let fetched = try await repository.fetchEmbedding(photoAssetId: photoId)

        XCTAssertNotNil(fetched, "Fetched embedding should not be nil")
        guard let fetched else { return }
        XCTAssertEqual(fetched.count, 768, "Fetched vector must have 768 dimensions")

        let similarity = cosineSimilarity(vector, fetched)
        XCTAssertGreaterThanOrEqual(similarity, Float(0.99), "Cosine similarity should be ≥ 0.99 for round-tripped vector")
    }

    // M7.1: Checking existence by photo ID returns true for a stored embedding
    func testEmbeddingExists_returnsTrueForStoredId() async throws {
        let storedId = UUID().uuidString
        let unknownId = UUID().uuidString
        let vector = makeTestVector()

        try await repository.storeEmbedding(photoAssetId: storedId, embedding: vector)

        let storedExists = try await repository.embeddingExists(photoAssetId: storedId)
        let unknownExists = try await repository.embeddingExists(photoAssetId: unknownId)

        XCTAssertTrue(storedExists, "embeddingExists should return true for stored ID")
        XCTAssertFalse(unknownExists, "embeddingExists should return false for unknown ID")
    }

    // M7.1: Deleting an embedding by photo ID removes it from the virtual table index
    func testDeleteEmbedding_removesVectorFromIndex() async throws {
        let photoId = UUID().uuidString
        let vector = makeTestVector()

        try await repository.storeEmbedding(photoAssetId: photoId, embedding: vector)
        try await repository.deleteEmbedding(photoAssetId: photoId)

        let fetched = try await repository.fetchEmbedding(photoAssetId: photoId)
        XCTAssertNil(fetched, "Fetched embedding should be nil after deletion")
    }

    // M7.1: AppDatabase migration creates the embeddings table on first run
    func testEmbeddingSchema_createsVirtualTableOnMigration() async throws {
        let tableExists = try await db.dbPool.read { database -> Bool in
            try database.tableExists("embeddings")
        }
        XCTAssertTrue(tableExists, "embeddings table should exist after v7_embeddings migration")
    }
}
