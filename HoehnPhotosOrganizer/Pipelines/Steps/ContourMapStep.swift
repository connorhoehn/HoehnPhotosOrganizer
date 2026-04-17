import CoreImage
import Vision
import CoreGraphics

/// Detects contours using Vision's VNDetectContoursRequest and renders
/// them as black strokes on a white CGContext, returning the result as CIImage.
///
/// Vision normalizedPath coordinate flip (RESEARCH pitfall 3):
/// Vision uses (0,0) at bottom-left; CGContext uses (0,0) at top-left.
/// Apply CGAffineTransform(scaleX: width, y: -height).translatedBy(x: 0, y: -1)
/// before rendering to avoid a vertically mirrored output.
///
/// Params:
///   - contrastAdjustment: Boost contrast for low-contrast images (default 2.0)
///   - detectDarkOnLight: Whether to detect dark contours on light background (default true)
struct ContourMapStep: PipelineStepProtocol {
    let stepType: PipelineStepType = .contourMap

    nonisolated init() {}

    nonisolated func execute(input: CIImage, params: [String: String], context: CIContext) throws -> CIImage {
        let contrastAdj = Float(params["contrastAdjustment"] ?? "2.0") ?? 2.0
        let darkOnLight = (params["detectDarkOnLight"] ?? "true") == "true"

        // Render CIImage to CGImage for Vision request
        guard let cgImage = context.createCGImage(input, from: input.extent) else {
            throw PipelineStepError.failedToRenderContourContext
        }

        let request = VNDetectContoursRequest()
        request.contrastAdjustment = contrastAdj
        request.detectDarkOnLight = darkOnLight

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observation = request.results?.first as? VNContoursObservation else {
            throw PipelineStepError.noContoursDetected
        }

        let width = cgImage.width
        let height = cgImage.height

        // Vision normalized path: y-flip transform (RESEARCH pitfall 3)
        // Vision (0,0) = bottom-left; CGContext (0,0) = top-left
        let transform = CGAffineTransform(scaleX: CGFloat(width), y: -CGFloat(height))
            .translatedBy(x: 0, y: -1)
        guard let scaledPath = observation.normalizedPath.copy(using: [transform]) else {
            throw PipelineStepError.failedToRenderContourContext
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let bitmapContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PipelineStepError.failedToRenderContourContext
        }

        // White background
        bitmapContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        bitmapContext.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Black strokes for contours
        bitmapContext.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        bitmapContext.setLineWidth(1.0)
        bitmapContext.addPath(scaledPath)
        bitmapContext.strokePath()

        guard let renderedCG = bitmapContext.makeImage() else {
            throw PipelineStepError.failedToRenderContourContext
        }
        return CIImage(cgImage: renderedCG)
    }
}
