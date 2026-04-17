import Foundation
import GRDB

// MARK: - Export model types

/// Top-level JSON structure written to the sidecar file.
struct PhotoExportPayload: Codable {
    let photo: PhotoExportInfo
    let metadata: MetadataExportInfo
    let metadataEdits: [MetadataEditRecord]
    let thread: [ThreadExportEntry]
    let exportTimestamp: String

    enum CodingKeys: String, CodingKey {
        case photo
        case metadata
        case metadataEdits = "metadata_edits"
        case thread
        case exportTimestamp = "export_timestamp"
    }
}

struct PhotoExportInfo: Codable {
    let id: String
    let canonicalName: String
    let originalPath: String
    let createdAt: String
    let updatedAt: String
    let curationState: String
    let processingState: String
    let exif: [String: String]?
    let fileHash: String?
    let colorProfile: String?
    let bitDepth: Int?
    let dpiX: Double?
    let dpiY: Double?
    let hasAlpha: Bool?
    let isGrayscale: Bool?
    let sceneType: String?
    let peopleDetected: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case canonicalName = "canonical_name"
        case originalPath = "original_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case curationState = "curation_state"
        case processingState = "processing_state"
        case exif
        case fileHash = "file_hash"
        case colorProfile = "color_profile"
        case bitDepth = "bit_depth"
        case dpiX = "dpi_x"
        case dpiY = "dpi_y"
        case hasAlpha = "has_alpha"
        case isGrayscale = "is_grayscale"
        case sceneType = "scene_type"
        case peopleDetected = "people_detected"
    }
}

struct MetadataExportInfo: Codable {
    let location: String?
    let people: [String]
    let occasion: String?
    let mood: String?
    let keywords: [String]

    enum CodingKeys: String, CodingKey {
        case location, people, occasion, mood, keywords
    }
}

struct MetadataEditRecord: Codable {
    let field: String
    let oldValue: String?
    let newValue: String?
    let editedAt: String

    enum CodingKeys: String, CodingKey {
        case field
        case oldValue = "before"
        case newValue = "after"
        case editedAt = "timestamp"
    }
}

struct ThreadExportEntry: Codable {
    let id: String
    let kind: String
    let content: String
    let createdAt: String
    let authoredBy: String

    enum CodingKeys: String, CodingKey {
        case id, kind, content
        case createdAt = "created_at"
        case authoredBy = "authored_by"
    }
}

// MARK: - MetadataExportService

/// Generates JSON sidecar files containing the full photo story:
/// photo metadata, user-edited metadata, metadata edit history, and thread entries.
///
/// Sidecar files are written to:
///   ~/Library/Application Support/HoehnPhotosOrganizer/exports/{canonicalId}.json
///
/// REQ: META-8 (JSON export), THR-4 (thread sync-ready storage)
@MainActor
final class MetadataExportService {

    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Public API

    /// Export all metadata for a photo to a JSON sidecar file.
    ///
    /// - Parameter photoId: The `canonical_name` (or `id`) of the photo asset.
    ///   If no match by `id` is found the service falls back to `canonical_name`.
    /// - Returns: URL of the written JSON file.
    /// - Throws: `MetadataExportError` on fetch or write failure.
    func exportMetadataAsJSON(photoId: String) async throws -> URL {
        // 1. Fetch the photo from the database.
        let photo = try await fetchPhoto(id: photoId)

        // 2. Fetch thread entries in chronological order.
        let entries = try await fetchThreadEntries(for: photoId)

        // 3. Parse metadata fields from the photo record.
        let metadataInfo = parseUserMetadata(from: photo)
        let editHistory = parseMetadataEdits(from: photo)
        let exifDict = parseExif(from: photo)

        // 4. Build the export payload.
        let photoInfo = PhotoExportInfo(
            id: photo.id,
            canonicalName: photo.canonicalName,
            originalPath: photo.filePath,
            createdAt: photo.createdAt,
            updatedAt: photo.updatedAt,
            curationState: photo.curationState,
            processingState: photo.processingState,
            exif: exifDict,
            fileHash: photo.fileHash,
            colorProfile: photo.colorProfile,
            bitDepth: photo.bitDepth,
            dpiX: photo.dpiX,
            dpiY: photo.dpiY,
            hasAlpha: photo.hasAlpha,
            isGrayscale: photo.isGrayscale,
            sceneType: photo.sceneType,
            peopleDetected: photo.peopleDetected
        )

        let threadEntries = entries.map { entry in
            ThreadExportEntry(
                id: entry.id,
                kind: entry.kind,
                content: entry.contentJson,
                createdAt: entry.createdAt,
                authoredBy: entry.authoredBy
            )
        }

        let payload = PhotoExportPayload(
            photo: photoInfo,
            metadata: metadataInfo,
            metadataEdits: editHistory,
            thread: threadEntries,
            exportTimestamp: ISO8601DateFormatter().string(from: .now)
        )

        // 5. Encode and write to disk.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)

        let outputURL = try sidecarURL(canonicalId: photo.canonicalName)
        try data.write(to: outputURL, options: .atomic)
        return outputURL
    }

    // MARK: - Helpers

    private func fetchPhoto(id: String) async throws -> PhotoAsset {
        let result = try await db.dbPool.read { db -> PhotoAsset? in
            // Try by primary key (UUID) first, then fall back to canonical_name.
            if let asset = try PhotoAsset.fetchOne(db, key: id) {
                return asset
            }
            return try PhotoAsset
                .filter(Column("canonical_name") == id)
                .fetchOne(db)
        }
        guard let photo = result else {
            throw MetadataExportError.photoNotFound(id)
        }
        return photo
    }

    private func fetchThreadEntries(for photoId: String) async throws -> [ThreadEntry] {
        try await db.dbPool.read { db in
            try ThreadEntry
                .filter(Column("thread_root_id") == photoId)
                .order(Column("sequence_number").asc)
                .fetchAll(db)
        }
    }

    private func parseUserMetadata(from photo: PhotoAsset) -> MetadataExportInfo {
        guard let json = photo.userMetadataJson,
              let data = json.data(using: .utf8),
              let extraction = try? JSONDecoder().decode(MetadataExtractionResult.self, from: data) else {
            return MetadataExportInfo(location: nil, people: [], occasion: nil, mood: nil, keywords: [])
        }
        return MetadataExportInfo(
            location: extraction.location,
            people: extraction.people,
            occasion: extraction.occasion,
            mood: extraction.mood,
            keywords: extraction.keywords
        )
    }

    private func parseMetadataEdits(from photo: PhotoAsset) -> [MetadataEditRecord] {
        guard let json = photo.metadataEdits,
              let data = json.data(using: .utf8),
              let rawEdits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return rawEdits.compactMap { dict -> MetadataEditRecord? in
            guard let field = dict["field"] as? String,
                  let editedAt = dict["editedAt"] as? String else { return nil }
            return MetadataEditRecord(
                field: field,
                oldValue: dict["oldValue"] as? String,
                newValue: dict["newValue"] as? String,
                editedAt: editedAt
            )
        }
    }

    private func parseExif(from photo: PhotoAsset) -> [String: String]? {
        guard let json = photo.rawExifJson,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Convert all values to String for a uniform, portable representation.
        return dict.reduce(into: [String: String]()) { result, pair in
            result[pair.key] = "\(pair.value)"
        }
    }

    /// Returns the URL for the sidecar JSON file.
    /// Creates the exports directory if it doesn't exist.
    func sidecarURL(canonicalId: String) throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let exportsDir = appSupport
            .appendingPathComponent("HoehnPhotosOrganizer", isDirectory: true)
            .appendingPathComponent("exports", isDirectory: true)
        try fm.createDirectory(at: exportsDir, withIntermediateDirectories: true)
        return exportsDir.appendingPathComponent("\(canonicalId).json")
    }
}

// MARK: - Errors

enum MetadataExportError: LocalizedError {
    case photoNotFound(String)
    case encodingFailed(Error)
    case writeFailed(URL, Error)

    var errorDescription: String? {
        switch self {
        case .photoNotFound(let id):
            return "Photo not found: \(id)"
        case .encodingFailed(let error):
            return "JSON encoding failed: \(error.localizedDescription)"
        case .writeFailed(let url, let error):
            return "Failed to write sidecar to \(url.path): \(error.localizedDescription)"
        }
    }
}
