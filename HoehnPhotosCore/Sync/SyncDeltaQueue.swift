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

// MARK: - People / Face mutations

/// A mutation on person_identities / face_embeddings originated on iOS.
/// Wire prefix on peer transport: `PEOPLE_V1:<json-array>`.
public enum PeopleSyncDelta: Codable, Identifiable, Equatable {
    case createPerson(id: String, name: String, coverFaceId: String?, createdAt: String)
    case renamePerson(id: String, name: String, updatedAt: String)
    case deletePerson(id: String, deletedAt: String)
    case mergePeople(sourceId: String, targetId: String, mergedAt: String)
    case assignFace(faceId: String, personId: String, labeledBy: String, updatedAt: String)
    case unassignFace(faceId: String, updatedAt: String)

    /// Stable-ish identifier used for de-dup within a queue flush window.
    public var id: String {
        switch self {
        case .createPerson(let id, _, _, _): return "createPerson:\(id)"
        case .renamePerson(let id, _, _): return "renamePerson:\(id)"
        case .deletePerson(let id, _): return "deletePerson:\(id)"
        case .mergePeople(let src, let tgt, _): return "mergePeople:\(src)->\(tgt)"
        case .assignFace(let faceId, _, _, _): return "assignFace:\(faceId)"
        case .unassignFace(let faceId, _): return "unassignFace:\(faceId)"
        }
    }
}

public extension PeopleSyncDelta {
    static func createPerson(name: String, coverFaceId: String? = nil) -> PeopleSyncDelta {
        .createPerson(
            id: UUID().uuidString,
            name: name,
            coverFaceId: coverFaceId,
            createdAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func renamePerson(id: String, name: String) -> PeopleSyncDelta {
        .renamePerson(id: id, name: name, updatedAt: ISO8601DateFormatter().string(from: Date()))
    }

    static func deletePerson(id: String) -> PeopleSyncDelta {
        .deletePerson(id: id, deletedAt: ISO8601DateFormatter().string(from: Date()))
    }

    static func mergePeople(source: String, target: String) -> PeopleSyncDelta {
        .mergePeople(sourceId: source, targetId: target, mergedAt: ISO8601DateFormatter().string(from: Date()))
    }

    static func assignFace(faceId: String, personId: String, labeledBy: String = "user") -> PeopleSyncDelta {
        .assignFace(
            faceId: faceId, personId: personId,
            labeledBy: labeledBy,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    static func unassignFace(faceId: String) -> PeopleSyncDelta {
        .unassignFace(faceId: faceId, updatedAt: ISO8601DateFormatter().string(from: Date()))
    }
}
