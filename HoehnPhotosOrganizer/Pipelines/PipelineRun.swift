import Foundation
import GRDB

enum PipelineRunStatus: String, Codable, CaseIterable, Sendable {
    case running, succeeded, failed, cancelled
}

struct PipelineRun: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "pipeline_runs"

    var id: String
    var pipelineId: String?
    var sourcePhotoId: String
    var status: String   // PipelineRunStatus.rawValue
    var startedAt: String
    var completedAt: String?
    var errorMessage: String?
    var outputPhotoIdsJson: String?  // JSON array of photo_asset IDs

    enum CodingKeys: String, CodingKey {
        case id
        case pipelineId = "pipeline_id"
        case sourcePhotoId = "source_photo_id"
        case status
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case errorMessage = "error_message"
        case outputPhotoIdsJson = "output_photo_ids_json"
    }

    static func new(pipelineId: String?, sourcePhotoId: String) -> PipelineRun {
        PipelineRun(
            id: UUID().uuidString,
            pipelineId: pipelineId,
            sourcePhotoId: sourcePhotoId,
            status: PipelineRunStatus.running.rawValue,
            startedAt: ISO8601DateFormatter().string(from: .now),
            completedAt: nil,
            errorMessage: nil,
            outputPhotoIdsJson: nil
        )
    }
}
