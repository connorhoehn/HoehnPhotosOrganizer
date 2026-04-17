import Foundation
import GRDB

/// A persistent canvas session — like Procreate's gallery.
/// Each session remembers the source image, current medium, full pipeline state,
/// and can be reopened to continue editing with full undo/redo history.
struct CanvasSession: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "canvas_sessions"

    var id: String                  // UUID string
    var name: String
    var sourcePhotoId: String?      // FK to photo_assets (nil when loaded from file/drop)
    var sourceImagePath: String     // absolute path to prepared source image on disk
    var currentMedium: String?      // ArtMedium.rawValue
    var pipelineState: Data?        // serialized pipeline config JSON
    var thumbnailPath: String?      // path to session thumbnail on disk
    var createdAt: String           // ISO8601
    var modifiedAt: String          // ISO8601

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case sourcePhotoId   = "source_photo_id"
        case sourceImagePath = "source_image_path"
        case currentMedium   = "current_medium"
        case pipelineState   = "pipeline_state"
        case thumbnailPath   = "thumbnail_path"
        case createdAt       = "created_at"
        case modifiedAt      = "modified_at"
    }

    enum Columns {
        static let id              = Column("id")
        static let name            = Column("name")
        static let sourcePhotoId   = Column("source_photo_id")
        static let sourceImagePath = Column("source_image_path")
        static let currentMedium   = Column("current_medium")
        static let pipelineState   = Column("pipeline_state")
        static let thumbnailPath   = Column("thumbnail_path")
        static let createdAt       = Column("created_at")
        static let modifiedAt      = Column("modified_at")
    }
}
