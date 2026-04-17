import Foundation
import Observation
import GRDB

// MARK: - TodoListViewModel

@MainActor
@Observable
final class TodoListViewModel {

    // MARK: - State

    var todos: [TodoItem] = []
    var newTodoText: String = ""

    // MARK: - Dependencies

    let photoAssetId: String
    private let repo: TodoRepository
    private let db: AppDatabase

    // MARK: - Observation lifecycle

    private var observationTask: Task<Void, Never>?

    init(photoAssetId: String, db: AppDatabase) {
        self.photoAssetId = photoAssetId
        self.db = db
        self.repo = TodoRepository(db: db)
    }

    /// Start live-observing the todo list. Call once after view appears.
    func startObserving() {
        observationTask?.cancel()
        // Capture values needed in the task to avoid actor-isolation issues
        let photoId = photoAssetId
        let pool = db.dbPool
        observationTask = Task { [weak self] in
            guard let self else { return }
            // Build observation inline: avoids hopping into the TodoRepository actor
            // (todosPublisher is actor-isolated sync, so we duplicate the query here)
            let observation = ValueObservation.tracking { db in
                try TodoItem
                    .filter(TodoItem.Columns.photoAssetId == photoId)
                    .order(TodoItem.Columns.sortOrder.asc)
                    .fetchAll(db)
            }
            do {
                for try await items in observation.values(in: pool) {
                    guard !Task.isCancelled else { return }
                    self.todos = items
                }
            } catch {
                // Observation failed — leave current state intact
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Operations

    func addTodo() {
        let text = newTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        newTodoText = ""
        let nextOrder = (todos.map(\.sortOrder).max() ?? -1) + 1
        let item = TodoItem(
            id: UUID().uuidString,
            photoAssetId: photoAssetId,
            body: text,
            isCompleted: false,
            completedAt: nil,
            createdAt: Date(),
            sortOrder: nextOrder
        )
        Task {
            try? await repo.insert(item)
        }
    }

    func toggleCompletion(id: String) {
        Task {
            try? await repo.toggleCompletion(id: id)
        }
    }

    func deleteTodo(id: String) {
        Task {
            try? await repo.delete(id: id)
        }
    }
}
