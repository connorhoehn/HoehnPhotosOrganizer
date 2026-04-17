import Foundation
import GRDB

enum PipelineStepType: String, Codable, CaseIterable, Sendable {
    case resizeCrop = "resize_crop"
    case grayscale
    case edgeDetection = "edge_detection"
    case contourMap = "contour_map"
    case lineArt = "line_art"
    case validationPreflight = "validation_preflight"
    case dustRemoval = "dust_removal"
}

struct PipelineStep: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "pipeline_steps"

    var id: String
    var pipelineId: String
    var stepOrder: Int
    var stepType: String   // PipelineStepType.rawValue
    var paramsJson: String?

    enum CodingKeys: String, CodingKey {
        case id
        case pipelineId = "pipeline_id"
        case stepOrder = "step_order"
        case stepType = "step_type"
        case paramsJson = "params_json"
    }
}

// MARK: - PipelineStepType Extensions

extension PipelineStepType {
    var displayLabel: String {
        switch self {
        case .grayscale:            return "Grayscale"
        case .edgeDetection:        return "Edge Detection"
        case .lineArt:              return "Line Art"
        case .contourMap:           return "Contour Map"
        case .resizeCrop:           return "Resize / Crop"
        case .validationPreflight:  return "Validation Preflight"
        case .dustRemoval:          return "Dust Removal"
        }
    }
}
