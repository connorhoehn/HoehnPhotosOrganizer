import Foundation
import GRDB

/// Actor-based repository for persisting and fetching `ExtractionToolLog` records.
///
/// All writes are atomic: `save(logs:extractionId:)` inserts every converted log
/// row inside a single `db.write {}` transaction. Either all rows are written or
/// none are (on error, the write transaction rolls back automatically).
///
/// Designed for CP-1 — durable storage of `PipelineToolRun` diagnostics captured
/// during film-strip extraction. The companion CP-2 UI plan reads these logs back
/// via `fetch(extractionId:)` for display in the detail panel.
actor ExtractionToolLogRepository {

    private let db: any DatabaseWriter

    init(_ db: any DatabaseWriter) {
        self.db = db
    }

    // MARK: - Write

    /// Persists a sequence of `PipelineToolRun` values as `ExtractionToolLog` rows
    /// in the `extraction_tool_logs` table, associated with the given `extractionId`.
    ///
    /// The `toolOrder` column is set to the run's position in the array (0-based).
    /// All rows are inserted in a single write transaction — if any insert fails,
    /// the whole batch is rolled back.
    ///
    /// Saving an empty array is valid and produces no rows (no error).
    ///
    /// - Parameters:
    ///   - logs:         The ordered tool runs from `FilmStripExtractionResult.toolRuns`.
    ///   - extractionId: The `ExtractionEvent.id` to link these logs to.
    func save(logs: [PipelineToolRun], extractionId: String) async throws {
        guard !logs.isEmpty else { return }
        try await db.write { database in
            for (index, run) in logs.enumerated() {
                let log = ExtractionToolLog.from(run: run, extractionId: extractionId, order: index)
                try log.insert(database)
            }
        }
    }

    // MARK: - Read

    /// Fetches all `ExtractionToolLog` rows for the given extraction batch,
    /// ordered by `tool_order` ascending (matches original capture sequence).
    ///
    /// Returns an empty array when no rows exist for the given `extractionId`
    /// (not an error — valid for legacy events created before CP-1).
    ///
    /// - Parameter extractionId: The `ExtractionEvent.id` to query.
    /// - Returns: Ordered array of `ExtractionToolLog` for the batch.
    func fetch(extractionId: String) async throws -> [ExtractionToolLog] {
        try await db.read { database in
            try ExtractionToolLog
                .filter(Column("extraction_id") == extractionId)
                .order(Column("tool_order").asc)
                .fetchAll(database)
        }
    }
}
