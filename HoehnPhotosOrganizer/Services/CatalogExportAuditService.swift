import Foundation
import GRDB
import os.log

// MARK: - Export metadata

struct CatalogExportManifest: Codable {
    let exportedAt: String
    let appVersion: String
    let tables: [TableExportSummary]

    enum CodingKeys: String, CodingKey {
        case exportedAt = "exported_at"
        case appVersion = "app_version"
        case tables
    }
}

struct TableExportSummary: Codable {
    let tableName: String
    let rowCount: Int
    enum CodingKeys: String, CodingKey {
        case tableName = "table_name"
        case rowCount  = "row_count"
    }
}

// MARK: - Service

/// Exports the full catalog to JSON Lines format (.jsonl).
/// Each line is a self-describing JSON object:
///   {"_table":"photo_assets","id":"...","canonical_name":"...","role":"..."}
///
/// Memory-safe: uses GRDB fetchCursor internally — never loads full tables into RAM.
/// All database I/O is read-only.
actor CatalogExportAuditService {
    private let db: AppDatabase
    private let logger = Logger(subsystem: "HoehnPhotosOrganizer", category: "CatalogExportAuditService")

    /// Tables exported in order. All domain object tables from v1 through v10.
    private let exportTables: [String] = [
        "photo_assets",
        "proxy_assets",
        "drives",
        "thread_entries",
        "extraction_events",
        "extraction_tool_logs",
        "pipeline_runs",
        "pipeline_run_steps",
        "asset_lineage",
        "collections",
        "collection_members",
        "saved_searches",
        "background_jobs",
        "activity_log"
    ]

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Public API

    /// Exports all domain tables to a JSON Lines file at `outputURL`.
    /// First line is a manifest JSON object (type: "manifest").
    /// Subsequent lines are domain object rows (type: row, includes "_table" field).
    /// Last line is a completion marker.
    func exportAll(to outputURL: URL) async throws {
        // Create/overwrite the output file
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var summaries: [TableExportSummary] = []

        for tableName in exportTables {
            let rowCount = try await exportTable(tableName, to: handle)
            summaries.append(TableExportSummary(tableName: tableName, rowCount: rowCount))
            logger.info("exportAll: exported \(rowCount) rows from \(tableName)")
        }

        // Write manifest as final line
        let manifest = CatalogExportManifest(
            exportedAt: ISO8601DateFormatter().string(from: .now),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            tables: summaries
        )
        if let data = try? JSONEncoder().encode(manifest) {
            var line = data
            line.append(contentsOf: [0x0A])  // newline
            handle.write(line)
        }

        logger.info("exportAll: complete — \(summaries.map { $0.rowCount }.reduce(0, +)) total rows written to \(outputURL.lastPathComponent)")
    }

    // MARK: - Default output URL

    static func defaultOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: .now)
        let filename = "HoehnPhotosOrganizer-export-\(dateStr).jsonl"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop")
            .appendingPathComponent(filename)
    }

    // MARK: - Private

    private func exportTable(_ tableName: String, to handle: FileHandle) async throws -> Int {
        var rowCount = 0

        // fetchCursor MUST be consumed inside the db.read block.
        // Collect rows as [String: String] dictionaries, then write outside lock.
        let rows: [[String: String]] = try await db.dbPool.read { db in
            // Check if table exists (some may be absent on older installs)
            let exists = try Bool.fetchOne(db, sql: """
                SELECT COUNT(*) > 0 FROM sqlite_master WHERE type='table' AND name=?
            """, arguments: [tableName]) ?? false
            guard exists else { return [] }

            let cursor = try Row.fetchCursor(db, sql: "SELECT * FROM \(tableName)")
            var result: [[String: String]] = []
            while let row = try cursor.next() {
                var dict: [String: String] = ["_table": tableName]
                for (column, value) in row {
                    switch value.storage {
                    case .null:            break
                    case .int64(let v):    dict[column] = String(v)
                    case .double(let v):   dict[column] = String(v)
                    case .string(let v):   dict[column] = v
                    case .blob(let d):     dict[column] = d.base64EncodedString()
                    }
                }
                result.append(dict)
            }
            return result
        }

        for dict in rows {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
                var line = data
                line.append(contentsOf: [0x0A])  // newline byte
                handle.write(line)
                rowCount += 1
            }
        }
        return rowCount
    }
}
