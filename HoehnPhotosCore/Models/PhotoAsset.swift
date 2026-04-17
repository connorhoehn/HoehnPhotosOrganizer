import Foundation
import GRDB

public struct PhotoAsset: Identifiable, Codable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "photo_assets"

    public var id: String            // UUID string
    public var canonicalName: String
    public var role: String          // PhotoRole.rawValue
    public var filePath: String
    public var fileSize: Int
    public var dateModified: String?
    public var rawExifJson: String?
    /// User-edited metadata overrides (META-3). Separate from rawExifJson.
    public var userMetadataJson: String?
    /// Append-only JSON array of change records [{field, oldValue, newValue, editedAt}] for edit reversibility (META-4).
    public var metadataEdits: String?
    public var processingState: String  // ProcessingState.rawValue
    public var errorMessage: String?
    public var curationState: String    // CurationState.rawValue
    public var syncState: String        // SyncState.rawValue
    public var createdAt: String
    public var updatedAt: String
    // AST-6: Technical image metadata — populated by IngestionActor/ProxyGenerationActor
    public var fileHash: String?         // SHA-256 hex string of original file
    public var colorProfile: String?     // e.g. "sRGB IEC61966-2.1", "Display P3"
    public var bitDepth: Int?            // bits per component: 8, 16, 32
    public var dpiX: Double?             // horizontal resolution from ImageIO
    public var dpiY: Double?             // vertical resolution from ImageIO
    public var hasAlpha: Bool?           // alpha channel present
    public var isGrayscale: Bool?        // image is grayscale (single luminance channel)
    // AI-5/AI-6 (M7.6): Scene classification + people detection — populated by SceneClassificationService/PersonDetectionService
    /// Scene type assigned by SceneClassificationService (landscape, portrait, architecture, stillLife, street, documentary, other).
    public var sceneType: String?
    /// True if faces or bodies were detected by PersonDetectionService.
    public var peopleDetected: Bool?
    /// JSON blob with confidence scores and detection details from classification/detection pass.
    /// Shape: {"visionConfidence": Float?, "faceCount": Int, "bodyDetected": Bool, "classificationSource": String}
    public var sceneClassificationMetadata: String?
    /// When true, asset is a parent scan source used for lineage/adjustment only.
    /// It does not appear in the main library grid but remains accessible via lineage and RefineFrameSheet.
    public var hiddenFromLibrary: Bool = false
    /// ISO 8601 timestamp of when face detection was last run on this photo's proxy.
    /// nil = never indexed. Set after successful face detection pass.
    public var faceIndexedAt: String?
    /// Absolute path to the generated proxy JPEG (set during drive import).
    public var proxyPath: String?
    /// macOS volume UUID of the originating drive.
    public var sourceDriveUUID: String?
    /// Path relative to the drive mount point.
    public var sourceDrivePath: String?
    /// Import staging state. "staged" = pending triage in Jobs, not visible in Library.
    /// "library" = committed to library after job review.
    /// Existing photos default to "library"; new imports start as "staged".
    public var importStatus: String = "staged"

    enum CodingKeys: String, CodingKey {
        case id, role
        case canonicalName = "canonical_name"
        case filePath = "file_path"
        case fileSize = "file_size"
        case dateModified = "date_modified"
        case rawExifJson = "raw_exif_json"
        case userMetadataJson = "user_metadata_json"
        case metadataEdits = "metadata_edits"
        case processingState = "processing_state"
        case errorMessage = "error_message"
        case curationState = "curation_state"
        case syncState = "sync_state"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case fileHash = "file_hash"
        case colorProfile = "color_profile"
        case bitDepth = "bit_depth"
        case dpiX = "dpi_x"
        case dpiY = "dpi_y"
        case hasAlpha = "has_alpha"
        case isGrayscale = "is_grayscale"
        case sceneType = "scene_type"
        case peopleDetected = "people_detected"
        case sceneClassificationMetadata = "scene_classification_metadata"
        case hiddenFromLibrary = "hidden_from_library"
        case faceIndexedAt = "face_indexed_at"
        case proxyPath = "proxy_path"
        case sourceDriveUUID = "source_drive_uuid"
        case sourceDrivePath = "source_drive_path"
        case importStatus = "import_status"
    }

    public static func new(canonicalName: String, role: PhotoRole, filePath: String, fileSize: Int) -> PhotoAsset {
        let now = ISO8601DateFormatter().string(from: .now)
        return PhotoAsset(
            id: UUID().uuidString,
            canonicalName: canonicalName,
            role: role.rawValue,
            filePath: filePath,
            fileSize: fileSize,
            dateModified: nil, rawExifJson: nil, userMetadataJson: nil, metadataEdits: nil,
            processingState: ProcessingState.indexed.rawValue,
            errorMessage: nil,
            curationState: CurationState.needsReview.rawValue,
            syncState: SyncState.localOnly.rawValue,
            createdAt: now, updatedAt: now
        )
    }
}
