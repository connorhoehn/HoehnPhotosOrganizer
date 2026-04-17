import SwiftUI

// MARK: - LineageTimelineView

struct LineageTimelineView: View {
    @State private var viewModel: LineageTimelineViewModel

    init(viewModel: LineageTimelineViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
                .padding(.bottom, 8)

            ForEach(viewModel.nodes) { node in
                LineageNodeRow(
                    node: node,
                    isSelected: viewModel.selectedNodeId == node.id,
                    onSelect: { viewModel.selectedNodeId = node.id },
                    onRestore: {
                        if case .adjustmentSnapshot(let snap) = node.kind {
                            Task { await viewModel.onRollback(snap) }
                        }
                    }
                )

                if node.id != viewModel.nodes.last?.id {
                    // Connector line between nodes
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2, height: 20)
                        .padding(.leading, 15)
                }
            }

            if viewModel.nodes.isEmpty {
                Text("No history yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: viewModel.photoAssetId) {
            await viewModel.load()
            await viewModel.observeSnapshots()
        }
    }
}

// MARK: - LineageNodeRow

struct LineageNodeRow: View {
    let node: LineageNode
    let isSelected: Bool
    let onSelect: () -> Void
    let onRestore: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Timeline dot
            Circle()
                .fill(nodeColor)
                .frame(width: 10, height: 10)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(node.title)
                        .font(.system(size: 12, weight: isCurrentState ? .semibold : .regular))
                    if isCurrentState {
                        Label("Current", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                            .labelStyle(.titleAndIcon)
                    }
                    Spacer()
                    Text(node.occurredAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                if let detail = node.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Restore button for non-current adjustment snapshots
                if case .adjustmentSnapshot(let snap) = node.kind, !snap.isCurrentState {
                    Button("Restore this state") { onRestore() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .background(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(4)
    }

    private var isCurrentState: Bool {
        if case .adjustmentSnapshot(let s) = node.kind { return s.isCurrentState }
        return false
    }

    private var nodeColor: Color {
        switch node.kind {
        case .assetOrigin: return .orange
        case .adjustmentSnapshot(let s): return s.isCurrentState ? .blue : .secondary
        case .pipelineOutput: return .purple
        }
    }
}
