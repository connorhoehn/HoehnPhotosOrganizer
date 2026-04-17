import CoreImage
import CoreGraphics
import Foundation

/// Pipeline step that runs dust/hair detection + inpainting on the current CIImage.
///
/// This integrates the DustDetectionService and InpaintingService into the existing
/// PipelineStepProtocol system, allowing dust removal to be composed with other
/// pipeline steps (grayscale, resize, etc.) in user-defined pipelines.
///
/// Params:
///   - "confidence": Float string, detection threshold (default "0.25")
///   - "dilation": Int string, mask dilation radius in pixels (default "8")
///   - "strategy": "lama", "mat", or "auto" (default "auto")
struct DustRemovalStep: PipelineStepProtocol {
    let stepType: PipelineStepType = .dustRemoval

    nonisolated init() {}

    nonisolated func execute(
        input: CIImage,
        params: [String: String],
        context: CIContext
    ) throws -> CIImage {
        // Parse params
        let confidence = Float(params["confidence"] ?? "") ?? 0.25
        let dilation = Int(params["dilation"] ?? "") ?? 8
        let strategyStr = params["strategy"] ?? "auto"
        let strategy = InpaintingStrategy(rawValue: strategyStr) ?? .auto

        // Render CIImage to CGImage for the detection + inpainting pipeline
        guard let cgImage = context.createCGImage(input, from: input.extent) else {
            throw PipelineStepError.missingRequiredParam("Failed to render input CIImage to CGImage")
        }

        // Run detection + inpainting synchronously via a blocking semaphore.
        // PipelineStepProtocol.execute is nonisolated and synchronous, but our
        // AI services are actors with async APIs. We bridge with a semaphore
        // since pipeline steps run on a detached Task (never on MainActor).
        let semaphore = DispatchSemaphore(value: 0)
        var resultImage: CGImage?
        var stepError: Error?

        Task.detached(priority: .userInitiated) {
            do {
                let detector = DustDetectionService()
                let inpainter = InpaintingService()

                let detectionResult = try await detector.detectAndGenerateMask(
                    in: cgImage,
                    confidenceThreshold: confidence,
                    dilationRadius: dilation
                )

                guard let (detections, mask) = detectionResult else {
                    // No artifacts — return original
                    resultImage = cgImage
                    semaphore.signal()
                    return
                }

                let inpaintResult = try await inpainter.inpaint(
                    image: cgImage,
                    mask: mask,
                    strategy: strategy,
                    detections: detections
                )

                resultImage = inpaintResult.image
            } catch {
                stepError = error
            }
            semaphore.signal()
        }

        semaphore.wait()

        if let error = stepError {
            throw error
        }

        guard let output = resultImage else {
            throw PipelineStepError.missingRequiredParam("Dust removal produced no output")
        }

        return CIImage(cgImage: output)
    }
}
