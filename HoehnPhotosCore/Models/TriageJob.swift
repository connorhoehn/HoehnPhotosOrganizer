import Foundation
import GRDB

// MARK: - Enums

public enum TriageJobStatus: String, Codable, CaseIterable, Sendable {
    case open
    case complete
    case archived
}

public enum JobMilestone: String, Codable, CaseIterable, Sendable {
    case triage
    case develop
    case print

    public var order: Int {
        switch self {
        case .triage: return 0
        case .develop: return 1
        case .print: return 2
        }
    }
}

public enum TriageJobSource: String, Codable, CaseIterable, Sendable {
    case importBatch = "import_batch"
    case manual
    case split
}

// MARK: - Completeness field weights

public struct CompletenessWeights {
    // Legacy EXIF-completeness sub-weights (kept for backward compatibility)
    public static let location: Double = 0.20
    public static let date: Double = 0.15
    public static let gear: Double = 0.15
    public static let keywords: Double = 0.10
    public static let sceneType: Double = 0.10

    // Archive-readiness dimensions — each contributes 25% to overall score
    public static let curation: Double = 0.25    // all photos rated
    public static let people: Double = 0.25      // all faces identified
    public static let developed: Double = 0.25   // keeper photos developed
    public static let metadata: Double = 0.25    // keeper photos have title/caption
}

// MARK: - TriageJob

public struct TriageJob: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Hashable {
    public static let databaseTableName = "triage_jobs"

    public var id: String
    public var parentJobId: String?
    public var title: String
    public var source: TriageJobSource
    public var status: TriageJobStatus
    public var inheritedMetadata: String?     // JSON: fields set at this level that children inherit
    public var completenessScore: Double      // 0.0–1.0
    public var photoCount: Int                // denormalized for fast display
    public var currentMilestone: JobMilestone
    public var triageCompletedAt: Date?
    public var developCompletedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case parentJobId       = "parent_job_id"
        case title
        case source
        case status
        case inheritedMetadata = "inherited_metadata"
        case completenessScore  = "completeness_score"
        case photoCount         = "photo_count"
        case currentMilestone   = "current_milestone"
        case triageCompletedAt  = "triage_completed_at"
        case developCompletedAt = "develop_completed_at"
        case createdAt          = "created_at"
        case updatedAt         = "updated_at"
        case completedAt       = "completed_at"
    }

    public enum Columns {
        static let id                = Column(CodingKeys.id)
        static let parentJobId       = Column(CodingKeys.parentJobId)
        static let title             = Column(CodingKeys.title)
        static let source            = Column(CodingKeys.source)
        static let status            = Column(CodingKeys.status)
        static let inheritedMetadata = Column(CodingKeys.inheritedMetadata)
        static let completenessScore  = Column(CodingKeys.completenessScore)
        static let photoCount         = Column(CodingKeys.photoCount)
        static let currentMilestone   = Column(CodingKeys.currentMilestone)
        static let triageCompletedAt  = Column(CodingKeys.triageCompletedAt)
        static let developCompletedAt = Column(CodingKeys.developCompletedAt)
        static let createdAt          = Column(CodingKeys.createdAt)
        static let updatedAt         = Column(CodingKeys.updatedAt)
        static let completedAt       = Column(CodingKeys.completedAt)
    }

    public static func == (lhs: TriageJob, rhs: TriageJob) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Factory

    public static func newImportJob(title: String, photoCount: Int) -> TriageJob {
        TriageJob(
            id: UUID().uuidString,
            parentJobId: nil,
            title: title,
            source: .importBatch,
            status: .open,
            inheritedMetadata: nil,
            completenessScore: 0.0,
            photoCount: photoCount,
            currentMilestone: .triage,
            triageCompletedAt: nil,
            developCompletedAt: nil,
            createdAt: Date(),
            updatedAt: Date(),
            completedAt: nil
        )
    }

    public static func newChildJob(parentId: String, title: String, photoCount: Int, source: TriageJobSource = .split, milestone: JobMilestone = .triage) -> TriageJob {
        TriageJob(
            id: UUID().uuidString,
            parentJobId: parentId,
            title: title,
            source: source,
            status: .open,
            inheritedMetadata: nil,
            completenessScore: 0.0,
            photoCount: photoCount,
            currentMilestone: milestone,
            triageCompletedAt: nil,
            developCompletedAt: nil,
            createdAt: Date(),
            updatedAt: Date(),
            completedAt: nil
        )
    }
}

// MARK: - TriageJobPhoto (join table)

public struct TriageJobPhoto: Codable, FetchableRecord, PersistableRecord, Sendable {
    public static let databaseTableName = "triage_job_photos"

    public var jobId: String
    public var photoId: String
    public var sortOrder: Int
    public var addedAt: Date

    enum CodingKeys: String, CodingKey {
        case jobId    = "job_id"
        case photoId  = "photo_id"
        case sortOrder = "sort_order"
        case addedAt  = "added_at"
    }

    public enum Columns {
        static let jobId     = Column(CodingKeys.jobId)
        static let photoId   = Column(CodingKeys.photoId)
        static let sortOrder = Column(CodingKeys.sortOrder)
        static let addedAt   = Column(CodingKeys.addedAt)
    }
}
