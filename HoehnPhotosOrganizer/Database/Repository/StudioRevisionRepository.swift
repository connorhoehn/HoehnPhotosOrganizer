import Foundation
import GRDB

actor StudioRevisionRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    /// Persist a new studio revision.
    func insertRevision(_ revision: StudioRevision) async throws {
        try await db.dbPool.write { db in
            var r = revision
            try r.insert(db)
        }
    }

    /// Fetch all revisions for a photo, newest first.
    func revisionsForPhoto(id photoId: String) async throws -> [StudioRevision] {
        try await db.dbPool.read { db in
            try StudioRevision
                .filter(StudioRevision.Columns.photoId == photoId)
                .order(StudioRevision.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Delete a single revision by ID.
    /// Returns the deleted revision (if found) so callers can clean up associated files.
    @discardableResult
    func deleteRevision(id: String) async throws -> StudioRevision? {
        try await db.dbPool.write { db in
            let revision = try StudioRevision.fetchOne(db, key: id)
            _ = try StudioRevision.deleteOne(db, key: id)
            return revision
        }
    }
}
