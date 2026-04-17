import Foundation
import GRDB

// MARK: - PersonIdentity

/// A named person whose faces appear across the photo library.
/// Face embeddings link to this record via `person_id`.
struct PersonIdentity: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    static let databaseTableName = "person_identities"

    var id: String
    var name: String
    /// Optional: which face_embeddings row to use as the avatar chip.
    var coverFaceEmbeddingId: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case coverFaceEmbeddingId = "cover_face_embedding_id"
        case createdAt = "created_at"
    }
}
