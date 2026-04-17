import Foundation
import GRDB

public enum ActivityEventKind: String, Codable, CaseIterable {
    case importBatch         = "import_batch"
    case frameExtraction     = "frame_extraction"
    case adjustment          = "adjustment"
    case colorGrade          = "color_grade"
    case printAttempt        = "print_attempt"
    case batchTransform      = "batch_transform"
    case reAdjustment        = "re_adjustment"
    case note                = "note"
    case todo                = "todo"
    case rollback            = "rollback"
    case pipelineRun         = "pipeline_run"
    case editorialReview     = "editorial_review"
    case faceDetection       = "face_detection"
    case metadataEnrichment  = "metadata_enrichment"
    case printJob            = "print_job"           // Parent thread for a print session
    case scanAttachment      = "scan_attachment"     // Photo/scan attached from mobile or Finder
    case aiSummary           = "ai_summary"          // AI-generated thread summary or analysis
    case search              = "search"              // Conversational search session

    /// Human-readable label for filter chips.
    public var filterLabel: String {
        switch self {
        case .importBatch:        return "import"
        case .frameExtraction:    return "extraction"
        case .adjustment:         return "adjustment"
        case .colorGrade:         return "color grade"
        case .printAttempt:       return "print attempt"
        case .batchTransform:     return "transform"
        case .reAdjustment:       return "re-adjustment"
        case .note:               return "note"
        case .todo:               return "to-do"
        case .rollback:           return "rollback"
        case .pipelineRun:        return "pipeline"
        case .editorialReview:    return "review"
        case .faceDetection:      return "face detection"
        case .metadataEnrichment: return "metadata"
        case .printJob:           return "print job"
        case .scanAttachment:     return "scan"
        case .aiSummary:          return "AI"
        case .search:             return "search"
        }
    }
}

public struct ActivityEvent: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static func == (lhs: ActivityEvent, rhs: ActivityEvent) -> Bool {
        lhs.id == rhs.id
    }
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static let databaseTableName = "activity_events"

    public var id: String               // UUID string
    public var kind: ActivityEventKind
    public var parentEventId: String?   // nil = root event
    public var photoAssetId: String?    // associated photo (optional — batch events may not have one)
    public var title: String
    public var detail: String?
    public var metadata: String?        // JSON blob for kind-specific data
    public var occurredAt: Date
    public var createdAt: Date
    public var savedSearchRuleId: String? = nil  // Cross-ref to saved_searches rule that triggered this event

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case parentEventId    = "parent_event_id"
        case photoAssetId     = "photo_asset_id"
        case title
        case detail
        case metadata
        case occurredAt       = "occurred_at"
        case createdAt        = "created_at"
        case savedSearchRuleId = "saved_search_rule_id"
    }

    public enum Columns {
        static let id                = Column(CodingKeys.id)
        static let kind              = Column(CodingKeys.kind)
        static let parentEventId     = Column(CodingKeys.parentEventId)
        static let photoAssetId      = Column(CodingKeys.photoAssetId)
        static let title             = Column(CodingKeys.title)
        static let detail            = Column(CodingKeys.detail)
        static let metadata          = Column(CodingKeys.metadata)
        static let occurredAt        = Column(CodingKeys.occurredAt)
        static let createdAt         = Column(CodingKeys.createdAt)
        static let savedSearchRuleId = Column(CodingKeys.savedSearchRuleId)
    }
}
