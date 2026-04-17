import Foundation
import GRDB

// MARK: - DrivePhotoRecord

/// One image file indexed from an external drive.
/// Stored in the per-drive SQLite at ~/Library/…/driveIndexes/{uuid}/index.db
struct DrivePhotoRecord: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "drive_photos"

    var id: String              // UUID string
    var relativePath: String    // path relative to volume mount point
    var filename: String        // display name (e.g. "IMG_1234.ARW")
    var fileSize: Int           // bytes
    var captureDate: String?    // ISO8601, from EXIF DateTimeOriginal
    var width: Int?
    var height: Int?
    var isRaw: Int              // 1 = RAW format
    var thumbnailPath: String?  // absolute path in app-support thumbs folder
    var indexedAt: String       // ISO8601
    var modifiedAt: String      // ISO8601 file modification date
    var duplicateGroupId: String? // non-nil when ≥1 other file shares the same filename+captureDate (or filename+size)

    // Workflow annotation results (nil = workflow not yet run)
    var orientationDegrees: Int?  // CW correction needed: 0/90/180/270
    var sceneLabel: String?        // "landscape", "portrait", etc.
    var faceCount: Int?            // 0 = no faces; N = N faces detected
    var filmFrameCount: Int?       // 0 = not a film strip; N = N frames detected
    var filmFrameRectsJSON: String? // JSON array of [x,y,w,h] quads — persisted to skip re-detection
    var workflowsRun: String?      // comma-separated IDs: "orientation,scene,faces,filmStrip"
    var importedAt: String?        // ISO8601 timestamp when photo was imported to library
    var gpsLatitude: Double?       // WGS-84 latitude (+N / -S)
    var gpsLongitude: Double?      // WGS-84 longitude (+E / -W)

    enum CodingKeys: String, CodingKey {
        case id, filename, width, height
        case relativePath    = "relative_path"
        case fileSize        = "file_size"
        case captureDate     = "capture_date"
        case isRaw           = "is_raw"
        case thumbnailPath   = "thumbnail_path"
        case indexedAt       = "indexed_at"
        case modifiedAt      = "modified_at"
        case duplicateGroupId    = "duplicate_group_id"
        case orientationDegrees  = "orientation_degrees"
        case sceneLabel          = "scene_label"
        case faceCount           = "face_count"
        case filmFrameCount      = "film_frame_count"
        case filmFrameRectsJSON  = "film_frame_rects_json"
        case workflowsRun        = "workflows_run"
        case importedAt          = "imported_at"
        case gpsLatitude         = "gps_latitude"
        case gpsLongitude        = "gps_longitude"
    }

    var isRawFile: Bool { isRaw == 1 }
    var hasWorkflowResults: Bool { workflowsRun != nil && !workflowsRun!.isEmpty }
    var completedWorkflows: Set<String> {
        guard let s = workflowsRun else { return [] }
        return Set(s.split(separator: ",").map(String.init))
    }

    func absoluteURL(mountPoint: URL) -> URL {
        mountPoint.appendingPathComponent(relativePath)
    }

    /// Best display date: capture date from EXIF, falling back to file mod date.
    var displayDate: Date? {
        let src = captureDate ?? modifiedAt
        return ISO8601DateFormatter().date(from: src)
    }
}

// MARK: - DriveWorkflow

enum DriveWorkflow: String, CaseIterable, Hashable {
    case orientation = "orientation"
    case scene       = "scene"
    case faces       = "faces"
    case filmStrip   = "filmStrip"

    var displayLabel: String {
        switch self {
        case .orientation: return "Orientation"
        case .scene:       return "Scene Classification"
        case .faces:       return "Face Detection"
        case .filmStrip:   return "Film Strip Detection"
        }
    }
    var systemImage: String {
        switch self {
        case .orientation: return "rotate.right"
        case .scene:       return "photo.badge.magnifyingglass"
        case .faces:       return "person.crop.rectangle"
        case .filmStrip:   return "film"
        }
    }
    var shortDescription: String {
        switch self {
        case .orientation: return "Detect if the image needs rotation"
        case .scene:       return "Classify scene type (landscape, portrait…)"
        case .faces:       return "Count faces present in the image"
        case .filmStrip:   return "Detect film frame boundaries (YOLO)"
        }
    }
}

// MARK: - DriveIndexMeta

struct DriveIndexMeta: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "drive_meta"
    var key: String
    var value: String
}

// MARK: - IndexingStage

enum IndexingStage: String, Equatable {
    case idle                = "Idle"
    case discovering         = "Discovering Files"
    case indexing            = "Indexing Files"
    case generatingThumbnails = "Generating Thumbnails"
    case detectingDuplicates = "Finding Duplicates"
    case complete            = "Complete"

    var systemImage: String {
        switch self {
        case .idle:                return "circle.dashed"
        case .discovering:          return "folder.fill"
        case .indexing:             return "arrow.down.doc.fill"
        case .generatingThumbnails: return "photo.stack"
        case .detectingDuplicates:  return "doc.on.doc.fill"
        case .complete:            return "checkmark.circle.fill"
        }
    }
}
