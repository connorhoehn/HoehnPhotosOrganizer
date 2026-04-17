import SwiftUI

struct PipelineRunProgressView: View {
    let stream: AsyncStream<PipelineRunProgress>
    let runID: String
    @Environment(\.dismiss) private var dismiss

    @State private var stepResults: [PipelineRunProgress] = []
    @State private var isDone = false
    @State private var hasFailed = false

    var body: some View {
        NavigationStack {
            List(stepResults.indices, id: \.self) { i in
                let result = stepResults[i]
                HStack {
                    Image(systemName: statusIcon(result.status))
                        .foregroundStyle(statusColor(result.status))
                    Text(result.stepType.displayLabel)
                    Spacer()
                    if let detail = result.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(isDone ? (hasFailed ? "Pipeline Failed" : "Pipeline Complete") : "Running Pipeline…")
            .toolbar {
                if isDone {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Close") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        ProgressView()
                    }
                }
            }
            .task {
                for await event in stream {
                    stepResults.append(event)
                    if event.status == .failed { hasFailed = true }
                }
                isDone = true
            }
        }
    }

    private func statusIcon(_ status: PipelineRunStepStatus) -> String {
        switch status {
        case .running: return "gear"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle"
        }
    }

    private func statusColor(_ status: PipelineRunStepStatus) -> Color {
        switch status {
        case .running: return .blue
        case .succeeded: return .green
        case .failed: return .red
        case .skipped: return .secondary
        }
    }
}

// MARK: - Preview

#Preview {
    PipelineRunProgressView(
        stream: AsyncStream { continuation in
            continuation.finish()
        },
        runID: "test-run-id"
    )
}
