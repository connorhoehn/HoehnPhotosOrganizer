import AppKit

// MARK: - WatercolorPipeline

/// Watercolor: bilateralFilter (heavy) -> kmeans (fewer colors) -> wet edge bleed -> transparency -> paper texture.
/// Produces transparent washes with wet-on-wet bleeding, granulation, and cold-pressed paper texture.
enum WatercolorPipeline: StudioPipeline {

    static let mediumName = "Watercolor"
    static let mediumIcon = "drop.triangle"

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Number of colors for k-means quantization (3–16).
        /// Watercolor uses fewer colors than oil — transparent washes limit palette complexity.
        var numColors: Int
        /// Wash intensity: how strongly the bilateral filter smooths (0–1).
        /// Higher values create broader, more dissolved washes.
        var washIntensity: Double
        /// Wet-edge bleed amount — Gaussian blur sigma applied to simulate
        /// pigment bleeding at wash boundaries (0–15).
        var bleedAmount: Double
        /// Paper wetness — controls transparency and lightening (0–1).
        /// Higher values produce more diluted, luminous washes.
        var paperWetness: Double
    }

    static let defaultParams = Params(
        numColors: 8,
        washIntensity: 0.7,
        bleedAmount: 5.0,
        paperWetness: 0.4
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        progress(0.0)

        // Step 1: Heavy bilateral filter to dissolve detail into broad wash areas.
        // Watercolor paintings lack the textural detail of oil; pigment flows freely
        // on wet paper, so we use a large bilateral kernel to merge similar regions
        // into flat, watery areas while preserving major color boundaries.
        let diameter = 9 + Int(params.washIntensity * 16) // 9–25
        let sigma = 50.0 + params.washIntensity * 100.0          // 50–150
        guard let washed = CVImageProcessor.bilateralFilter(
            source,
            diameter: diameter,
            sigmaColor: sigma,
            sigmaSpace: sigma
        ) else {
            throw PipelineError.renderStepFailed(step: "bilateralFilter (wash)")
        }
        progress(0.15)
        try Task.checkCancellation()

        // Step 2: K-means quantization with fewer colors.
        // Watercolorists work with a limited palette, premixing washes in wells.
        // Fewer clusters = larger, simpler color areas = more painterly.
        guard let quantized = CVImageProcessor.kmeansQuantize(
            washed,
            numColors: params.numColors
        ) else {
            throw PipelineError.renderStepFailed(step: "kmeansQuantize")
        }
        progress(0.35)
        try Task.checkCancellation()

        // Step 3: Detect edges for wet-edge bleeding.
        // Where two washes meet on wet paper, pigment from both sides
        // blooms into the boundary, creating a soft, darkened edge.
        // We use Canny to find boundaries, then blur them to simulate bleed.
        guard let edges = CVImageProcessor.cannyEdges(
            quantized.image,
            threshold1: 30.0,
            threshold2: 90.0
        ) else {
            throw PipelineError.renderStepFailed(step: "cannyEdges (wet edge)")
        }
        progress(0.45)
        try Task.checkCancellation()

        // Blur the edge mask to create the bleeding effect.
        guard let blurredEdges = CVImageProcessor.gaussianBlur(
            edges,
            sigma: params.bleedAmount
        ) else {
            throw PipelineError.renderStepFailed(step: "gaussianBlur (edge bleed)")
        }
        progress(0.55)
        try Task.checkCancellation()

        // Step 4: Darken boundaries by multiplying blurred edges onto the quantized image.
        // This simulates pigment accumulation at wash edges — the characteristic
        // "blooming" or "cauliflower" effect of wet-on-wet watercolor.
        guard let edgeOverlay = CVImageProcessor.multiplyBlend(
            base: quantized.image,
            top: blurredEdges
        ) else {
            throw PipelineError.renderStepFailed(step: "multiplyBlend (edge overlay)")
        }
        progress(0.65)
        try Task.checkCancellation()

        // Step 5: Lighten toward paper white to simulate transparency.
        // Watercolor is a transparent medium — the white paper shows through diluted washes.
        // We brighten the image proportionally to paperWetness, lifting midtones and shadows
        // to create the luminous, backlit quality of real watercolor.
        let brightness = params.paperWetness * 30.0 // 0–30
        guard let transparent = CVImageProcessor.adjustBrightnessContrast(
            edgeOverlay,
            brightness: brightness,
            contrast: 0.9 + (1.0 - params.paperWetness) * 0.2
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast (transparency)")
        }
        progress(0.80)
        try Task.checkCancellation()

        // Step 6: Paper texture overlay — cold-pressed watercolor paper grain.
        // The rough paper surface causes granulation where heavy pigment settles
        // into the paper's valleys. We add noise and multiply-blend for this effect.
        guard let paperGrain = CVImageProcessor.addGaussianNoise(
            transparent,
            strength: 0.10
        ) else {
            throw PipelineError.renderStepFailed(step: "paper grain noise")
        }

        guard let result = CVImageProcessor.addWeighted(
            transparent,
            alpha: 0.85,
            paperGrain,
            beta: 0.15,
            gamma: 0.0
        ) else {
            throw PipelineError.renderStepFailed(step: "paper texture blend")
        }
        progress(1.0)

        return result
    }
}
