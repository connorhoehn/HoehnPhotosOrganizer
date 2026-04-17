import Foundation
import GRDB

actor StudioCanvasRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    /// Fetch all canvases, most recently updated first.
    func allCanvases() async throws -> [StudioCanvas] {
        try await db.dbPool.read { db in
            try StudioCanvas
                .order(StudioCanvas.Columns.updatedAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetch a single canvas by ID.
    func canvas(id: String) async throws -> StudioCanvas? {
        try await db.dbPool.read { db in
            try StudioCanvas.fetchOne(db, key: id)
        }
    }

    /// Find existing canvas for a photo.
    func canvasForPhoto(id photoId: String) async throws -> StudioCanvas? {
        try await db.dbPool.read { db in
            try StudioCanvas
                .filter(StudioCanvas.Columns.photoId == photoId)
                .fetchOne(db)
        }
    }

    /// Insert a new canvas.
    func insert(_ canvas: StudioCanvas) async throws {
        try await db.dbPool.write { db in
            var c = canvas
            try c.insert(db)
        }
    }

    /// Update an existing canvas.
    func update(_ canvas: StudioCanvas) async throws {
        try await db.dbPool.write { db in
            var c = canvas
            try c.update(db)
        }
    }

    /// Delete a canvas and its revisions (cascade).
    @discardableResult
    func delete(id: String) async throws -> StudioCanvas? {
        try await db.dbPool.write { db in
            let canvas = try StudioCanvas.fetchOne(db, key: id)
            _ = try StudioCanvas.deleteOne(db, key: id)
            return canvas
        }
    }

    /// Fetch all revisions belonging to a canvas, newest first.
    func revisionsForCanvas(id canvasId: String) async throws -> [StudioRevision] {
        try await db.dbPool.read { db in
            try StudioRevision
                .filter(Column("canvas_id") == canvasId)
                .order(StudioRevision.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Count revisions for a canvas.
    func revisionCount(forCanvas canvasId: String) async throws -> Int {
        try await db.dbPool.read { db in
            try StudioRevision
                .filter(Column("canvas_id") == canvasId)
                .fetchCount(db)
        }
    }
}
