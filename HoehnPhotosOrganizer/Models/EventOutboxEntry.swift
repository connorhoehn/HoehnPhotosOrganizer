import Foundation
import GRDB

// MARK: - OutboxStatus

enum OutboxStatus: String, Codable, Sendable {
    case pending    = "pending"
    case processing = "processing"
    case done       = "done"
    case failed     = "failed"
}

// MARK: - EventOutboxEntry

/// A durable, SQLite-backed record that represents a pending activity event.
/// Events are written here first (atomically, synchronously), then promoted
/// to `activity_events` by `EventOutboxProcessor` — surviving app crashes.
///
/// Uses the same `id` as the eventual `ActivityEvent` for idempotent retry.
struct EventOutboxEntry: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "event_outbox"

    var id: String               // UUID — shared with eventual ActivityEvent for idempotency
    var kind: String             // ActivityEventKind raw value
    var photoAssetId: String?
    var parentEventId: String?
    var title: String
    var detail: String?
    var metadata: String?        // JSON blob for kind-specific data
    var occurredAt: Date
    var createdAt: Date
    var status: OutboxStatus     // pending → processing → done/failed
    var attempts: Int            // retry counter (max 5)
    var lastError: String?       // last failure message
    var processedAt: Date?       // when successfully promoted to activity_events

    enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, metadata, status, attempts
        case photoAssetId  = "photo_asset_id"
        case parentEventId = "parent_event_id"
        case occurredAt    = "occurred_at"
        case createdAt     = "created_at"
        case lastError     = "last_error"
        case processedAt   = "processed_at"
    }

    // MARK: - Factory

    static func make(
        kind: ActivityEventKind,
        photoAssetId: String? = nil,
        parentEventId: String? = nil,
        title: String,
        detail: String? = nil,
        metadata: [String: Any]? = nil
    ) -> EventOutboxEntry {
        let metaJson = metadata.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        return EventOutboxEntry(
            id: UUID().uuidString,
            kind: kind.rawValue,
            photoAssetId: photoAssetId,
            parentEventId: parentEventId,
            title: title,
            detail: detail,
            metadata: metaJson,
            occurredAt: Date(),
            createdAt: Date(),
            status: .pending,
            attempts: 0,
            lastError: nil,
            processedAt: nil
        )
    }
}

// MARK: - OutboxError

enum OutboxError: Error, LocalizedError {
    case unknownKind(String)
    case maxRetriesExceeded(String)

    var errorDescription: String? {
        switch self {
        case .unknownKind(let k):      return "Unknown event kind '\(k)'"
        case .maxRetriesExceeded(let id): return "Max retries exceeded for outbox entry \(id)"
        }
    }
}
