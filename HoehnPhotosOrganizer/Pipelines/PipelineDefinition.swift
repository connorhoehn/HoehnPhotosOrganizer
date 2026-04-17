import Foundation
import GRDB

enum PipelinePurpose: String, Codable, CaseIterable, Sendable {
    case printPrep = "print_prep"
    case tracingPrep = "tracing_prep"
    case engravingPrep = "engraving_prep"
    case scanCleanup = "scan_cleanup"
    case socialExport = "social_export"
}

struct PipelineDefinition: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "pipeline_definitions"

    var id: String
    var name: String
    var purpose: String   // PipelinePurpose.rawValue
    var createdAt: String
    var updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, name, purpose
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static func new(name: String, purpose: PipelinePurpose) -> PipelineDefinition {
        let now = ISO8601DateFormatter().string(from: .now)
        return PipelineDefinition(
            id: UUID().uuidString,
            name: name,
            purpose: purpose.rawValue,
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - PipelinePurpose Extensions

extension PipelinePurpose {
    var displayLabel: String {
        switch self {
        case .printPrep:       return "Print Prep"
        case .tracingPrep:     return "Tracing Prep"
        case .engravingPrep:   return "Engraving Prep"
        case .scanCleanup:     return "Scan Cleanup"
        case .socialExport:    return "Social Export"
        }
    }
}
