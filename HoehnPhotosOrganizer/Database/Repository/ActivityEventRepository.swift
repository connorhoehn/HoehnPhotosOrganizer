import Foundation
import GRDB
import SwiftUI

actor ActivityEventRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    // Insert a new event
    func insert(_ event: ActivityEvent) async throws {
        try await db.dbPool.write { db in
            try event.insert(db)
        }
    }

    // Insert or ignore — safe to call on retry (idempotent)
    func insertOrIgnore(_ event: ActivityEvent) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO activity_events
                    (id, kind, parent_event_id, photo_asset_id, title, detail, metadata, occurred_at, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    event.id, event.kind.rawValue, event.parentEventId, event.photoAssetId,
                    event.title, event.detail, event.metadata, event.occurredAt, event.createdAt
                ]
            )
        }
    }

    // Fetch all root events (no parent), most recent first
    func fetchRootEvents(limit: Int = 100) async throws -> [ActivityEvent] {
        try await db.dbPool.read { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.parentEventId == nil)
                .order(ActivityEvent.Columns.occurredAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // Fetch direct children of an event
    func fetchChildren(of parentId: String) async throws -> [ActivityEvent] {
        try await db.dbPool.read { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.parentEventId == parentId)
                .order(ActivityEvent.Columns.occurredAt.asc)
                .fetchAll(db)
        }
    }

    // Fetch all events for a specific photo, most recent first
    func fetchEventsForPhoto(_ photoId: String, limit: Int = 50) async throws -> [ActivityEvent] {
        try await db.dbPool.read { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.photoAssetId == photoId)
                .order(ActivityEvent.Columns.occurredAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // Fetch a single event by ID
    func fetchEvent(id: String) async throws -> ActivityEvent? {
        try await db.dbPool.read { db in
            try ActivityEvent.fetchOne(db, key: id)
        }
    }

    // Fetch root events of a specific kind, most recent first
    func fetchRecent(kind: ActivityEventKind, limit: Int = 20) async throws -> [ActivityEvent] {
        try await db.dbPool.read { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.parentEventId == nil)
                .filter(ActivityEvent.Columns.kind == kind.rawValue)
                .order(ActivityEvent.Columns.occurredAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    // Observation publisher for the full root-level feed
    func feedPublisher() -> ValueObservation<ValueReducers.Fetch<[ActivityEvent]>> {
        ValueObservation.tracking { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.parentEventId == nil)
                .order(ActivityEvent.Columns.occurredAt.desc)
                .limit(200)
                .fetchAll(db)
        }
    }

    // AsyncSequence stream version — for use in @Observable ViewModels
    func feedStream() -> AsyncValueObservation<[ActivityEvent]> {
        ValueObservation.tracking { db in
            try ActivityEvent
                .filter(ActivityEvent.Columns.parentEventId == nil)
                .order(ActivityEvent.Columns.occurredAt.desc)
                .limit(200)
                .fetchAll(db)
        }
        .values(in: db.dbPool)
    }
}

// MARK: - SwiftUI environment key

private struct ActivityEventRepositoryKey: EnvironmentKey {
    static var defaultValue: ActivityEventRepository? { nil }
}

extension EnvironmentValues {
    var activityEventRepository: ActivityEventRepository? {
        get { self[ActivityEventRepositoryKey.self] }
        set { self[ActivityEventRepositoryKey.self] = newValue }
    }
}
