import Foundation
import GRDB

/// A single Studio render revision tied to a source photo.
/// The rendered image files (thumbnail + full-res) live on disk; this record stores
/// the metadata and parameter snapshot in the GRDB catalog so renders are queryable,
/// sortable, and survive across sessions.
struct StudioRevision: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "studio_revisions"

    var id: String                  // UUID string
    var photoId: String             // FK → photo_assets.id
    var name: String                // e.g. "Oil Painting — Mar 30, 2026 at 2:15 PM"
    var medium: String              // ArtMedium.rawValue
    var brushSize: Double
    var detail: Double
    var texture: Double
    var colorSaturation: Double
    var contrast: Double
    var createdAt: String           // ISO8601
    var thumbnailPath: String?      // relative path to rendered thumbnail on disk
    var fullResPath: String?        // relative path to full-res render on disk

    enum CodingKeys: String, CodingKey {
        case id
        case photoId         = "photo_id"
        case name
        case medium
        case brushSize       = "brush_size"
        case detail
        case texture
        case colorSaturation = "color_saturation"
        case contrast
        case createdAt       = "created_at"
        case thumbnailPath   = "thumbnail_path"
        case fullResPath     = "full_res_path"
    }

    enum Columns {
        static let id              = Column("id")
        static let photoId         = Column("photo_id")
        static let name            = Column("name")
        static let medium          = Column("medium")
        static let brushSize       = Column("brush_size")
        static let detail          = Column("detail")
        static let texture         = Column("texture")
        static let colorSaturation = Column("color_saturation")
        static let contrast        = Column("contrast")
        static let createdAt       = Column("created_at")
        static let thumbnailPath   = Column("thumbnail_path")
        static let fullResPath     = Column("full_res_path")
    }
}
