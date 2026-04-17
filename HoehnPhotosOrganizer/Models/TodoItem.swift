import Foundation
import GRDB

struct TodoItem: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "todo_items"

    var id: String           // UUID string
    var photoAssetId: String
    var body: String
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date
    var sortOrder: Int       // user-defined ordering within a photo's todo list

    enum CodingKeys: String, CodingKey {
        case id
        case photoAssetId  = "photo_asset_id"
        case body
        case isCompleted   = "is_completed"
        case completedAt   = "completed_at"
        case createdAt     = "created_at"
        case sortOrder     = "sort_order"
    }

    enum Columns {
        static let id           = Column(CodingKeys.id)
        static let photoAssetId = Column(CodingKeys.photoAssetId)
        static let body         = Column(CodingKeys.body)
        static let isCompleted  = Column(CodingKeys.isCompleted)
        static let completedAt  = Column(CodingKeys.completedAt)
        static let createdAt    = Column(CodingKeys.createdAt)
        static let sortOrder    = Column(CodingKeys.sortOrder)
    }
}
