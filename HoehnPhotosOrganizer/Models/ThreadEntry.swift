import Foundation
import GRDB

struct ThreadEntry: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: String
    var threadRootId: String          // Foreign key: photo canonical_id
    var sequenceNumber: Int
    var kind: String                  // "print_attempt", "text_note", "ai_turn", "image_attachment"
    var authoredBy: String            // "user" | "ai"
    var contentJson: String           // JSON-encoded type-specific fields
    var createdAt: String             // ISO8601
    var syncState: String             // "local_only", "queued", "synced"
    var activityEventId: String?      // Cross-ref to the activity_event that created this entry

    static let databaseTableName = "thread_entries"

    enum CodingKeys: String, CodingKey {
        case id
        case threadRootId = "thread_root_id"
        case sequenceNumber = "sequence_number"
        case kind
        case authoredBy = "authored_by"
        case contentJson = "content_json"
        case createdAt = "created_at"
        case syncState = "sync_state"
        case activityEventId = "activity_event_id"
    }
}

// MARK: - MetadataExtractionResult

struct MetadataExtractionResult: Codable {
    let location: String?
    let people: [String]
    let occasion: String?
    let mood: String?
    let keywords: [String]

    // Phase 7: image scene classification. Do not populate in Phase 3.
    let sceneType: String?

    // Phase 7: vision API face detection. Do not populate in Phase 3.
    let peopleDetected: [String]?

    enum CodingKeys: String, CodingKey {
        case location
        case people
        case occasion
        case mood
        case keywords
        case sceneType = "scene_type"
        case peopleDetected = "people_detected"
    }
}
