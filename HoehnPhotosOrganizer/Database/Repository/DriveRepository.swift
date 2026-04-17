import Foundation
import GRDB

actor DriveRepository {
    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    // MARK: - Live stream

    /// Live stream of all drives ordered by volume_label.
    /// Returns an AsyncValueObservation which is an AsyncSequence that throws on error.
    func allDrivesStream() -> AsyncValueObservation<[DriveDB]> {
        ValueObservation
            .tracking { db in
                try DriveDB
                    .order(Column("volume_label"))
                    .fetchAll(db)
            }
            .values(in: db.dbPool)
    }

    // MARK: - Writes

    /// Insert or replace on volume_label conflict (upsert).
    /// Sets updated_at to now on every call.
    func upsert(_ drive: DriveDB) async throws {
        var updated = drive
        updated.updatedAt = ISO8601DateFormatter().string(from: .now)
        try await db.dbPool.write { db in
            // upsert() generates INSERT ... ON CONFLICT DO UPDATE SET which handles
            // conflicts on the volume_label UNIQUE constraint.
            try updated.upsert(db)
        }
    }

    func delete(id: String) async throws {
        try await db.dbPool.write { db in
            try DriveDB.deleteOne(db, id: id)
        }
    }

    // MARK: - Reads

    func fetchAll() async throws -> [DriveDB] {
        try await db.dbPool.read { db in
            try DriveDB
                .order(Column("volume_label"))
                .fetchAll(db)
        }
    }

    func fetchByVolumeLabel(_ label: String) async throws -> DriveDB? {
        try await db.dbPool.read { db in
            try DriveDB
                .filter(Column("volume_label") == label)
                .fetchOne(db)
        }
    }
}
