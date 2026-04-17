import Foundation
import GRDB

/// GRDB-backed drive record. Named DriveDB to avoid collision with mock DriveRecord struct.
struct DriveDB: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "drives"
    var id: String
    var volumeLabel: String
    var mountPoint: String
    var totalBytes: Int
    var freeBytes: Int
    var lastSeen: String
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case volumeLabel = "volume_label"
        case mountPoint = "mount_point"
        case totalBytes = "total_bytes"
        case freeBytes = "free_bytes"
        case lastSeen = "last_seen"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}
