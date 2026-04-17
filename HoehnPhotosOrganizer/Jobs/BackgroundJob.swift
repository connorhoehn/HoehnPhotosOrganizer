import Foundation
import GRDB

// MARK: - Enums

enum JobType: String, Codable, CaseIterable {
    case ingestion          = "ingestion"
    case proxyGeneration    = "proxyGeneration"
    case duplicateScan      = "duplicateScan"
    case catalogExport      = "catalogExport"
    case filmScanImport     = "filmScanImport"
}

enum JobStatus: String, Codable {
    case pending     = "pending"
    case running     = "running"
    case interrupted = "interrupted"
    case completed   = "completed"
    case failed      = "failed"
}

// MARK: - GRDB Record

struct BackgroundJob: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "background_jobs"

    var id: String
    var type: String          // JobType.rawValue
    var status: String        // JobStatus.rawValue
    var driveId: String?
    var cursorJson: String?
    var errorMessage: String?
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, type, status
        case driveId      = "drive_id"
        case cursorJson   = "cursor_json"
        case errorMessage = "error_message"
        case createdAt    = "created_at"
        case updatedAt    = "updated_at"
    }

    static func new(type: JobType, driveId: String? = nil) -> BackgroundJob {
        let now = ISO8601DateFormatter().string(from: .now)
        return BackgroundJob(
            id: UUID().uuidString,
            type: type.rawValue,
            status: JobStatus.running.rawValue,
            driveId: driveId,
            cursorJson: nil,
            errorMessage: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}
