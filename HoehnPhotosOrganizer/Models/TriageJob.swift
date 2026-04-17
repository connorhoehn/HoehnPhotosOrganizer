import Foundation
import GRDB

// MARK: - Enums

enum TriageJobStatus: String, Codable, CaseIterable {
    case open
    case complete
    case archived
}

enum TriageJobSource: String, Codable, CaseIterable {
    case importBatch = "import_batch"
    case manual
    case split
}

// MARK: - Completeness field weights

struct CompletenessWeights {
    // Legacy EXIF-completeness sub-weights (kept for backward compatibility)
    static let location: Double = 0.20
    static let date: Double = 0.15
    static let gear: Double = 0.15
    static let keywords: Double = 0.10
    static let sceneType: Double = 0.10

    // Archive-readiness dimensions — each contributes 25% to overall score
    static let curation: Double = 0.25    // all photos rated
    static let people: Double = 0.25      // all faces identified
    static let developed: Double = 0.25   // keeper photos developed
    static let metadata: Double = 0.25    // keeper photos have title/caption
}

// MARK: - TriageJob

struct TriageJob: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    static let databaseTableName = "triage_jobs"

    var id: String
    var parentJobId: String?
    var title: String
    var source: TriageJobSource
    var status: TriageJobStatus
    var inheritedMetadata: String?     // JSON: fields set at this level that children inherit
    var completenessScore: Double      // 0.0–1.0
    var photoCount: Int                // denormalized for fast display
    var createdAt: Date
    var updatedAt: Date
    var completedAt: Date?
    var triageCompletedAt: Date?
    var developCompletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case parentJobId       = "parent_job_id"
        case title
        case source
        case status
        case inheritedMetadata = "inherited_metadata"
        case completenessScore = "completeness_score"
        case photoCount        = "photo_count"
        case createdAt         = "created_at"
        case updatedAt         = "updated_at"
        case completedAt         = "completed_at"
        case triageCompletedAt   = "triage_completed_at"
        case developCompletedAt  = "develop_completed_at"
    }

    enum Columns {
        static let id                = Column(CodingKeys.id)
        static let parentJobId       = Column(CodingKeys.parentJobId)
        static let title             = Column(CodingKeys.title)
        static let source            = Column(CodingKeys.source)
        static let status            = Column(CodingKeys.status)
        static let inheritedMetadata = Column(CodingKeys.inheritedMetadata)
        static let completenessScore = Column(CodingKeys.completenessScore)
        static let photoCount        = Column(CodingKeys.photoCount)
        static let createdAt         = Column(CodingKeys.createdAt)
        static let updatedAt         = Column(CodingKeys.updatedAt)
        static let completedAt       = Column(CodingKeys.completedAt)
    }

    static func == (lhs: TriageJob, rhs: TriageJob) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Factory

    static func newImportJob(title: String, photoCount: Int) -> TriageJob {
        TriageJob(
            id: UUID().uuidString,
            parentJobId: nil,
            title: title,
            source: .importBatch,
            status: .open,
            inheritedMetadata: nil,
            completenessScore: 0.0,
            photoCount: photoCount,
            createdAt: Date(),
            updatedAt: Date(),
            completedAt: nil
        )
    }

    static func newChildJob(parentId: String, title: String, photoCount: Int, source: TriageJobSource = .split) -> TriageJob {
        TriageJob(
            id: UUID().uuidString,
            parentJobId: parentId,
            title: title,
            source: source,
            status: .open,
            inheritedMetadata: nil,
            completenessScore: 0.0,
            photoCount: photoCount,
            createdAt: Date(),
            updatedAt: Date(),
            completedAt: nil
        )
    }
}

// MARK: - TriageJobPhoto (join table)

struct TriageJobPhoto: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "triage_job_photos"

    var jobId: String
    var photoId: String
    var sortOrder: Int
    var addedAt: Date

    enum CodingKeys: String, CodingKey {
        case jobId    = "job_id"
        case photoId  = "photo_id"
        case sortOrder = "sort_order"
        case addedAt  = "added_at"
    }

    enum Columns {
        static let jobId     = Column(CodingKeys.jobId)
        static let photoId   = Column(CodingKeys.photoId)
        static let sortOrder = Column(CodingKeys.sortOrder)
        static let addedAt   = Column(CodingKeys.addedAt)
    }
}
