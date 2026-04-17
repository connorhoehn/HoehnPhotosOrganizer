import CoreImage

/// Applies CIEdges filter for edge detection.
/// Params:
///   - intensity: Edge detection intensity, 0.0–10.0 (default 1.0)
///   - invertForTracing: If "true", applies CIColorInvert after edge detection
///     to produce black lines on white — required for tracing/engraving prep
///     (RESEARCH pitfall 2: CIEdges outputs white-on-black; print prep needs black-on-white)
struct EdgeDetectionStep: PipelineStepProtocol {
    let stepType: PipelineStepType = .edgeDetection

    nonisolated init() {}

    nonisolated func execute(input: CIImage, params: [String: String], context: CIContext) throws -> CIImage {
        let intensity = Double(params["intensity"] ?? "1.0") ?? 1.0
        var result = input.applyingFilter("CIEdges", parameters: ["inputIntensity": intensity])
        // For tracing/engraving: invert so lines are black on white (RESEARCH pitfall 2)
        if params["invertForTracing"] == "true" {
            result = result.applyingFilter("CIColorInvert")
        }
        return result
    }
}
