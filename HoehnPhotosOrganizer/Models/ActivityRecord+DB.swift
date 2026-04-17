import Foundation
import GRDB

struct ActivityDB: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "activity_log"
    var id: String
    var kind: String      // ActivityKind.rawValue
    var title: String
    var detail: String
    var photoId: String?
    var timestamp: String

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, timestamp
        case photoId = "photo_id"
    }
}
