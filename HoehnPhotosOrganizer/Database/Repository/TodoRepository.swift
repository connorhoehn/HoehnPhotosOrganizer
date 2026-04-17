import Foundation
import GRDB

actor TodoRepository {
    private let db: AppDatabase

    init(db: AppDatabase) { self.db = db }

    func fetchTodos(forPhoto photoId: String) async throws -> [TodoItem] {
        try await db.dbPool.read { db in
            try TodoItem
                .filter(TodoItem.Columns.photoAssetId == photoId)
                .order(TodoItem.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    func insert(_ todo: TodoItem) async throws {
        try await db.dbPool.write { db in try todo.insert(db) }
    }

    func toggleCompletion(id: String) async throws {
        try await db.dbPool.write { db in
            guard var todo = try TodoItem.fetchOne(db, key: id) else { return }
            todo.isCompleted.toggle()
            todo.completedAt = todo.isCompleted ? Date() : nil
            try todo.update(db)
        }
    }

    func delete(id: String) async throws {
        try await db.dbPool.write { db in
            try TodoItem.deleteOne(db, key: id)
        }
    }

    func updateBody(id: String, body: String) async throws {
        try await db.dbPool.write { db in
            guard var todo = try TodoItem.fetchOne(db, key: id) else { return }
            todo.body = body
            try todo.update(db)
        }
    }

    func todosPublisher(forPhoto photoId: String) -> ValueObservation<ValueReducers.Fetch<[TodoItem]>> {
        ValueObservation.tracking { db in
            try TodoItem
                .filter(TodoItem.Columns.photoAssetId == photoId)
                .order(TodoItem.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    /// AsyncSequence stream version — for use in @Observable ViewModels without actor hop.
    func todosStream(forPhoto photoId: String) -> AsyncValueObservation<[TodoItem]> {
        ValueObservation.tracking { db in
            try TodoItem
                .filter(TodoItem.Columns.photoAssetId == photoId)
                .order(TodoItem.Columns.sortOrder.asc)
                .fetchAll(db)
        }
        .values(in: db.dbPool)
    }
}
