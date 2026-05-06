import Testing
import Foundation
import GRDB
@testable import HoehnPhotosOrganizer

struct TodoItemRepositoryTests {

    // MARK: - Helpers

    private func seedPhoto(id: String, in db: AppDatabase) async throws {
        var asset = PhotoAsset.new(
            canonicalName: "\(id).dng",
            role: .original,
            filePath: "/tmp/\(id).dng",
            fileSize: 1024
        )
        asset.id = id
        try await PhotoRepository(db: db).bulkUpsert([asset])
    }

    private func makeTodo(
        id: String = UUID().uuidString,
        photoId: String,
        body: String = "Check exposure",
        isCompleted: Bool = false,
        sortOrder: Int = 0
    ) -> TodoItem {
        TodoItem(
            id: id,
            photoAssetId: photoId,
            body: body,
            isCompleted: isCompleted,
            completedAt: nil,
            createdAt: Date(),
            sortOrder: sortOrder
        )
    }

    // MARK: - Tests

    @Test
    func testInsertTodoItemForPhoto() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "p-todo-1", in: db)

        let item = makeTodo(id: "todo-1", photoId: "p-todo-1", body: "Review contrast")
        try await db.dbPool.write { d in try item.insert(d) }

        let fetched = try await db.dbPool.read { d in
            try TodoItem.fetchOne(d, key: "todo-1")
        }
        let f = try #require(fetched)
        #expect(f.photoAssetId == "p-todo-1")
        #expect(f.body == "Review contrast")
        #expect(f.isCompleted == false)
    }

    @Test
    func testFetchTodosForPhotoReturnsAll() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "p-todo-2", in: db)

        for i in 0..<3 {
            let item = makeTodo(photoId: "p-todo-2", body: "Task \(i)", sortOrder: i)
            try await db.dbPool.write { d in try item.insert(d) }
        }

        let items = try await db.dbPool.read { d in
            try TodoItem
                .filter(TodoItem.Columns.photoAssetId == "p-todo-2")
                .order(TodoItem.Columns.sortOrder)
                .fetchAll(d)
        }
        #expect(items.count == 3)
        #expect(items.allSatisfy { $0.photoAssetId == "p-todo-2" })
    }

    @Test
    func testToggleTodoCompletionUpdatesDB() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "p-todo-3", in: db)

        var item = makeTodo(id: "todo-toggle", photoId: "p-todo-3", isCompleted: false)
        try await db.dbPool.write { d in try item.insert(d) }

        item.isCompleted = true
        item.completedAt = Date()
        try await db.dbPool.write { d in try item.update(d) }

        let fetched = try await db.dbPool.read { d in
            try TodoItem.fetchOne(d, key: "todo-toggle")
        }
        let f = try #require(fetched)
        #expect(f.isCompleted == true)
        #expect(f.completedAt != nil)
    }

    @Test
    func testDeleteTodoRemovesFromDB() async throws {
        let db = try AppDatabase.makeInMemory()
        try await seedPhoto(id: "p-todo-4", in: db)

        let item = makeTodo(id: "todo-del", photoId: "p-todo-4")
        try await db.dbPool.write { d in try item.insert(d) }

        try await db.dbPool.write { d in try item.delete(d) }

        let count = try await db.dbPool.read { d in
            try TodoItem
                .filter(TodoItem.Columns.photoAssetId == "p-todo-4")
                .fetchCount(d)
        }
        #expect(count == 0)
    }
}
