import Foundation
import GRDB

// MARK: - EventOutboxService

/// Raw DB actor for the event outbox. Handles enqueue, status transitions,
/// and count queries. Does not know about ActivityEventService or hooks —
/// that logic lives in EventOutboxProcessor.
actor EventOutboxService {

    static let maxAttempts = 5

    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    // MARK: - Enqueue

    /// Write a pending outbox entry atomically. This is the "durable" step —
    /// if the app crashes after this returns, the entry will be picked up on restart.
    func enqueue(
        kind: ActivityEventKind,
        photoAssetId: String? = nil,
        parentEventId: String? = nil,
        title: String,
        detail: String? = nil,
        metadata: String? = nil
    ) async throws {
        let entry = EventOutboxEntry(
            id: UUID().uuidString,
            kind: kind.rawValue,
            photoAssetId: photoAssetId,
            parentEventId: parentEventId,
            title: title,
            detail: detail,
            metadata: metadata,
            occurredAt: Date(),
            createdAt: Date(),
            status: .pending,
            attempts: 0,
            lastError: nil,
            processedAt: nil
        )
        try await db.dbPool.write { db in
            try entry.insert(db)
        }
    }

    // MARK: - Fetch

    func fetchPending(limit: Int = 50) async throws -> [EventOutboxEntry] {
        try await db.dbPool.read { db in
            try EventOutboxEntry
                .filter(Column("status") == OutboxStatus.pending.rawValue)
                .order(Column("occurred_at").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func fetchFailed() async throws -> [EventOutboxEntry] {
        try await db.dbPool.read { db in
            try EventOutboxEntry
                .filter(Column("status") == OutboxStatus.failed.rawValue)
                .order(Column("occurred_at").asc)
                .fetchAll(db)
        }
    }

    func pendingCount() async throws -> Int {
        try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_outbox WHERE status = 'pending'") ?? 0
        }
    }

    func failedCount() async throws -> Int {
        try await db.dbPool.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_outbox WHERE status = 'failed'") ?? 0
        }
    }

    // MARK: - Status transitions

    /// Atomically claim a pending entry for processing (prevents double-processing).
    /// Returns true if the claim succeeded (entry was still pending).
    func claim(id: String) async throws -> Bool {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE event_outbox SET status = 'processing', attempts = attempts + 1 WHERE id = ? AND status = 'pending'",
                arguments: [id]
            )
            return db.changesCount > 0
        }
    }

    func markDone(id: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE event_outbox SET status = 'done', processed_at = ?, last_error = NULL WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    func markFailed(id: String, error: String) async throws {
        try await db.dbPool.write { db in
            // After max attempts, keep as failed — otherwise back to pending for retry
            let attemptsRow = try Row.fetchOne(db, sql: "SELECT attempts FROM event_outbox WHERE id = ?", arguments: [id])
            let attempts = attemptsRow?["attempts"] as? Int ?? 0
            let newStatus = attempts >= EventOutboxService.maxAttempts ? "failed" : "pending"
            try db.execute(
                sql: "UPDATE event_outbox SET status = ?, last_error = ? WHERE id = ?",
                arguments: [newStatus, error, id]
            )
        }
    }

    /// Re-queue all failed entries for retry.
    @discardableResult
    func resetFailed() async throws -> Int {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE event_outbox SET status = 'pending', attempts = 0, last_error = NULL WHERE status = 'failed'"
            )
            return db.changesCount
        }
    }

    // MARK: - Observation

    func pendingCountStream() -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_outbox WHERE status IN ('pending', 'processing')") ?? 0
            }
            .values(in: db.dbPool)
    }

    func failedCountStream() -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_outbox WHERE status = 'failed'") ?? 0
            }
            .values(in: db.dbPool)
    }
}

// MARK: - SwiftUI environment key

import SwiftUI

private struct EventOutboxServiceKey: EnvironmentKey {
    static var defaultValue: EventOutboxService? { nil }
}

extension EnvironmentValues {
    var eventOutboxService: EventOutboxService? {
        get { self[EventOutboxServiceKey.self] }
        set { self[EventOutboxServiceKey.self] = newValue }
    }
}
