import Foundation
import CoreGraphics
import GRDB

/// GRDB record type for the `asset_lineage` table (v2_lineage migration).
/// Tracks parent -> child relationships between photo assets.
/// This struct is the single authoritative Swift binding for asset_lineage.
/// Do NOT redefine AssetLineage in any other file.
struct AssetLineage: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "asset_lineage"

    var id: String
    var parentPhotoId: String?  // nullable: parent may have been deleted
    var childPhotoId: String
    var operation: String       // e.g. "film_strip_extract", "pipeline_run", "proxy_generate"
    var frameIndex: Int?
    var sourceFileName: String
    var createdAt: String
    var metadataJson: String?

    // Crop rect within the parent scan, in parent-image pixel coordinates (v11_lineage_crop_rect).
    var cropRectX: Double?
    var cropRectY: Double?
    var cropRectW: Double?
    var cropRectH: Double?

    /// Reconstructed crop rect, or nil if columns were not populated (pre-v11 rows).
    var cropRect: CGRect? {
        guard let x = cropRectX, let y = cropRectY,
              let w = cropRectW, let h = cropRectH else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case parentPhotoId = "parent_photo_id"
        case childPhotoId = "child_photo_id"
        case operation
        case frameIndex = "frame_index"
        case sourceFileName = "source_file_name"
        case createdAt = "created_at"
        case metadataJson = "metadata_json"
        case cropRectX = "crop_rect_x"
        case cropRectY = "crop_rect_y"
        case cropRectW = "crop_rect_w"
        case cropRectH = "crop_rect_h"
    }
}
