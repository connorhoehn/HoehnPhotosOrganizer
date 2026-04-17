import Foundation
import GRDB

struct SyncStateRecord: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sync_metadata"

    var key: String
    var value: String
    var updatedAt: String

    var id: String { key }

    enum Columns {
        static let key = Column(CodingKeys.key)
        static let value = Column(CodingKeys.value)
        static let updatedAt = Column(CodingKeys.updatedAt)
    }

    enum CodingKeys: String, CodingKey {
        case key
        case value
        case updatedAt = "updated_at"
    }

    init(key: String, value: String) {
        self.key = key
        self.value = value
        self.updatedAt = ISO8601DateFormatter().string(from: Date())
    }

    init(key: String, value: String, updatedAt: String) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}
