import Foundation
import GRDB

// MARK: - SimilaritySearchError

/// Errors specific to visual similarity search.
enum SimilaritySearchError: Error, LocalizedError {
    /// The reference photo has no embedding stored — cannot compute similarity.
    case referencePhotoNotEmbedded
    /// A database read/write error occurred during the query.
    case databaseError(underlying: Error)
    /// The search returned no results (not an error in all callers, but surfaced for logging).
    case noResults

    var errorDescription: String? {
        switch self {
        case .referencePhotoNotEmbedded:
            return "Reference photo has no embedding. Run embedding generation first."
        case .databaseError(let err):
            return "Database error during similarity search: \(err.localizedDescription)"
        case .noResults:
            return "No similar photos found."
        }
    }
}

// MARK: - SimilaritySearchService

/// Actor providing ANN (approximate nearest neighbor) similarity search over stored embeddings.
///
/// Because sqlite-vec is not compiled into the app binary, similarity ranking is performed
/// in-process using CPU cosine distance. For photo libraries up to ~100k photos this is
/// fast enough (<500ms) and avoids a native extension dependency.
///
/// Usage:
/// ```swift
/// let service = SimilaritySearchService(embeddingRepo: repo, photoRepo: photoRepo)
/// let similar = try await service.findSimilarPhotos(to: selectedPhoto.id, limit: 20)
/// ```
///
/// Requirement: SRCH-9
actor SimilaritySearchService {

    private let embeddingRepo: EmbeddingRepository
    private let photoRepo: PhotoRepository

    init(embeddingRepo: EmbeddingRepository, photoRepo: PhotoRepository) {
        self.embeddingRepo = embeddingRepo
        self.photoRepo = photoRepo
    }

    // MARK: - Public API

    /// Find the `limit` most visually similar photos to the given reference photo.
    ///
    /// - Parameters:
    ///   - photoId: The `id` of the reference photo (must have a stored embedding).
    ///   - limit: Maximum number of similar photos to return (default 20).
    /// - Returns: An array of `PhotoAsset` objects sorted by cosine distance (nearest first).
    ///            Returns an empty array when the reference photo has no embedding.
    /// - Throws: `SimilaritySearchError.databaseError` on DB failure.
    func findSimilarPhotos(to photoId: String, limit: Int = 20) async throws -> [PhotoAsset] {
        // Step 1: Fetch the reference embedding. Return empty (not error) if absent.
        let referenceEmbedding: [Float]
        do {
            guard let embedding = try await embeddingRepo.fetchEmbedding(photoAssetId: photoId) else {
                // Reference photo has no embedding — graceful empty return per spec.
                return []
            }
            referenceEmbedding = embedding
        } catch {
            throw SimilaritySearchError.databaseError(underlying: error)
        }

        // Step 2: Fetch all stored embeddings for CPU-side ANN ranking.
        let allEmbeddings: [(photoAssetId: String, vector: [Float])]
        do {
            allEmbeddings = try await embeddingRepo.getAllEmbeddings()
        } catch {
            throw SimilaritySearchError.databaseError(underlying: error)
        }

        // Step 3: Compute cosine distance for each candidate, excluding the reference photo.
        var scored: [(photoAssetId: String, distance: Float)] = allEmbeddings.compactMap { entry in
            guard entry.photoAssetId != photoId else { return nil }
            let dist = cosineDistance(v1: referenceEmbedding, v2: entry.vector)
            return (entry.photoAssetId, dist)
        }

        // Step 4: Sort by distance ascending (nearest neighbours first) and take top-K.
        scored.sort { $0.distance < $1.distance }
        let topK = Array(scored.prefix(limit))

        guard !topK.isEmpty else { return [] }

        // Step 5: Fetch PhotoAsset records for the selected IDs, preserving rank order.
        let orderedIds = topK.map(\.photoAssetId)
        let fetchedAssets = try await fetchPhotosByIds(orderedIds)

        // Build a lookup so we can re-order to match rank.
        let assetMap = Dictionary(uniqueKeysWithValues: fetchedAssets.map { ($0.id, $0) })
        return orderedIds.compactMap { assetMap[$0] }
    }

    // MARK: - Distance metric (CPU fallback)

    /// Cosine distance between two vectors.
    ///
    /// `cosineDistance = 1 - cosineSimilarity`
    ///
    /// | Relationship   | Similarity | Distance |
    /// |---------------|-----------|---------|
    /// | Identical      | 1.0       | 0.0     |
    /// | Orthogonal     | 0.0       | 1.0     |
    /// | Opposite       | -1.0      | 2.0     |
    ///
    /// - Returns: Distance in [0, 2]. Returns 1.0 (neutral) if either vector is zero-length.
    nonisolated func cosineDistance(v1: [Float], v2: [Float]) -> Float {
        guard v1.count == v2.count, !v1.isEmpty else { return 1.0 }

        var dotProduct: Float = 0
        var norm1: Float = 0
        var norm2: Float = 0

        for i in 0..<v1.count {
            dotProduct += v1[i] * v2[i]
            norm1 += v1[i] * v1[i]
            norm2 += v2[i] * v2[i]
        }

        let denominator = sqrt(norm1) * sqrt(norm2)
        guard denominator > 0 else { return 1.0 }

        let similarity = dotProduct / denominator
        // Clamp to [-1, 1] to guard against floating-point noise at the edges.
        let clamped = min(1.0, max(-1.0, similarity))
        return 1.0 - clamped
    }

    // MARK: - Private helpers

    /// Fetch multiple PhotoAsset records by their IDs in a single read transaction.
    private func fetchPhotosByIds(_ ids: [String]) async throws -> [PhotoAsset] {
        guard !ids.isEmpty else { return [] }

        do {
            return try await photoRepo.fetchByIds(ids)
        } catch {
            throw SimilaritySearchError.databaseError(underlying: error)
        }
    }
}
