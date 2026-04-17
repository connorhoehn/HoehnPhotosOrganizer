import Foundation
import GRDB

// MARK: - PhotoCollection

/// A named collection of photo assets. kind is either "manual" (user-curated) or
/// "smart" (rule-driven). Smart collections store their criteria as JSON in rulesJson.
struct PhotoCollection: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collections"

    var id: String
    var name: String
    var kind: String          // "manual" | "smart"
    var rulesJson: String?    // JSON-encoded [SmartCollectionRule] for smart collections
    var sortOrder: Int
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case rulesJson = "rules_json"
        case sortOrder = "sort_order"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    /// Convenience initialiser that generates a UUID id and ISO8601 timestamps.
    static func new(name: String, kind: String) -> PhotoCollection {
        let now = ISO8601DateFormatter().string(from: .now)
        return PhotoCollection(
            id: UUID().uuidString,
            name: name,
            kind: kind,
            rulesJson: nil,
            sortOrder: 0,
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - CollectionMember

/// A membership row linking a photo_asset to a collection.
struct CollectionMember: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collection_members"

    var id: String
    var collectionId: String
    var photoId: String
    var addedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case collectionId = "collection_id"
        case photoId = "photo_id"
        case addedAt = "added_at"
    }
}

// MARK: - SmartCollectionRule

/// A single filtering rule used by smart collections. Stored as JSON in PhotoCollection.rulesJson.
struct SmartCollectionRule: Codable, Equatable {
    var field: Field
    var op: Operator
    var value: String?

    enum Field: String, Codable, Equatable {
        case curationState = "curation_state"
        case processingState = "processing_state"
        case syncState = "sync_state"
        case role
        case driveId = "drive_id"
    }

    enum Operator: String, Codable, Equatable {
        case equals
        case notEquals = "not_equals"
        case isNull = "is_null"
        case isNotNull = "is_not_null"
    }
}

// MARK: - CurationCounts

/// Per-state totals for the photo_assets table. Returned by PhotoRepository.curationCounts().
struct CurationCounts {
    var keeper: Int
    var archive: Int
    var needsReview: Int
    var rejected: Int
    var deleted: Int = 0
}
