import SwiftUI

// MARK: - TodoListView

struct TodoListView: View {
    @State private var viewModel: TodoListViewModel

    init(photoAssetId: String, db: AppDatabase) {
        _viewModel = State(initialValue: TodoListViewModel(photoAssetId: photoAssetId, db: db))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("To Do", systemImage: "checklist")
                .font(.headline)
                .foregroundStyle(.primary)

            ForEach(viewModel.todos) { todo in
                HStack {
                    Button {
                        viewModel.toggleCompletion(id: todo.id)
                    } label: {
                        Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(todo.isCompleted ? .green : .secondary)
                    }
                    .buttonStyle(.plain)

                    Text(todo.body)
                        .strikethrough(todo.isCompleted)
                        .foregroundStyle(todo.isCompleted ? .secondary : .primary)
                        .font(.system(size: 13))

                    Spacer()

                    Button {
                        viewModel.deleteTodo(id: todo.id)
                    } label: {
                        Image(systemName: "xmark").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            // Inline add field
            HStack {
                TextField("Add a task...", text: $viewModel.newTodoText)
                    .font(.system(size: 13))
                    .onSubmit { viewModel.addTodo() }
                    .textFieldStyle(.plain)
                Button(action: { viewModel.addTodo() }) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(viewModel.newTodoText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { viewModel.startObserving() }
        .onDisappear { viewModel.stopObserving() }
    }
}
