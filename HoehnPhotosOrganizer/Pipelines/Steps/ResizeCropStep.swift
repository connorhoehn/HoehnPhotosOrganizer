import CoreImage

/// Resizes input image to fit within target dimensions using CILanczosScaleTransform.
/// Preserves aspect ratio (fits, does not fill/crop).
///
/// Params (both required):
///   - width: Target width in pixels
///   - height: Target height in pixels
struct ResizeCropStep: PipelineStepProtocol {
    let stepType: PipelineStepType = .resizeCrop

    nonisolated init() {}

    nonisolated func execute(input: CIImage, params: [String: String], context: CIContext) throws -> CIImage {
        guard let wStr = params["width"], let hStr = params["height"],
              let targetW = Double(wStr), let targetH = Double(hStr),
              targetW > 0, targetH > 0 else {
            throw PipelineStepError.missingRequiredParam("width or height")
        }
        let inputW = Double(input.extent.width)
        let inputH = Double(input.extent.height)
        // Fit within target dimensions, preserving aspect ratio
        let scaleX = targetW / inputW
        let scaleY = targetH / inputH
        let scale = min(scaleX, scaleY)
        return input.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale,
            kCIInputAspectRatioKey: 1.0
        ])
    }
}
