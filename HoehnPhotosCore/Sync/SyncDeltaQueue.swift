import Foundation

/// A single curation change to be synced back to Mac.
public struct PhotoCurationDelta: Codable, Identifiable, Equatable {
    public let id: String        // photoId
    public let curationState: String
    public let updatedAt: String // ISO8601

    public init(photoId: String, curationState: String) {
        self.id = photoId
        self.curationState = curationState
        self.updatedAt = ISO8601DateFormatter().string(from: Date())
    }
}

/// Proxy manifest entry for incremental sync.
public struct ProxyManifestEntry: Codable {
    public let filename: String
    public let size: Int

    public init(filename: String, size: Int) {
        self.filename = filename
        self.size = size
    }
}
