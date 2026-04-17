import Foundation
import GRDB

/// A Studio canvas project — groups all revisions for one source photo.
struct StudioCanvas: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "studio_canvases"

    var id: String                  // UUID string
    var photoId: String?            // FK -> photo_assets.id (nil for standalone)
    var name: String
    var createdAt: String           // ISO8601
    var updatedAt: String           // ISO8601
    var lastMedium: String          // ArtMedium.rawValue
    var lastParamsJson: String      // MediumParams JSON
    var thumbnailPath: String?

    enum CodingKeys: String, CodingKey {
        case id
        case photoId         = "photo_id"
        case name
        case createdAt       = "created_at"
        case updatedAt       = "updated_at"
        case lastMedium      = "last_medium"
        case lastParamsJson  = "last_params_json"
        case thumbnailPath   = "thumbnail_path"
    }

    enum Columns {
        static let id              = Column("id")
        static let photoId         = Column("photo_id")
        static let name            = Column("name")
        static let createdAt       = Column("created_at")
        static let updatedAt       = Column("updated_at")
        static let lastMedium      = Column("last_medium")
        static let lastParamsJson  = Column("last_params_json")
        static let thumbnailPath   = Column("thumbnail_path")
    }

    /// Create a new canvas with auto-generated ID and timestamps.
    static func create(
        photoId: String? = nil,
        name: String,
        medium: String = "Oil",
        paramsJson: String = "{}"
    ) -> StudioCanvas {
        let now = ISO8601DateFormatter().string(from: Date())
        return StudioCanvas(
            id: UUID().uuidString,
            photoId: photoId,
            name: name,
            createdAt: now,
            updatedAt: now,
            lastMedium: medium,
            lastParamsJson: paramsJson,
            thumbnailPath: nil
        )
    }
}
