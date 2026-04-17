import Foundation
import Combine

// MARK: - StudioCommand Protocol

/// A reversible command for the canvas undo/redo system.
protocol StudioCommand {
    /// Human-readable name for the history list (e.g., "Change Threshold", "Apply Preset")
    var name: String { get }

    /// Execute the command (apply the change).
    func execute()

    /// Reverse the command (restore previous state).
    func undo()
}

// MARK: - ClosureCommand

/// Generic command that captures closures for execute and undo.
class ClosureCommand: StudioCommand {
    let name: String
    private let doAction: () -> Void
    private let undoAction: () -> Void

    init(name: String, execute: @escaping () -> Void, undo: @escaping () -> Void) {
        self.name = name
        self.doAction = execute
        self.undoAction = undo
    }

    func execute() { doAction() }
    func undo() { undoAction() }
}

// MARK: - PropertyChangeCommand

/// Command that captures old and new values for a property change,
/// applying them through a setter closure.
class PropertyChangeCommand<T>: StudioCommand {
    let name: String
    private let setter: (T) -> Void
    private let oldValue: T
    private let newValue: T

    init(name: String, oldValue: T, newValue: T, setter: @escaping (T) -> Void) {
        self.name = name
        self.oldValue = oldValue
        self.newValue = newValue
        self.setter = setter
    }

    func execute() { setter(newValue) }
    func undo() { setter(oldValue) }
}

// MARK: - CommandStack

/// Manages undo/redo history for a canvas session.
/// Thread-safe via @MainActor — all mutations happen on the main thread.
@MainActor
class CommandStack: ObservableObject {
    @Published private(set) var commands: [StudioCommand] = []
    @Published private(set) var currentIndex: Int = -1  // -1 = no commands executed

    var canUndo: Bool { currentIndex >= 0 }
    var canRedo: Bool { currentIndex < commands.count - 1 }
    var undoName: String? { canUndo ? commands[currentIndex].name : nil }
    var redoName: String? { canRedo ? commands[currentIndex + 1].name : nil }

    /// History list for display (most recent first).
    /// Each entry carries its index, name, and whether it's the current position.
    var history: [(index: Int, name: String, isCurrent: Bool)] {
        guard !commands.isEmpty else { return [] }
        return commands.enumerated().reversed().map { offset, command in
            (index: offset, name: command.name, isCurrent: offset == currentIndex)
        }
    }

    /// Execute a new command, truncating any redo history beyond the current position.
    func execute(_ command: StudioCommand) {
        // Discard everything after the current position (redo stack is gone)
        let keepCount = currentIndex + 1
        if commands.count > keepCount {
            commands.removeSubrange(keepCount..<commands.count)
        }

        commands.append(command)
        currentIndex = commands.count - 1
        command.execute()
    }

    /// Undo the most recent command.
    func undo() {
        guard canUndo else { return }
        commands[currentIndex].undo()
        currentIndex -= 1
    }

    /// Redo the next command.
    func redo() {
        guard canRedo else { return }
        currentIndex += 1
        commands[currentIndex].execute()
    }

    /// Jump to a specific point in history.
    /// If the target is before the current position, undo commands forward-to-back.
    /// If after, redo commands back-to-forward.
    func jumpTo(index targetIndex: Int) {
        guard targetIndex >= -1, targetIndex < commands.count else { return }
        guard targetIndex != currentIndex else { return }

        if targetIndex < currentIndex {
            // Undo from current down to target+1
            while currentIndex > targetIndex {
                commands[currentIndex].undo()
                currentIndex -= 1
            }
        } else {
            // Redo from current+1 up to target
            while currentIndex < targetIndex {
                currentIndex += 1
                commands[currentIndex].execute()
            }
        }
    }

    /// Clear all history.
    func clear() {
        commands.removeAll()
        currentIndex = -1
    }
}
