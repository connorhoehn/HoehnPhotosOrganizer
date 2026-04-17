import Foundation

struct CurveFileReference: Codable, Identifiable {
    let id: String
    let originalFileName: String
    let s3Key: String
    let fileSize: Int
    let uploadedAt: String         // ISO8601
    let contentHash: String        // SHA256 hex

    enum CodingKeys: String, CodingKey {
        case id
        case originalFileName = "original_file_name"
        case s3Key = "s3_key"
        case fileSize = "file_size"
        case uploadedAt = "uploaded_at"
        case contentHash = "content_hash"
    }
}
