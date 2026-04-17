import AppKit

// MARK: - StudioPipeline Protocol

/// Each art medium defines its own pipeline with medium-specific parameters
/// and a render function that chains CVImageProcessor calls.
protocol StudioPipeline {
    associatedtype Params: Equatable
    static var mediumName: String { get }
    static var mediumIcon: String { get }  // SF Symbol
    static var defaultParams: Params { get }
    static func render(source: NSImage, params: Params, progress: @escaping (Double) -> Void) async throws -> NSImage
}

// MARK: - PipelineError

enum PipelineError: Error, LocalizedError {
    case renderStepFailed(step: String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .renderStepFailed(let step):
            return "Pipeline failed at step: \(step)"
        case .cancelled:
            return "Render was cancelled."
        }
    }
}
