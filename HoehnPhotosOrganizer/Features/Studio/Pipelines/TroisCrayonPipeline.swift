import AppKit

// MARK: - TroisCrayonPipeline

/// Trois crayon technique: pencilSketch -> 3-color threshold (black + sanguine + paper).
/// The historical trois crayon method uses black chalk, sanguine (red-brown),
/// and white chalk on toned paper to create warm, dimensional figure drawings.
enum TroisCrayonPipeline: StudioPipeline {

    static let mediumName = "Trois Crayon"
    static let mediumIcon = "pencil.and.outline"

    // MARK: - RGBColor

    struct RGBColor: Equatable, Codable, Hashable {
        var r: UInt8
        var g: UInt8
        var b: UInt8
    }

    // MARK: - Params

    struct Params: Equatable, Codable, Hashable {
        /// Blur radius for pencil sketch extraction (1–40).
        var blurRadius: Double
        /// Threshold breakpoints for the 3-color mapping (2–4 values, ascending).
        /// With 2 thresholds: [black|sanguine|paper].
        /// With 3 thresholds: [black|dark sanguine|light sanguine|paper].
        /// With 4 thresholds: [black|dark sanguine|mid sanguine|light/white chalk|paper].
        var thresholds: [Int]
        /// Sanguine crayon color — warm red-brown (RGB 0–255).
        var sanguineColor: RGBColor
        /// Toned paper base color (RGB 0–255).
        var paperColor: RGBColor
        /// Output contrast (50–200, maps to PencilSketchParams.contrast).
        var contrast: Double
    }

    static let defaultParams = Params(
        blurRadius: 25.0,
        thresholds: [60, 130, 190],
        sanguineColor: RGBColor(r: 165, g: 65, b: 38),   // warm sanguine red-brown
        paperColor: RGBColor(r: 194, g: 179, b: 158),      // classic toned paper
        contrast: 120.0
    )

    // MARK: - Render

    static func render(
        source: NSImage,
        params: Params,
        progress: @escaping (Double) -> Void
    ) async throws -> NSImage {
        progress(0.0)

        // Step 1: Generate pencil sketch from the source.
        // This extracts the luminance structure that will be mapped
        // to the three crayon materials.
        let sketchParams = CVImageProcessor.PencilSketchParams(
            blurRadius: params.blurRadius,
            brightness: -20,
            contrast: params.contrast,
            noiseStrength: 6,
            sharpAmount: 1.2
        )
        guard let sketch = CVImageProcessor.pencilSketch(source, params: sketchParams) else {
            throw PipelineError.renderStepFailed(step: "pencilSketch")
        }
        progress(0.20)
        try Task.checkCancellation()

        // Step 2: Build the trois crayon palette for threshold mapping.
        // The palette maps luminance zones to specific colors:
        //   - Darkest zone: black chalk (pure black strokes for deepest shadows)
        //   - Middle zone(s): sanguine crayon (warm red-brown for flesh/midtones)
        //   - Lightest zone: paper color shows through (toned paper is the "white")
        let sang = params.sanguineColor
        let paper = params.paperColor

        let paletteColors: [PBNColor]
        if params.thresholds.count >= 3 {
            // 4-zone: black, dark sanguine, light sanguine, paper
            paletteColors = [
                PBNColor(red: 0.05, green: 0.05, blue: 0.05, name: "Black Chalk"),
                PBNColor(red: Double(sang.r) / 255, green: Double(sang.g) / 255, blue: Double(sang.b) / 255, name: "Dark Sanguine"),
                PBNColor(
                    red: min(1.0, Double(sang.r) / 255 * 1.4),
                    green: min(1.0, Double(sang.g) / 255 * 1.3),
                    blue: min(1.0, Double(sang.b) / 255 * 1.2),
                    name: "Light Sanguine"
                ),
                PBNColor(red: Double(paper.r) / 255, green: Double(paper.g) / 255, blue: Double(paper.b) / 255, name: "Toned Paper"),
            ]
        } else {
            // 3-zone: black, sanguine, paper
            paletteColors = [
                PBNColor(red: 0.05, green: 0.05, blue: 0.05, name: "Black Chalk"),
                PBNColor(red: Double(sang.r) / 255, green: Double(sang.g) / 255, blue: Double(sang.b) / 255, name: "Sanguine"),
                PBNColor(red: Double(paper.r) / 255, green: Double(paper.g) / 255, blue: Double(paper.b) / 255, name: "Toned Paper"),
            ]
        }

        let palette = PBNPalette(name: "Trois Crayon", colors: paletteColors)
        let thresholdSet = PBNThresholdSet(thresholds: params.thresholds)

        guard let colorMapped = CVImageProcessor.thresholdMap(
            sketch,
            thresholds: thresholdSet,
            palette: palette
        ) else {
            throw PipelineError.renderStepFailed(step: "thresholdMap (trois crayon palette)")
        }
        progress(0.50)
        try Task.checkCancellation()

        // Step 3: Add subtle noise for the chalky crayon texture.
        // Real crayon drags across paper tooth; the micro-grain breaks up flat zones.
        guard let textured = CVImageProcessor.addGaussianNoise(
            colorMapped,
            strength: 4.0
        ) else {
            throw PipelineError.renderStepFailed(step: "addGaussianNoise (chalk texture)")
        }
        progress(0.65)
        try Task.checkCancellation()

        // Step 4: Light blur to soften hard threshold edges.
        // Crayon marks have soft edges where pigment feathers out.
        guard let softened = CVImageProcessor.gaussianBlur(
            textured,
            sigma: 1.2
        ) else {
            throw PipelineError.renderStepFailed(step: "gaussianBlur (soften)")
        }
        progress(0.80)
        try Task.checkCancellation()

        // Step 5: Final brightness/contrast adjustment for the toned-paper look.
        guard let result = CVImageProcessor.adjustBrightnessContrast(
            softened,
            brightness: 0.0,
            contrast: 1.05
        ) else {
            throw PipelineError.renderStepFailed(step: "adjustBrightnessContrast")
        }
        progress(1.0)

        return result
    }
}
