import Foundation
import GRDB

enum PipelineRunStepStatus: String, Codable, CaseIterable, Sendable {
    case running, succeeded, failed, skipped
}

struct PipelineRunStep: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "pipeline_run_steps"

    var id: String
    var runId: String
    var stepOrder: Int
    var stepType: String   // PipelineStepType.rawValue
    var status: String     // PipelineRunStepStatus.rawValue
    var detail: String?
    var startedAt: String
    var completedAt: String?
    var paramsJson: String?

    enum CodingKeys: String, CodingKey {
        case id
        case runId = "run_id"
        case stepOrder = "step_order"
        case stepType = "step_type"
        case status
        case detail
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case paramsJson = "params_json"
    }
}
