import Foundation
import GRDB

struct ProxyAsset: Identifiable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "proxy_assets"
    var id: String
    var photoId: String
    var filePath: String
    var width: Int
    var height: Int
    var byteSize: Int
    /// PRX-10: Optional path to the 300 px thumbnail JPEG in proxies/thumbs/
    var thumbnailPath: String?
    /// PRX-10: Byte size of the 300 px thumbnail JPEG; nil if not yet generated
    var thumbnailByteSize: Int?
    var createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, width, height
        case photoId = "photo_id"
        case filePath = "file_path"
        case byteSize = "byte_size"
        case thumbnailPath = "thumbnail_path"
        case thumbnailByteSize = "thumbnail_byte_size"
        case createdAt = "created_at"
    }
}
