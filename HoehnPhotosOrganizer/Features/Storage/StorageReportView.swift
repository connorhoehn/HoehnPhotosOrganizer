import SwiftUI

struct StorageReportView: View {
    @StateObject private var viewModel: StorageReportViewModel

    init(db: AppDatabase) {
        _viewModel = StateObject(wrappedValue: StorageReportViewModel(db: db))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.isLoading {
                    ProgressView("Loading storage report...")
                        .frame(maxWidth: .infinity)
                } else if let report = viewModel.report {
                    storageSummarySection(report)
                    driveBreakdownSection(report)
                    consolidationPlannerSection
                }
                if let error = viewModel.errorMessage {
                    Text("Error: \(error)").foregroundColor(.red).font(.caption)
                }
            }
            .padding()
        }
        .navigationTitle("Storage Report")
        .toolbar {
            Button("Refresh") {
                Task { await viewModel.loadReport() }
            }
        }
        .task { await viewModel.loadReport() }
        .sheet(isPresented: $viewModel.showPlanPreview) {
            if let plan = viewModel.consolidationPlan {
                consolidationPlanSheet(plan)
            }
        }
    }

    private func storageSummarySection(_ report: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library Summary")
                .font(.headline)
            HStack(spacing: 16) {
                storageCell("Originals", bytes: report.originalsBytes, color: .blue)
                storageCell("Proxies", bytes: report.proxiesBytes, color: .orange)
                storageCell("Derivatives", bytes: report.derivativesBytes, color: .purple)
            }
        }
    }

    private func storageCell(_ label: String, bytes: Int, color: Color) -> some View {
        VStack {
            Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                .font(.title3).fontWeight(.semibold)
                .foregroundColor(color)
            Text(label).font(.caption).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(color.opacity(0.08))
        .cornerRadius(8)
    }

    private func driveBreakdownSection(_ report: StorageReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By Drive")
                .font(.headline)
            ForEach(report.driveBreakdowns) { drive in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "externaldrive")
                        Text(drive.volumeLabel).fontWeight(.medium)
                        Spacer()
                        Text("\(ByteCountFormatter.string(fromByteCount: Int64(drive.freeBytes), countStyle: .file)) free")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text("Orig: \(ByteCountFormatter.string(fromByteCount: Int64(drive.originalBytes), countStyle: .file))")
                        Text("Proxy: \(ByteCountFormatter.string(fromByteCount: Int64(drive.proxyBytes), countStyle: .file))")
                        Text("Deriv: \(ByteCountFormatter.string(fromByteCount: Int64(drive.derivativeBytes), countStyle: .file))")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
                Divider()
            }
        }
    }

    private var consolidationPlannerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Consolidation Planner")
                .font(.headline)
            Text("Simulate moving originals between drives. No files are moved — this is a simulation only.")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack {
                TextField("Source drive label", text: $viewModel.sourceDriveLabel)
                    .textFieldStyle(.roundedBorder)
                Image(systemName: "arrow.right")
                TextField("Target drive label", text: $viewModel.targetDriveLabel)
                    .textFieldStyle(.roundedBorder)
                Button("Preview Plan") {
                    Task { await viewModel.generateConsolidationPlan() }
                }
                .disabled(viewModel.sourceDriveLabel.isEmpty || viewModel.targetDriveLabel.isEmpty)
            }
        }
    }

    private func consolidationPlanSheet(_ plan: ConsolidationPlan) -> some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(plan.moves.count) photos would move from '\(plan.sourceDriveLabel)' to '\(plan.targetDriveLabel)'")
                    .font(.headline)
                Text("Total: \(ByteCountFormatter.string(fromByteCount: Int64(plan.totalBytesToMove), countStyle: .file))")
                    .foregroundColor(.secondary)
                Text("Simulation generated at \(plan.generatedAt.formatted()). No files have been moved.")
                    .font(.caption).foregroundColor(.orange)
                List(plan.moves) { move in
                    HStack {
                        Text(move.canonicalName)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(move.fileSizeBytes), countStyle: .file))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                Spacer()
                // Phase 8: simulation only. Execute functionality deferred to Phase 9.
                Text("File execution planned for a future phase.")
                    .font(.caption2).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .center)
            }
            .padding()
            .navigationTitle("Consolidation Plan (Simulation)")
            .toolbar {
                Button("Close") { viewModel.showPlanPreview = false }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }
}
