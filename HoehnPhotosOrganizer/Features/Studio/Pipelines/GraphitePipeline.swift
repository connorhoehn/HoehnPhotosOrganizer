import AppKit

// MARK: - GraphitePipeline

/// Graphite pencil rendering: pencilSketch -> 5-zone gray threshold -> paper texture overlay.
/// Produces fine-detail pencil drawings with smooth tonal gradation and visible hatching.
enum GraphitePipeline: StudioPipeline {

    static let mediumName = "Graphite"
    static let mediumIcon = "pencil"

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Blur radius for the initial pencil sketch extraction (1–40).
        var blurRadius: Double
        /// Four threshold values dividing 5 gray zones (0–255 each, ascending).
        var thresholds: [Int]
        /// Output contrast boost (50–200, maps to PencilSketchParams.contrast).
        var contrast: Double
        /// Paper texture blend strength (0–1).
        var paperTexture: Double
        /// Gaussian noise strength for paper grain (0–30).
        var noiseStrength: Double
        /// Unsharp-mask amount for final sharpening (0–3).
        var sharpAmount: Double
    }

    static let defaultParams = Params(
        blurRadius: 30.0,
        thresholds: [50, 100, 155, 205],
        contrast: 130.0,
        paperTexture: 0.3,
        noiseStrength: 8.0,
        sharpAmount: 1.0
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        progress(0.0)

        // Step 1: Generate pencil sketch base from source.
        // pencilSketch uses adaptive thresholding + Gaussian blur to extract
        // light/dark pencil strokes from the luminance channel.
        let sketchParams = CVImageProcessor.PencilSketchParams(
            blurRadius: params.blurRadius,
            brightness: -20,
            contrast: params.contrast,
            noiseStrength: params.noiseStrength,
            sharpAmount: params.sharpAmount
        )
        guard let sketch = CVImageProcessor.pencilSketch(source, params: sketchParams) else {
            throw PipelineError.renderStepFailed(step: "pencilSketch")
        }
        progress(0.20)
        try Task.checkCancellation()

        // Step 2: Map the sketch into 5 discrete gray zones using threshold boundaries.
        // Zones: [0..t0], [t0..t1], [t1..t2], [t2..t3], [t3..255]
        // Each zone gets a flat gray value, simulating the limited tonal range of
        // graphite pencil pressure levels (6B through 2H).
        let t = params.thresholds
        let zones: [CVImageProcessor.ThresholdZone] = [
            .init(lower: 0,      upper: t[0],  color: (r: 30,  g: 30,  b: 30)),   // darkest graphite
            .init(lower: t[0],   upper: t[1],  color: (r: 90,  g: 90,  b: 90)),   // heavy shading
            .init(lower: t[1],   upper: t[2],  color: (r: 155, g: 155, b: 155)),   // mid-tone hatching
            .init(lower: t[2],   upper: t[3],  color: (r: 210, g: 210, b: 210)),   // light touch
            .init(lower: t[3],   upper: 255,   color: (r: 248, g: 248, b: 248)),   // paper white
        ]
        guard let thresholded = CVImageProcessor.thresholdMap(
            sketch,
            zones: zones,
            backgroundColor: (r: 255, g: 255, b: 255)
        ) else {
            throw PipelineError.renderStepFailed(step: "thresholdMap")
        }
        progress(0.45)
        try Task.checkCancellation()

        // Step 3: Add subtle Gaussian noise to simulate paper grain.
        // Real graphite sits on textured paper; the micro-noise breaks up
        // the flat threshold bands and adds tactile realism.
        guard let noisy = CVImageProcessor.addGaussianNoise(
            thresholded,
            strength: params.noiseStrength * 0.5
        ) else {
            throw PipelineError.renderStepFailed(step: "addGaussianNoise")
        }
        progress(0.60)
        try Task.checkCancellation()

        // Step 4: Sharpen to restore fine pencil detail lost in thresholding.
        // Unsharp mask with moderate sigma keeps hatching crisp.
        guard let sharpened = CVImageProcessor.unsharpMask(
            noisy,
            sigma: 1.5,
            amount: params.sharpAmount
        ) else {
            throw PipelineError.renderStepFailed(step: "unsharpMask")
        }
        progress(0.75)
        try Task.checkCancellation()

        // Step 5: Adjust final brightness for the pencil-on-paper look.
        // Slightly lift overall brightness so the paper reads as white.
        guard let contrasted = CVImageProcessor.adjustBrightnessContrast(
            sharpened,
            brightness: 5.0,
            contrast: 1.05
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast")
        }
        progress(0.85)
        try Task.checkCancellation()

        // Step 6: Blend with a paper texture using addWeighted.
        // The paper texture is generated as light Gaussian noise, then blended
        // so pencil marks appear to sit on textured stock.
        guard let paperNoise = CVImageProcessor.addGaussianNoise(
            contrasted,
            strength: params.paperTexture * 5.0
        ) else {
            throw PipelineError.renderStepFailed(step: "paperTexture noise")
        }

        // Weighted blend: mostly the pencil drawing with subtle paper overlay
        guard let result = CVImageProcessor.addWeighted(
            contrasted,
            alpha: 1.0 - params.paperTexture,
            paperNoise,
            beta: params.paperTexture,
            gamma: 0.0
        ) else {
            throw PipelineError.renderStepFailed(step: "paper blend")
        }
        progress(1.0)

        return result
    }
}
