import CoreImage
import Foundation

// MARK: - PipelineStepProtocol

/// All processing step types conform to this protocol.
/// Steps are pure functions: given a CIImage input and string params, they return a transformed CIImage.
/// Conformers must be Sendable (structs with no mutable state).
protocol PipelineStepProtocol: Sendable {
    var stepType: PipelineStepType { get }
    nonisolated func execute(input: CIImage, params: [String: String], context: CIContext) throws -> CIImage
}

// MARK: - PipelineStepError

enum PipelineStepError: Error, LocalizedError {
    case noContoursDetected
    case failedToRenderContourContext
    case missingRequiredParam(String)

    var errorDescription: String? {
        switch self {
        case .noContoursDetected:
            return "No contours detected in image"
        case .failedToRenderContourContext:
            return "Failed to render contour to CGContext"
        case .missingRequiredParam(let key):
            return "Missing required parameter: \(key)"
        }
    }
}

// MARK: - ValidationError

enum ValidationError: Error, LocalizedError {
    case unreadableImage
    case insufficientDPI(found: Double, required: Double)
    case unexpectedAlphaChannel
    case unsupportedColorSpace(String)

    var errorDescription: String? {
        switch self {
        case .unreadableImage:
            return "Image could not be read"
        case .insufficientDPI(let found, let required):
            return "DPI \(Int(found)) is below required \(Int(required))"
        case .unexpectedAlphaChannel:
            return "Image has an alpha channel"
        case .unsupportedColorSpace(let cs):
            return "Unsupported color space: \(cs)"
        }
    }
}
