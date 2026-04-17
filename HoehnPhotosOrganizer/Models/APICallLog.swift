import Foundation
import GRDB

/// A single logged API call to the Anthropic Messages API.
struct APICallLog: Identifiable, Codable, FetchableRecord, PersistableRecord {
    var id: String
    var model: String              // e.g. "claude-haiku-4-5-20251001"
    var label: String              // e.g. "refine(turn 2)", "editorial critique"
    var inputTokens: Int
    var outputTokens: Int
    var estimatedCostUSD: Double   // Computed at log time
    var durationMs: Int
    var calledAt: Date

    static let databaseTableName = "api_call_logs"

    enum CodingKeys: String, CodingKey {
        case id
        case model
        case label
        case inputTokens  = "input_tokens"
        case outputTokens = "output_tokens"
        case estimatedCostUSD = "estimated_cost_usd"
        case durationMs   = "duration_ms"
        case calledAt     = "called_at"
    }
}
