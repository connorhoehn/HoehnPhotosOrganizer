import Foundation
import GRDB

/// GRDB record type for the `extraction_tool_logs` table (v6_extraction_tool_logs migration).
///
/// Records one row per `PipelineToolRun` step within a single film-strip extraction batch.
/// Tool logs are ordered by `toolOrder` (0-based) and linked to an `ExtractionEvent` via
/// `extractionId` with CASCADE delete.
///
/// Use `ExtractionToolLogRepository` to persist and fetch these records.
struct ExtractionToolLog: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "extraction_tool_logs"

    var id: String                      // UUID string (primary key)
    var extractionId: String            // FK → extraction_events.id
    var toolName: String                // e.g. "VisionRectangles", "ProjectionFallback"
    var status: PipelineToolStatus      // started | succeeded | failed | skipped | fallback
    var detail: String                  // diagnostic message
    var toolOrder: Int                  // 0-based sequence index within the batch
    var createdAt: String               // ISO8601

    enum CodingKeys: String, CodingKey {
        case id
        case extractionId = "extraction_id"
        case toolName = "tool_name"
        case status
        case detail
        case toolOrder = "tool_order"
        case createdAt = "created_at"
    }
}

extension ExtractionToolLog {
    /// Converts a `PipelineToolRun` to an `ExtractionToolLog` for database persistence.
    ///
    /// - Parameters:
    ///   - run:          The tool run captured by `FilmStripFrameExtractor`.
    ///   - extractionId: The `ExtractionEvent.id` this log belongs to.
    ///   - order:        The 0-based position of this run within the extraction batch.
    static func from(run: PipelineToolRun, extractionId: String, order: Int) -> ExtractionToolLog {
        ExtractionToolLog(
            id: run.id.uuidString,
            extractionId: extractionId,
            toolName: run.name,
            status: run.status,
            detail: run.detail,
            toolOrder: order,
            createdAt: run.timestamp
        )
    }
}
