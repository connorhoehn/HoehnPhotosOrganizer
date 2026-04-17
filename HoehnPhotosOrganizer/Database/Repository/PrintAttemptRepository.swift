import Foundation
import GRDB

actor PrintAttemptRepository {
    private let db: any DatabaseWriter

    init(_ db: any DatabaseWriter) {
        self.db = db
    }

    /// Add a new print attempt as a ThreadEntry with kind="print_attempt"
    func addPrintAttempt(
        to photoId: String,
        attempt: PrintAttempt,
        activityEventId: String? = nil
    ) async throws -> ThreadEntry {
        return try await db.write { db in
            // Get next sequence number for this photo's thread
            let nextSeq = try PrintAttemptRepository.nextSequenceNumber(for: photoId, in: db)

            // Encode attempt as JSON for ThreadEntry contentJson
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let attemptJSON = try String(
                data: encoder.encode(attempt),
                encoding: .utf8
            ) ?? "{}"

            // Create ThreadEntry
            let entry = ThreadEntry(
                id: UUID().uuidString,
                threadRootId: photoId,
                sequenceNumber: nextSeq,
                kind: "print_attempt",
                authoredBy: "user",
                contentJson: attemptJSON,
                createdAt: ISO8601DateFormatter().string(from: Date()),
                syncState: "local_only",
                activityEventId: activityEventId
            )

            try entry.insert(db)
            return entry
        }
    }

    /// Fetch all print attempts for a photo, ordered chronologically
    func fetchTimelineForPhoto(_ photoId: String) async throws -> [ThreadEntry] {
        return try await db.read { db in
            try ThreadEntry
                .filter(Column("thread_root_id") == photoId)
                .filter(Column("kind") == "print_attempt")
                .order(Column("sequence_number").asc)
                .fetchAll(db)
        }
    }

    /// Fetch a single print attempt by its ThreadEntry ID
    func fetchAttempt(id: String) async throws -> PrintAttempt? {
        return try await db.read { db in
            guard let entry = try ThreadEntry
                .filter(Column("id") == id)
                .filter(Column("kind") == "print_attempt")
                .fetchOne(db) else {
                return nil
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(PrintAttempt.self, from: entry.contentJson.data(using: .utf8)!)
        }
    }

    /// Update outcome and notes of existing attempt (creates new ThreadEntry, original is archive)
    func updateAttempt(
        id: String,
        outcome: PrintOutcome,
        outcomeNotes: String
    ) async throws -> ThreadEntry? {
        // For now, create a new entry with updated fields
        // Full revision history can be added in Phase 6 if needed
        guard let originalAttempt = try await fetchAttempt(id: id) else {
            return nil
        }

        var updated = originalAttempt
        updated.outcome = outcome
        updated.outcomeNotes = outcomeNotes
        updated.updatedAt = Date()

        return try await addPrintAttempt(to: updated.photoId, attempt: updated)
    }

    // Static helper to compute next sequence number inside a transaction (avoids actor isolation issue)
    private static func nextSequenceNumber(for threadRootId: String, in db: Database) throws -> Int {
        let maxSeq = try Int.fetchOne(
            db,
            sql: "SELECT MAX(sequence_number) FROM thread_entries WHERE thread_root_id = ?",
            arguments: [threadRootId]
        ) ?? 0
        return maxSeq + 1
    }
}
