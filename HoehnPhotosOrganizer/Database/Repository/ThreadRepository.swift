import Foundation
import GRDB

// MARK: - ThreadRepository

actor ThreadRepository: ThreadEntryRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Reads

    /// Fetch all thread entries for a photo in chronological order (ascending by sequence_number).
    func thread(for photoId: String) async throws -> [ThreadEntry] {
        try await db.dbPool.read { db in
            try ThreadEntry
                .filter(Column("thread_root_id") == photoId)
                .order(Column("sequence_number").asc)
                .fetchAll(db)
        }
    }

    // MARK: - Writes

    /// Add a new entry to a thread, auto-incrementing the sequence number.
    /// The MAX(sequence_number) query and INSERT are performed in a single write
    /// transaction to prevent UNIQUE constraint violations under concurrent access.
    func addEntry(
        photoId: String,
        kind: String,
        contentJson: String,
        authoredBy: String
    ) async throws {
        let now = ISO8601DateFormatter().string(from: .now)
        let entryId = UUID().uuidString

        try await db.dbPool.write { db in
            // Compute the next sequence number inside the same transaction as the
            // INSERT so no concurrent writer can grab the same number.
            let maxSeq = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence_number), 0) FROM thread_entries WHERE thread_root_id = ?",
                arguments: [photoId]
            ) ?? 0

            let entry = ThreadEntry(
                id: entryId,
                threadRootId: photoId,
                sequenceNumber: maxSeq + 1,
                kind: kind,
                authoredBy: authoredBy,
                contentJson: contentJson,
                createdAt: now,
                syncState: "local_only"
            )
            try entry.insert(db)
        }
    }

    /// Delete a specific thread entry by ID.
    func deleteEntry(id: String) async throws {
        _ = try await db.dbPool.write { db in
            try ThreadEntry.deleteOne(db, key: id)
        }
    }

    // MARK: - Streaming

    /// Create a live stream of thread entries for a photo, ordered chronologically.
    /// Emits a new value on every DB change via GRDB ValueObservation.
    func threadStream(for photoId: String) -> AsyncValueObservation<[ThreadEntry]> {
        ValueObservation
            .tracking { db in
                try ThreadEntry
                    .filter(Column("thread_root_id") == photoId)
                    .order(Column("sequence_number").asc)
                    .fetchAll(db)
            }
            .values(in: db.dbPool)
    }

    // MARK: - Cloud Sync Support

    /// Fetch all entries with a specific syncState value (e.g. "queued", "synced").
    func fetchEntriesWithSyncState(_ syncState: String) async throws -> [ThreadEntry] {
        try await db.dbPool.read { db in
            try ThreadEntry
                .filter(Column("sync_state") == syncState)
                .fetchAll(db)
        }
    }

    /// Update the syncState of a single thread entry by ID.
    func updateSyncState(entryId: String, syncState: String) async throws {
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE thread_entries SET sync_state = ? WHERE id = ?",
                arguments: [syncState, entryId]
            )
        }
    }

    /// Fetch all thread entries for a photo in chronological order.
    func fetchEntries(forPhoto photoId: String) async throws -> [ThreadEntry] {
        try await db.dbPool.read { db in
            try ThreadEntry
                .filter(Column("thread_root_id") == photoId)
                .order(Column("sequence_number").asc)
                .fetchAll(db)
        }
    }

    /// Insert a remote thread entry (received from DynamoDB) into local SQLite.
    /// Uses the remote entryId and sets syncState to "synced".
    func insertRemoteEntry(_ remote: SyncThreadEntry) async throws {
        let now = ISO8601DateFormatter().string(from: Date())
        try await db.dbPool.write { db in
            let maxSeq = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sequence_number), 0) FROM thread_entries WHERE thread_root_id = ?",
                arguments: [remote.threadRootId]
            ) ?? 0
            let entry = ThreadEntry(
                id: remote.entryId,
                threadRootId: remote.threadRootId,
                sequenceNumber: maxSeq + 1,
                kind: remote.type.rawValue,
                authoredBy: "remote",
                contentJson: remote.content,
                createdAt: now,
                syncState: "synced"
            )
            try entry.insert(db)
        }
    }

    /// Overwrite the content and createdAt of an existing entry (remote version won conflict).
    func updateEntryContent(entryId: String, content: String, timestamp: Int64) async throws {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let iso = ISO8601DateFormatter().string(from: date)
        try await db.dbPool.write { db in
            try db.execute(
                sql: "UPDATE thread_entries SET content_json = ?, created_at = ?, sync_state = 'synced' WHERE id = ?",
                arguments: [content, iso, entryId]
            )
        }
    }
}
