import Foundation
import Combine

// MARK: - WorkflowPreset

struct WorkflowPreset: Codable, Identifiable {
    var id: String
    var name: String
    var workflowType: String      // MetadataWorkflowKind.rawValue
    var inputText: String
    var metadata: UserMetadata
    var createdAt: Date
}

// MARK: - WorkflowPresetStore

/// Persists workflow presets to Application Support as a flat JSON file.
@MainActor
final class WorkflowPresetStore: ObservableObject {
    @Published private(set) var presets: [WorkflowPreset] = []

    private let fileURL: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("HoehnPhotosOrganizer")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("workflow_presets.json")
    }()

    init() { load() }

    func save(_ preset: WorkflowPreset) {
        presets.removeAll { $0.id == preset.id }
        presets.insert(preset, at: 0)
        persist()
    }

    func delete(id: String) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func presets(for kind: MetadataWorkflowKind) -> [WorkflowPreset] {
        presets.filter { $0.workflowType == kind.rawValue }
    }

    // MARK: - Persistence

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        presets = (try? decoder.decode([WorkflowPreset].self, from: data)) ?? []
    }

    private func persist() {
        guard let data = try? encoder.encode(presets) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
