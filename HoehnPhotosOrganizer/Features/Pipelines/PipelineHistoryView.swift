import SwiftUI
import GRDB

struct PipelineHistoryView: View {
    let sourcePhotoId: String
    let db: AppDatabase
    
    @State private var runs: [PipelineRun] = []
    @State private var pipelineNames: [String: String] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        Group {
            if runs.isEmpty {
                VStack(alignment: .center, spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                    Text("No pipeline runs yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding()
            } else {
                List {
                    ForEach(runs) { run in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(pipelineName(for: run))
                                    .font(.body)
                                Spacer()
                                statusBadge(for: run)
                            }
                            Text(formatDate(run.startedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .task {
            await loadRuns()
        }
        .alert("Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private func pipelineName(for run: PipelineRun) -> String {
        guard let id = run.pipelineId else { return "Ad-hoc" }
        return pipelineNames[id] ?? id
    }
    
    private func statusBadge(for run: PipelineRun) -> some View {
        let status = PipelineRunStatus(rawValue: run.status) ?? .running
        let label: String
        let color: Color
        
        switch status {
        case .running:
            label = "Running"
            color = .blue
        case .succeeded:
            label = "Succeeded"
            color = .green
        case .failed:
            label = "Failed"
            color = .red
        case .cancelled:
            label = "Cancelled"
            color = .gray
        }
        
        return Text(label)
            .font(.caption)
            .foregroundStyle(color)
    }
    
    private func formatDate(_ isoString: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: isoString) else {
            return isoString
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    
    private func loadRuns() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let repo = PipelineRepository(db: db)
            runs = try await repo.fetchRunsForPhoto(photoId: sourcePhotoId)
            // Build name lookup from all definitions referenced by these runs
            let allDefinitions = try await repo.fetchAllPipelines()
            var nameMap: [String: String] = [:]
            for def in allDefinitions {
                nameMap[def.id] = def.name
            }
            pipelineNames = nameMap
        } catch {
            errorMessage = "Failed to load pipeline runs: \(error.localizedDescription)"
        }
    }
}

// MARK: - Preview

#Preview {
    // swiftlint:disable:next force_try
    PipelineHistoryView(
        sourcePhotoId: "test-photo-id",
        db: try! AppDatabase.makeInMemory()
    )
}
