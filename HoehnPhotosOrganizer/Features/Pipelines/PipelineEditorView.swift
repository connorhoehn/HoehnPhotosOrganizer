import SwiftUI

struct PipelineEditorView: View {
    @StateObject private var vm: PipelineEditorViewModel
    @Environment(\.dismiss) private var dismiss

    init(db: AppDatabase, editing: (PipelineDefinition, [PipelineStep])? = nil) {
        _vm = StateObject(wrappedValue: PipelineEditorViewModel(db: db, editing: editing))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Pipeline Details") {
                    TextField("Pipeline name", text: $vm.name)
                    Picker("Purpose", selection: $vm.purpose) {
                        ForEach(PipelinePurpose.allCases, id: \.self) { p in
                            Text(p.displayLabel).tag(p)
                        }
                    }
                }

                Section("Steps") {
                    if vm.steps.isEmpty {
                        Text("No steps added yet. Use + to add a step.")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    } else {
                        ForEach($vm.steps) { $step in
                            PipelineStepRow(step: $step)
                        }
                        .onMove(perform: vm.moveSteps)
                        .onDelete(perform: vm.removeSteps)
                    }
                }
            }
            .navigationTitle(vm.editingDefinition == nil ? "New Pipeline" : "Edit Pipeline")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if vm.isSaving {
                        ProgressView()
                    } else {
                        Button("Save") {
                            Task {
                                let success = await vm.save()
                                if success { dismiss() }
                            }
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(PipelineStepType.allCases, id: \.self) { stepType in
                            Button(stepType.displayLabel) {
                                vm.addStep(stepType)
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Error", isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )) {
                Button("OK") { vm.errorMessage = nil }
            } message: {
                Text(vm.errorMessage ?? "")
            }
        }
    }
}

// MARK: - PipelineStepRow

private struct PipelineStepRow: View {
    @Binding var step: PipelineEditorViewModel.EditableStep

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(step.displayName)
                .font(.body)
            if !step.paramSummary.isEmpty {
                Text(step.paramSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

