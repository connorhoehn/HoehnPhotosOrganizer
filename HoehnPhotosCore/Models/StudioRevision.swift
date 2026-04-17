import Foundation
import GRDB

// MARK: - StudioMedium

/// Shared enum mirroring the macOS ArtMedium cases and raw values.
/// Platform-agnostic — no SwiftUI or AppKit/UIKit dependencies.
public enum StudioMedium: String, CaseIterable, Identifiable, Codable {
    case oil = "Oil Painting"
    case watercolor = "Watercolor"
    case charcoal = "Charcoal"
    case troisCrayon = "Trois Crayon"
    case graphite = "Graphite"
    case inkWash = "Ink Wash"
    case pastel = "Pastel"
    case penAndInk = "Pen & Ink"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .oil:         return "drop.fill"
        case .watercolor:  return "drop.triangle"
        case .charcoal:    return "scribble"
        case .troisCrayon: return "pencil.and.outline"
        case .graphite:    return "pencil"
        case .inkWash:     return "paintbrush"
        case .pastel:      return "circle.lefthalf.filled"
        case .penAndInk:   return "pencil.tip"
        }
    }

    public var displayDescription: String {
        switch self {
        case .oil:         return "Rich, textured brushstrokes with visible impasto"
        case .watercolor:  return "Transparent washes and wet-on-wet bleeding"
        case .charcoal:    return "Deep blacks and soft gradations"
        case .troisCrayon: return "Sanguine, sepia, and white chalk on toned paper"
        case .graphite:    return "Fine hatching and smooth tonal gradation"
        case .inkWash:     return "East Asian brush painting with ink dilution"
        case .pastel:      return "Soft, chalky color with blended passages"
        case .penAndInk:   return "Cross-hatching, stippling, and line work"
        }
    }
}

// MARK: - StudioParameters

/// Render parameters used for a Studio revision.
/// Mirrors MediumParameters from the macOS target.
public struct StudioParameters: Equatable, Codable {
    public var brushSize: Double       // 1–20
    public var detail: Double          // 0–1
    public var texture: Double         // 0–1
    public var colorSaturation: Double // 0–1
    public var contrast: Double        // 0–1

    public init(brushSize: Double, detail: Double, texture: Double, colorSaturation: Double, contrast: Double) {
        self.brushSize = brushSize
        self.detail = detail
        self.texture = texture
        self.colorSaturation = colorSaturation
        self.contrast = contrast
    }
}

// MARK: - StudioRevision

/// A single Studio render result stored in the database.
/// Created on macOS when a render completes; synced to iOS for read-only browsing.
public struct StudioRevision: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "studio_revisions"

    public var id: String            // UUID string
    public var photoId: String       // FK to photo_assets.id
    public var name: String          // User-visible label, e.g. "Oil Painting — Mar 30, 2026"
    public var medium: String        // StudioMedium.rawValue
    public var paramsJson: String    // JSON-encoded StudioParameters
    public var createdAt: String     // ISO 8601
    public var thumbnailPath: String? // Relative path to JPEG thumbnail
    public var fullResPath: String?  // Relative path to full-res render

    enum CodingKeys: String, CodingKey {
        case id
        case photoId = "photo_id"
        case name
        case medium
        case paramsJson = "params_json"
        case createdAt = "created_at"
        case thumbnailPath = "thumbnail_path"
        case fullResPath = "full_res_path"
    }

    // MARK: - Convenience accessors

    /// Decoded medium enum. Falls back to `.oil` if the raw value is unrecognised.
    public var studioMedium: StudioMedium {
        StudioMedium(rawValue: medium) ?? .oil
    }

    /// Decoded render parameters. Returns nil if JSON is malformed.
    public var parameters: StudioParameters? {
        guard let data = paramsJson.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(StudioParameters.self, from: data)
    }

    // MARK: - Factory

    public static func create(
        photoId: String,
        name: String,
        medium: StudioMedium,
        params: StudioParameters,
        thumbnailPath: String? = nil,
        fullResPath: String? = nil
    ) -> StudioRevision {
        let encoder = JSONEncoder()
        let paramsJson = (try? encoder.encode(params)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return StudioRevision(
            id: UUID().uuidString,
            photoId: photoId,
            name: name,
            medium: medium.rawValue,
            paramsJson: paramsJson,
            createdAt: ISO8601DateFormatter().string(from: .now),
            thumbnailPath: thumbnailPath,
            fullResPath: fullResPath
        )
    }
}
