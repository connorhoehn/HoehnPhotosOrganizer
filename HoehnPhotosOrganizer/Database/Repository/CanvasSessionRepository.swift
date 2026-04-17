import Foundation
import GRDB

actor CanvasSessionRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    /// Persist a new canvas session.
    func insertSession(_ session: CanvasSession) async throws {
        try await db.dbPool.write { db in
            var s = session
            try s.insert(db)
        }
    }

    /// Update an existing canvas session (e.g., after saving pipeline state).
    func updateSession(_ session: CanvasSession) async throws {
        try await db.dbPool.write { db in
            var s = session
            try s.update(db)
        }
    }

    /// Delete a canvas session by ID.
    @discardableResult
    func deleteSession(id: String) async throws -> CanvasSession? {
        try await db.dbPool.write { db in
            let session = try CanvasSession.fetchOne(db, key: id)
            _ = try CanvasSession.deleteOne(db, key: id)
            return session
        }
    }

    /// Fetch all canvas sessions, newest-modified first.
    func allSessions() async throws -> [CanvasSession] {
        try await db.dbPool.read { db in
            try CanvasSession
                .order(CanvasSession.Columns.modifiedAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single canvas session by ID.
    func session(id: String) async throws -> CanvasSession? {
        try await db.dbPool.read { db in
            try CanvasSession.fetchOne(db, key: id)
        }
    }

    /// Fetch all canvas sessions linked to a specific photo, newest-modified first.
    func sessionsForPhoto(id photoId: String) async throws -> [CanvasSession] {
        try await db.dbPool.read { db in
            try CanvasSession
                .filter(CanvasSession.Columns.sourcePhotoId == photoId)
                .order(CanvasSession.Columns.modifiedAt.desc)
                .fetchAll(db)
        }
    }

    /// Check if a photo is referenced by any canvas session (useful for delete warnings).
    func isPhotoUsedInCanvas(photoId: String) async throws -> Bool {
        try await db.dbPool.read { db in
            try CanvasSession
                .filter(CanvasSession.Columns.sourcePhotoId == photoId)
                .fetchCount(db) > 0
        }
    }
}
