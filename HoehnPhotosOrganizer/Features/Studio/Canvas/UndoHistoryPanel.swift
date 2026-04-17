import SwiftUI

struct UndoHistoryPanel: View {
    @ObservedObject var commandStack: CommandStack
    @ObservedObject var viewModel: StudioViewModel
    @State private var showClearConfirmation = false
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("History")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button("Clear") {
                    showClearConfirmation = true
                }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(commandStack.commands.isEmpty)
                .confirmationDialog(
                    "Clear all history?",
                    isPresented: $showClearConfirmation
                ) {
                    Button("Clear History", role: .destructive) {
                        commandStack.clear()
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            Divider()

            if commandStack.commands.isEmpty {
                Text("No changes yet")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(commandStack.history, id: \.index) { entry in
                            UndoHistoryRow(
                                entry: entry,
                                isFuture: entry.index > commandStack.currentIndex,
                                isHovered: hoveredIndex == entry.index
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Commit: cancel any hover preview and jump for real
                                viewModel.restoreFromUndoPreview()
                                hoveredIndex = nil
                                commandStack.jumpTo(index: entry.index)
                                viewModel.schedulePreview()
                            }
                            .onHover { isHovering in
                                if isHovering {
                                    // Don't preview the already-current state
                                    guard entry.index != commandStack.currentIndex || viewModel.isPreviewingUndo else {
                                        hoveredIndex = entry.index
                                        return
                                    }
                                    hoveredIndex = entry.index
                                    viewModel.previewUndoState(at: entry.index)
                                } else if hoveredIndex == entry.index {
                                    hoveredIndex = nil
                                    viewModel.restoreFromUndoPreview()
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(idealWidth: 200, maxHeight: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Row

private struct UndoHistoryRow: View {
    let entry: (index: Int, name: String, isCurrent: Bool)
    let isFuture: Bool
    var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Text("\(entry.index + 1)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 20, alignment: .trailing)
            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(1)
            Spacer()
            if isHovered && !entry.isCurrent {
                Image(systemName: "eye.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            entry.isCurrent ? Color.accentColor.opacity(0.15) :
            isHovered ? Color.accentColor.opacity(0.08) :
            Color.clear
        )
        .opacity(isFuture ? 0.5 : 1.0)
    }
}
