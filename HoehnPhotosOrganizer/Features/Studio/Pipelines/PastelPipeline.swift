import AppKit

// MARK: - PastelPipeline

/// Pastel: bilateralFilter -> kmeans (vivid) -> soft blur -> saturation boost -> sanded paper.
/// Produces soft, chalky color with visible strokes and blended passages.
enum PastelPipeline: StudioPipeline {

    static let mediumName = "Pastel"
    static let mediumIcon = "circle.lefthalf.filled"

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Number of colors for k-means palette (6–20).
        /// Pastels come in sticks of fixed colors; k-means maps the image to a limited set.
        var numColors: Int
        /// Softness — Gaussian blur sigma for the chalky, blended look (0–8).
        var softness: Double
        /// Color saturation boost multiplier (0.5–2.0).
        /// Pastels are intensely pigmented; values above 1.0 push vivid color.
        var saturation: Double
        /// Texture grain strength for sanded pastel paper (0–1).
        var textureGrain: Double
    }

    static let defaultParams = Params(
        numColors: 14,
        softness: 3.0,
        saturation: 1.3,
        textureGrain: 0.5
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        progress(0.0)

        // Step 1: Bilateral filter to smooth fine detail while keeping color edges.
        // Soft pastels blend on the paper surface; bilateral smoothing mimics
        // how the chalky pigment fills in texture and merges neighboring strokes.
        guard let smoothed = CVImageProcessor.bilateralFilter(
            source,
            diameter: 11,
            sigmaColor: 60.0,
            sigmaSpace: 60.0
        ) else {
            throw PipelineError.renderStepFailed(step: "bilateralFilter")
        }
        progress(0.15)
        try Task.checkCancellation()

        // Step 2: K-means quantization for a limited pastel-stick palette.
        // Real pastel sets have 24–72 sticks; quantizing to numColors creates
        // the flat, buttery color blocks characteristic of pastel work.
        guard let quantized = CVImageProcessor.kmeansQuantize(
            smoothed,
            numColors: params.numColors
        ) else {
            throw PipelineError.renderStepFailed(step: "kmeansQuantize")
        }
        progress(0.35)
        try Task.checkCancellation()

        // Step 3: Soft Gaussian blur for the chalky, blended-passage look.
        // Pastel artists use fingers, tortillons, or chamois to blend color areas
        // into soft gradations. The blur simulates this blending.
        guard let softened = CVImageProcessor.gaussianBlur(
            quantized.image,
            sigma: params.softness
        ) else {
            throw PipelineError.renderStepFailed(step: "gaussianBlur (softness)")
        }
        progress(0.50)
        try Task.checkCancellation()

        // Step 4: Blend the soft version back with the quantized version.
        // Keep some hard-edged color blocks visible (unblended strokes)
        // mixed with soft passages — the hallmark of pastel technique.
        guard let mixed = CVImageProcessor.addWeighted(
            quantized.image,
            alpha: 0.35,
            softened,
            beta: 0.65,
            gamma: 0.0
        ) else {
            throw PipelineError.renderStepFailed(step: "addWeighted (stroke/blend mix)")
        }
        progress(0.60)
        try Task.checkCancellation()

        // Step 5: Saturation boost for vivid chalky pigment.
        // Pastels are among the most saturated of traditional media because
        // the pure pigment sits directly on the paper surface (no binder dilution).
        // We boost brightness slightly and contrast to match this vibrancy.
        let brightnessBump = (params.saturation - 1.0) * 10.0 // subtle
        guard let vivid = CVImageProcessor.adjustBrightnessContrast(
            mixed,
            brightness: brightnessBump,
            contrast: params.saturation * 0.85 + 0.15
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast (saturation)")
        }
        progress(0.72)
        try Task.checkCancellation()

        // Step 6: Sanded paper texture.
        // Pastel paper (like Canson Mi-Teintes or sanded UArt) has aggressive tooth
        // that grabs pigment particles. The grain shows through, especially in
        // lightly-applied areas. We simulate this with noise + multiply blend.
        guard let grainNoise = CVImageProcessor.addGaussianNoise(
            vivid,
            strength: params.textureGrain * 0.25
        ) else {
            throw PipelineError.renderStepFailed(step: "grain noise")
        }
        progress(0.85)
        try Task.checkCancellation()

        // Multiply-blend the grain to darken where paper tooth shows through.
        guard let grained = CVImageProcessor.multiplyBlend(
            base: vivid,
            top: grainNoise
        ) else {
            throw PipelineError.renderStepFailed(step: "multiplyBlend (paper grain)")
        }

        // Final weighted merge: most of the vivid pastel color with some grain.
        guard let result = CVImageProcessor.addWeighted(
            vivid,
            alpha: 1.0 - params.textureGrain * 0.4,
            grained,
            beta: params.textureGrain * 0.4,
            gamma: 0.0
        ) else {
            throw PipelineError.renderStepFailed(step: "paper texture final blend")
        }
        progress(1.0)

        return result
    }
}
