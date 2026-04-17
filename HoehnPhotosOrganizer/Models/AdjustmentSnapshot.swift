import Foundation
import GRDB

/// An immutable point-in-time capture of a photo's full PhotoAdjustments state.
/// Every time the user saves adjustments, a new snapshot is created — existing snapshots are never mutated.
/// This is the basis for rollback: selecting a snapshot re-applies its stored parameters.
struct AdjustmentSnapshot: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "adjustment_snapshots"

    var id: String                    // UUID
    var photoAssetId: String
    var label: String?                // user-supplied label e.g. "After crop", "Base grade"
    var adjustmentJSON: String        // full PhotoAdjustments serialized as JSON
    var masksJSON: String?            // full [AdjustmentLayer] serialized as JSON
    var thumbnailPath: String?        // optional small rendered preview of this state
    var isCurrentState: Bool          // true for the snapshot representing the live state
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case photoAssetId   = "photo_asset_id"
        case label
        case adjustmentJSON = "adjustment_json"
        case masksJSON      = "masks_json"
        case thumbnailPath  = "thumbnail_path"
        case isCurrentState = "is_current_state"
        case createdAt      = "created_at"
    }

    enum Columns {
        static let id             = Column("id")
        static let photoAssetId   = Column("photo_asset_id")
        static let label          = Column("label")
        static let adjustmentJSON = Column("adjustment_json")
        static let masksJSON      = Column("masks_json")
        static let thumbnailPath  = Column("thumbnail_path")
        static let isCurrentState = Column("is_current_state")
        static let createdAt      = Column("created_at")
    }
}
