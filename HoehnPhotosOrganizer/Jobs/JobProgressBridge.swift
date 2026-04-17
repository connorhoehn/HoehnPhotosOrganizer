import Foundation

/// Converts a BackgroundJob cursor JSON string into a typed resume point.
/// Format: {"lastCanonicalName": "DSC_0042.NEF", "processedCount": 150}
struct JobCursor: Codable {
    let lastCanonicalName: String?
    let processedCount: Int

    enum CodingKeys: String, CodingKey {
        case lastCanonicalName = "lastCanonicalName"
        case processedCount    = "processedCount"
    }

    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    static func decoded(from json: String?) -> JobCursor? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JobCursor.self, from: data)
    }
}
