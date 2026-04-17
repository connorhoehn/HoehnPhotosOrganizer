import Foundation
import GRDB

// MARK: - FaceEmbedding

/// One detected face in one photo, with its Vision feature print for similarity search.
struct FaceEmbedding: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "face_embeddings"

    var id: String
    var photoId: String
    var faceIndex: Int        // 0-based index within the photo's detected faces
    var bboxX: Double         // Vision normalized bbox (origin bottom-left)
    var bboxY: Double
    var bboxWidth: Double
    var bboxHeight: Double
    var featureData: Data?    // Raw Float32 feature print from VNGenerateImageFeaturePrintRequest
    var createdAt: String

    // MARK: - Person labeling (v17_person_identities)

    /// FK → person_identities.id. Nil = unlabeled.
    /// When needsReview = true this is a *tentative* assignment pending Claude confirmation.
    var personId: String?
    /// Who assigned this face: "user" | "embedding" | "claude" | nil (unlabeled)
    var labeledBy: String?
    /// True when the embedding distance was borderline and Claude has not yet reviewed it.
    var needsReview: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case photoId = "photo_id"
        case faceIndex = "face_index"
        case bboxX = "bbox_x"
        case bboxY = "bbox_y"
        case bboxWidth = "bbox_width"
        case bboxHeight = "bbox_height"
        case featureData = "feature_data"
        case createdAt = "created_at"
        case personId = "person_id"
        case labeledBy = "labeled_by"
        case needsReview = "needs_review"
    }
}
