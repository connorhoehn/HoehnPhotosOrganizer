import Foundation
import GRDB

public struct DevelopmentVersion: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "development_versions"

    public var id: String
    public var photoId: String
    public var name: String
    public var adjustmentsJson: String
    public var masksJson: String?
    public var isPublished: Bool
    public var isDefault: Bool
    public var createdAt: String
    public var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case photoId = "photo_id"
        case name
        case adjustmentsJson = "adjustments_json"
        case masksJson = "masks_json"
        case isPublished = "is_published"
        case isDefault = "is_default"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public static func newVersion(photoId: String, name: String, adjustmentsJson: String, isDefault: Bool = false) -> DevelopmentVersion {
        let now = ISO8601DateFormatter().string(from: .now)
        return DevelopmentVersion(
            id: UUID().uuidString,
            photoId: photoId,
            name: name,
            adjustmentsJson: adjustmentsJson,
            isPublished: false,
            isDefault: isDefault,
            createdAt: now,
            updatedAt: now
        )
    }

    /// Create a new version with an auto-incremented name (v1, v2, v3...).
    public static func nextVersion(photoId: String, adjustmentsJson: String, masksJson: String?, existingCount: Int) -> DevelopmentVersion {
        let name = "v\(existingCount + 1)"
        let now = ISO8601DateFormatter().string(from: .now)
        return DevelopmentVersion(
            id: UUID().uuidString,
            photoId: photoId,
            name: name,
            adjustmentsJson: adjustmentsJson,
            masksJson: masksJson,
            isPublished: false,
            isDefault: existingCount == 0,
            createdAt: now,
            updatedAt: now
        )
    }
}
