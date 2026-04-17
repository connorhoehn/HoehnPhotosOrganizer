import Foundation
import GRDB

/// GRDB record type for the `extraction_events` table (v2_lineage migration).
/// Records one row per film-strip extraction batch.
/// This struct is the single authoritative Swift binding for extraction_events.
/// Do NOT redefine ExtractionEvent in any other file.
struct ExtractionEvent: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "extraction_events"

    var id: String
    var sourcePhotoId: String?  // nullable: source may have been deleted
    var sourceFileName: String
    var orientation: String     // FilmStripOrientation.rawValue
    var detectorMethod: String  // FilmStripDetectionMethod.rawValue
    var frameCount: Int
    var manifestPath: String?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case sourcePhotoId = "source_photo_id"
        case sourceFileName = "source_file_name"
        case orientation
        case detectorMethod = "detector_method"
        case frameCount = "frame_count"
        case manifestPath = "manifest_path"
        case createdAt = "created_at"
    }
}
