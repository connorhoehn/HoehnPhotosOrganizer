import SwiftUI

// MARK: - DriveWorkflowSheet

/// Modal sheet for selecting and running analysis workflows on drive photos.
/// Attaches to a `MountedDriveState` which owns the `DriveWorkflowRunner` actor.
struct DriveWorkflowSheet: View {

    @ObservedObject var drive: MountedDriveState
    /// Photos currently selected in the grid; nil means no selection exists.
    var selectedPhotos: [DrivePhotoRecord] = []
    let onDismiss: () -> Void

    // Selection state
    @State private var selectedWorkflows: Set<DriveWorkflow> = [.orientation, .faces]
    @State private var scope: WorkflowScope = .unanalyzed  // overridden in onAppear

    enum WorkflowScope: String, CaseIterable, Identifiable {
        case selected   = "Selected"
        case all        = "All photos"
        case unanalyzed = "Unanalyzed only"
        var id: String { rawValue }
    }

    private var targetPhotos: [DrivePhotoRecord] {
        switch scope {
        case .selected:
            return selectedPhotos
        case .all:
            return drive.photos
        case .unanalyzed:
            return drive.photos.filter { !$0.hasWorkflowResults }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    workflowPicker
                    scopePicker
                    if drive.isRunningWorkflows {
                        progressSection
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 380, height: drive.isRunningWorkflows ? 480 : 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            scope = selectedPhotos.isEmpty ? .unanalyzed : .selected
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Analysis Workflows")
                    .font(.headline)
                Text("Run AI analysis on photos before importing to library")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(drive.isRunningWorkflows)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Workflow picker

    private var workflowPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKFLOWS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            ForEach(DriveWorkflow.allCases, id: \.self) { workflow in
                workflowRow(workflow)
            }
        }
    }

    private func workflowRow(_ workflow: DriveWorkflow) -> some View {
        Button {
            if selectedWorkflows.contains(workflow) {
                selectedWorkflows.remove(workflow)
            } else {
                selectedWorkflows.insert(workflow)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selectedWorkflows.contains(workflow)
                    ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(selectedWorkflows.contains(workflow)
                        ? Color.accentColor : .secondary)

                Image(systemName: workflow.systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(workflow.displayLabel)
                        .font(.system(size: 13, weight: .medium))
                    Text(workflow.shortDescription)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selectedWorkflows.contains(workflow)
                        ? Color.accentColor.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .disabled(drive.isRunningWorkflows)
    }

    // MARK: - Scope picker

    private var scopePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("APPLY TO")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            Picker("Scope", selection: $scope) {
                if !selectedPhotos.isEmpty {
                    Text(WorkflowScope.selected.rawValue).tag(WorkflowScope.selected)
                }
                Text(WorkflowScope.all.rawValue).tag(WorkflowScope.all)
                Text(WorkflowScope.unanalyzed.rawValue).tag(WorkflowScope.unanalyzed)
            }
            .pickerStyle(.segmented)
            .disabled(drive.isRunningWorkflows)

            HStack(spacing: 4) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("\(targetPhotos.count) photos will be analyzed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Progress

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("RUNNING")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("\(drive.workflowProcessed) / \(drive.workflowTotal) photos")
                        .font(.caption.monospacedDigit())
                    Spacer()
                    Text("\(Int(drive.workflowProgress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: max(0.02, drive.workflowProgress))
                    .tint(Color.accentColor)
                if !drive.workflowCurrentFile.isEmpty {
                    Text(drive.workflowCurrentFile)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if drive.isRunningWorkflows {
                Button("Stop") { drive.stopWorkflows() }
                    .buttonStyle(.bordered)
                    .tint(.red)
                Spacer()
                Text("Running…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Cancel") { onDismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Run on \(targetPhotos.count) Photos") {
                    guard !selectedWorkflows.isEmpty else { return }
                    drive.startWorkflows(photos: targetPhotos, workflows: selectedWorkflows)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedWorkflows.isEmpty || targetPhotos.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
