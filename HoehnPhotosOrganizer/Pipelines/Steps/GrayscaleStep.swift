import CoreImage

/// Converts input image to grayscale using CIPhotoEffectMono.
/// Uses perceptually correct BT.601 luma weighting.
/// Output extent matches input extent.
struct GrayscaleStep: PipelineStepProtocol {
    let stepType: PipelineStepType = .grayscale

    nonisolated init() {}

    nonisolated func execute(input: CIImage, params: [String: String], context: CIContext) throws -> CIImage {
        input.applyingFilter("CIPhotoEffectMono")
    }
}
