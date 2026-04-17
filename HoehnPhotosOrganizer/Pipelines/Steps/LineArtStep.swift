import CoreImage

/// Applies CILineOverlay for a pencil-sketch / line-art rendering.
/// Outputs black lines on a white background — suitable for etching and tracing prep.
/// Params:
///   - nrNoiseLevel: Noise reduction noise level (default 0.07)
///   - nrSharpness: Noise reduction sharpness (default 0.71)
///   - edgeIntensity: Edge intensity multiplier (default 1.0)
///   - threshold: Edge threshold (default 0.1)
///   - contrast: Contrast boost (default 50.0)
struct LineArtStep: PipelineStepProtocol {
    let stepType: PipelineStepType = .lineArt

    nonisolated init() {}

    nonisolated func execute(input: CIImage, params: [String: String], context: CIContext) throws -> CIImage {
        let noiseLevel = Double(params["nrNoiseLevel"] ?? "0.07") ?? 0.07
        let sharpness = Double(params["nrSharpness"] ?? "0.71") ?? 0.71
        let edgeIntensity = Double(params["edgeIntensity"] ?? "1.0") ?? 1.0
        let threshold = Double(params["threshold"] ?? "0.1") ?? 0.1
        let contrast = Double(params["contrast"] ?? "50.0") ?? 50.0
        return input.applyingFilter("CILineOverlay", parameters: [
            "inputNRNoiseLevel": noiseLevel,
            "inputNRSharpness": sharpness,
            "inputEdgeIntensity": edgeIntensity,
            "inputThreshold": threshold,
            "inputContrast": contrast
        ])
    }
}
