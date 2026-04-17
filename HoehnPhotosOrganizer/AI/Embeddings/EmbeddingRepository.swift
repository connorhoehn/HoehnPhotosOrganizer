import Foundation
import GRDB

// MARK: - EmbeddingRecord

/// GRDB record for the embeddings table.
/// Stores the embedding vector as a JSON-encoded array of Float values.
/// This provides broad compatibility regardless of sqlite-vec extension availability.
private struct EmbeddingRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "embeddings"

    var photoAssetId: String
    var embeddingJson: String  // JSON-encoded [Float] array
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case photoAssetId = "photo_asset_id"
        case embeddingJson = "embedding_json"
        case createdAt = "created_at"
    }

    init(row: Row) {
        photoAssetId = row["photo_asset_id"]
        embeddingJson = row["embedding_json"]
        createdAt = row["created_at"]
    }

    func encode(to container: inout PersistenceContainer) {
        container["photo_asset_id"] = photoAssetId
        container["embedding_json"] = embeddingJson
        container["created_at"] = createdAt
    }
}

// MARK: - EmbeddingRepository

/// Actor providing async storage and retrieval of embedding vectors from SQLite.
///
/// Embedding vectors are stored as JSON arrays in the `embeddings` table.
/// This fallback approach ensures broad compatibility without requiring the sqlite-vec extension.
/// Vector storage survives app restart (durable SQLite via GRDB).
///
/// Requirement: M7.1 (SRCH-9, AI-12) — local embedding storage and retrieval.
actor EmbeddingRepository {

    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Public Interface

    /// Store a 768-dim embedding vector for a photo asset.
    /// Upserts — overwrites any existing embedding for the same `photoAssetId`.
    func storeEmbedding(photoAssetId: String, embedding: [Float]) async throws {
        let json = try encodeVector(embedding)
        let now = ISO8601DateFormatter().string(from: .now)
        let record = EmbeddingRecord(photoAssetId: photoAssetId, embeddingJson: json, createdAt: now)

        try await db.dbPool.write { database in
            // Use INSERT OR REPLACE for upsert behaviour on the photo_asset_id primary key
            try database.execute(
                sql: """
                    INSERT INTO embeddings (photo_asset_id, embedding_json, created_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(photo_asset_id) DO UPDATE SET
                        embedding_json = excluded.embedding_json,
                        created_at = excluded.created_at
                """,
                arguments: [record.photoAssetId, record.embeddingJson, record.createdAt]
            )
        }
    }

    /// Fetch the embedding vector for a photo asset. Returns nil if not found.
    func fetchEmbedding(photoAssetId: String) async throws -> [Float]? {
        let jsonString: String? = try await db.dbPool.read { database -> String? in
            guard let row = try Row.fetchOne(
                database,
                sql: "SELECT embedding_json FROM embeddings WHERE photo_asset_id = ?",
                arguments: [photoAssetId]
            ) else { return nil }
            return row["embedding_json"]
        }
        guard let json = jsonString else { return nil }
        return try decodeVector(json)
    }

    /// Check whether an embedding exists for the given photo asset ID.
    func embeddingExists(photoAssetId: String) async throws -> Bool {
        try await db.dbPool.read { database -> Bool in
            let count = try Int.fetchOne(
                database,
                sql: "SELECT COUNT(*) FROM embeddings WHERE photo_asset_id = ?",
                arguments: [photoAssetId]
            ) ?? 0
            return count > 0
        }
    }

    /// Delete the embedding for a photo asset.
    func deleteEmbedding(photoAssetId: String) async throws {
        try await db.dbPool.write { database in
            try database.execute(
                sql: "DELETE FROM embeddings WHERE photo_asset_id = ?",
                arguments: [photoAssetId]
            )
        }
    }

    /// Fetch all stored embeddings. Useful for batch similarity computations.
    func getAllEmbeddings() async throws -> [(photoAssetId: String, vector: [Float])] {
        let pairs: [(String, String)] = try await db.dbPool.read { database -> [(String, String)] in
            let rows = try Row.fetchAll(
                database,
                sql: "SELECT photo_asset_id, embedding_json FROM embeddings ORDER BY created_at"
            )
            return rows.compactMap { row -> (String, String)? in
                guard let photoId: String = row["photo_asset_id"],
                      let json: String = row["embedding_json"] else { return nil }
                return (photoId, json)
            }
        }
        return pairs.compactMap { (photoId, json) -> (String, [Float])? in
            guard let vector = try? decodeVector(json) else { return nil }
            return (photoId, vector)
        }
    }

    // MARK: - Private Helpers

    private func encodeVector(_ vector: [Float]) throws -> String {
        let doubles = vector.map { Double($0) }
        let data = try JSONSerialization.data(withJSONObject: doubles)
        guard let json = String(data: data, encoding: .utf8) else {
            throw EmbeddingRepositoryError.encodingFailed
        }
        return json
    }

    private func decodeVector(_ json: String) throws -> [Float] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [NSNumber] else {
            throw EmbeddingRepositoryError.decodingFailed
        }
        return array.map { $0.floatValue }
    }
}

// MARK: - EmbeddingRepositoryError

enum EmbeddingRepositoryError: Error, LocalizedError {
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Failed to JSON-encode embedding vector"
        case .decodingFailed: return "Failed to JSON-decode embedding vector"
        }
    }
}

// MARK: - EmbeddingRecord init helper (no Codable dependency)

private extension EmbeddingRecord {
    init(photoAssetId: String, embeddingJson: String, createdAt: String) {
        self.photoAssetId = photoAssetId
        self.embeddingJson = embeddingJson
        self.createdAt = createdAt
    }
}
