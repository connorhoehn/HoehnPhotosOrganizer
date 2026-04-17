import Foundation
import Combine
import SwiftUI

@MainActor
final class PipelineEditorViewModel: ObservableObject {
    @Published var name: String = ""
    @Published var purpose: PipelinePurpose = .printPrep
    @Published var steps: [EditableStep] = []
    @Published var isSaving = false
    @Published var errorMessage: String?

    struct EditableStep: Identifiable {
        var id = UUID()
        var stepType: PipelineStepType
        var params: [String: String]

        var displayName: String {
            switch stepType {
            case .grayscale:            return "Grayscale"
            case .edgeDetection:        return "Edge Detection"
            case .lineArt:              return "Line Art"
            case .contourMap:           return "Contour Map"
            case .resizeCrop:           return "Resize / Crop"
            case .validationPreflight:  return "Validation Preflight"
            case .dustRemoval:          return "Dust Removal"
            }
        }

        var paramSummary: String {
            guard !params.isEmpty else { return "" }
            return params.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        }
    }

    private let repo: PipelineRepository
    var editingDefinition: PipelineDefinition?

    init(db: AppDatabase, editing: (PipelineDefinition, [PipelineStep])? = nil) {
        self.repo = PipelineRepository(db: db)
        if let (def, loadedSteps) = editing {
            self.editingDefinition = def
            self.name = def.name
            self.purpose = PipelinePurpose(rawValue: def.purpose) ?? .printPrep
            self.steps = loadedSteps.map {
                let params = $0.paramsJson
                    .flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
                return EditableStep(
                    stepType: PipelineStepType(rawValue: $0.stepType) ?? .grayscale,
                    params: params
                )
            }
        }
    }

    func addStep(_ type: PipelineStepType) {
        steps.append(EditableStep(stepType: type, params: [:]))
    }

    func moveSteps(from: IndexSet, to: Int) {
        steps.move(fromOffsets: from, toOffset: to)
    }

    func removeSteps(at offsets: IndexSet) {
        steps.remove(atOffsets: offsets)
    }

    /// Saves (create or update) the pipeline. Returns true on success so callers can dismiss.
    @discardableResult
    func save() async -> Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            errorMessage = "Pipeline name cannot be empty"
            return false
        }
        isSaving = true
        defer { isSaving = false }
        let stepTuples = steps.map { (type: $0.stepType, params: $0.params.isEmpty ? nil : $0.params) }
        do {
            if var def = editingDefinition {
                def.name = name
                def.purpose = purpose.rawValue
                try await repo.updatePipeline(def, steps: stepTuples)
            } else {
                _ = try await repo.createPipeline(name: name, purpose: purpose, steps: stepTuples)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
