import AppKit

// MARK: - StudioRenderer Protocol

/// Protocol-based renderer so backends can be swapped.
protocol StudioRenderer: Sendable {
    func render(
        image: NSImage,
        medium: ArtMedium,
        params: MediumParameters,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NSImage

    /// Render using type-safe per-pipeline params (no legacy mapping).
    func render(
        image: NSImage,
        typedParams: MediumParams,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NSImage
}

// MARK: - OpenCVStudioRenderer

/// OpenCV-backed renderer that dispatches to per-medium Pipeline enums.
/// Each pipeline owns its full render chain using CVImageProcessor calls.
/// This class maps the generic `MediumParameters` to each pipeline's
/// specific `Params` struct, then delegates rendering.
final class OpenCVStudioRenderer: StudioRenderer {

    func render(
        image: NSImage,
        medium: ArtMedium,
        params: MediumParameters,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NSImage {
        try Task.checkCancellation()
        progress(0.02)

        let result: NSImage = try await Task.detached(priority: .userInitiated) {
            switch medium {
            case .oil:
                return try await OilPaintPipeline.render(
                    source: image,
                    params: Self.mapOilParams(params),
                    progress: progress
                )
            case .watercolor:
                return try await WatercolorPipeline.render(
                    source: image,
                    params: Self.mapWatercolorParams(params),
                    progress: progress
                )
            case .charcoal:
                return try await CharcoalPipeline.render(
                    source: image,
                    params: Self.mapCharcoalParams(params),
                    progress: progress
                )
            case .troisCrayon:
                return try await TroisCrayonPipeline.render(
                    source: image,
                    params: Self.mapTroisCrayonParams(params),
                    progress: progress
                )
            case .graphite:
                return try await GraphitePipeline.render(
                    source: image,
                    params: Self.mapGraphiteParams(params),
                    progress: progress
                )
            case .inkWash:
                return try await InkWashPipeline.render(
                    source: image,
                    params: Self.mapInkWashParams(params),
                    progress: progress
                )
            case .pastel:
                return try await PastelPipeline.render(
                    source: image,
                    params: Self.mapPastelParams(params),
                    progress: progress
                )
            case .penAndInk:
                return try await PenAndInkPipeline.render(
                    source: image,
                    params: Self.mapPenAndInkParams(params),
                    progress: progress
                )
            }
        }.value

        try Task.checkCancellation()
        return result
    }

    /// Render using type-safe per-pipeline params directly (no legacy mapping).
    func render(
        image: NSImage,
        typedParams: MediumParams,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> NSImage {
        try Task.checkCancellation()
        progress(0.02)

        let result: NSImage = try await Task.detached(priority: .userInitiated) {
            switch typedParams {
            case .oil(let p):         return try await OilPaintPipeline.render(source: image, params: p, progress: progress)
            case .watercolor(let p):  return try await WatercolorPipeline.render(source: image, params: p, progress: progress)
            case .charcoal(let p):    return try await CharcoalPipeline.render(source: image, params: p, progress: progress)
            case .troisCrayon(let p): return try await TroisCrayonPipeline.render(source: image, params: p, progress: progress)
            case .graphite(let p):    return try await GraphitePipeline.render(source: image, params: p, progress: progress)
            case .inkWash(let p):     return try await InkWashPipeline.render(source: image, params: p, progress: progress)
            case .pastel(let p):      return try await PastelPipeline.render(source: image, params: p, progress: progress)
            case .penAndInk(let p):   return try await PenAndInkPipeline.render(source: image, params: p, progress: progress)
            }
        }.value

        try Task.checkCancellation()
        return result
    }

    // MARK: - Parameter Mapping

    /// Oil: brushSize -> bilateralD & sigmaSpace, detail -> numColors & sigmaColor,
    /// texture -> brushTexture, contrast -> pruneMinPixels (higher contrast = less pruning).
    private static func mapOilParams(_ p: MediumParameters) -> OilPaintPipeline.Params {
        OilPaintPipeline.Params(
            numColors: Int(8 + p.detail * 16),                       // 8–24
            bilateralD: Int(5 + p.brushSize * 1.0),                  // 5–25
            sigmaColor: 30.0 + (1.0 - p.detail) * 120.0,            // 30–150 (less detail = more blending)
            sigmaSpace: 30.0 + p.brushSize * 6.0,                    // 30–150
            pruneMinPixels: Int(50 + (1.0 - p.detail) * 350),       // 50–400 (less detail = bigger prune)
            brushTexture: p.texture                                   // 0–1 direct
        )
    }

    /// Watercolor: brushSize -> washIntensity, detail -> numColors,
    /// texture -> paperWetness, contrast -> bleedAmount (inverted: low contrast = more bleed).
    private static func mapWatercolorParams(_ p: MediumParameters) -> WatercolorPipeline.Params {
        WatercolorPipeline.Params(
            numColors: max(3, Int(4 + p.detail * 12)),               // 4–16
            washIntensity: min(1.0, p.brushSize / 20.0 * 1.2),      // 0–1 scaled from brushSize 1–20
            bleedAmount: 2.0 + (1.0 - p.contrast) * 13.0,           // 2–15 (lower contrast = more bleed)
            paperWetness: p.texture * 0.8                             // 0–0.8 (texture drives paper wetness)
        )
    }

    /// Charcoal: brushSize -> blurRadius & smudgeAmount, detail -> thresholds,
    /// texture -> paperRoughness, contrast -> contrast.
    private static func mapCharcoalParams(_ p: MediumParameters) -> CharcoalPipeline.Params {
        // Threshold breakpoints shift based on detail:
        // High detail = wider spread (more tonal zones visible)
        // Low detail = compressed dark (more black mass)
        let detailShift = Int(p.detail * 30)  // 0–30
        let thresholds = [
            max(10, 20 + detailShift / 2),     // 20–35
            max(30, 50 + detailShift),          // 50–80
            max(60, 100 + detailShift),         // 100–130
            max(100, 155 + detailShift)         // 155–185
        ]

        return CharcoalPipeline.Params(
            blurRadius: max(1, p.brushSize * 2.0),                   // 2–40
            thresholds: thresholds,
            contrast: 80.0 + p.contrast * 120.0,                     // 80–200
            paperRoughness: p.texture,                                // 0–1 direct
            smudgeAmount: p.brushSize * 1.0                           // 1–20
        )
    }

    /// Trois Crayon: brushSize -> blurRadius, detail -> thresholds,
    /// contrast -> sketch contrast. Colors are fixed to the traditional palette.
    private static func mapTroisCrayonParams(_ p: MediumParameters) -> TroisCrayonPipeline.Params {
        // Threshold breakpoints control the black/sanguine/paper distribution.
        // Higher detail = more zones revealed; lower detail = more shadow mass.
        let detailShift = Int(p.detail * 40)  // 0–40
        let thresholds = [
            max(20, 40 + detailShift / 2),     // 40–60
            max(60, 110 + detailShift / 2),    // 110–130
            max(120, 170 + detailShift / 2)    // 170–190
        ]

        // Sanguine color slightly warmer/cooler based on colorSaturation
        let satBoost = p.colorSaturation
        let sangR = UInt8(min(255, 145 + Int(satBoost * 40)))    // 145–185
        let sangG = UInt8(max(30, 65 - Int(satBoost * 20)))      // 45–65
        let sangB = UInt8(max(20, 38 - Int(satBoost * 10)))      // 28–38

        return TroisCrayonPipeline.Params(
            blurRadius: max(5, p.brushSize * 2.5),                   // 5–50 (clamped by pipeline)
            thresholds: thresholds,
            sanguineColor: TroisCrayonPipeline.RGBColor(r: sangR, g: sangG, b: sangB),
            paperColor: TroisCrayonPipeline.RGBColor(r: 194, g: 179, b: 158),
            contrast: 70.0 + p.contrast * 130.0                      // 70–200
        )
    }

    /// Graphite: brushSize -> blurRadius, detail -> thresholds & sharpAmount,
    /// texture -> paperTexture & noiseStrength, contrast -> contrast.
    private static func mapGraphiteParams(_ p: MediumParameters) -> GraphitePipeline.Params {
        let detailShift = Int(p.detail * 30)
        let thresholds = [
            max(15, 35 + detailShift / 2),     // 35–50
            max(50, 85 + detailShift / 2),     // 85–100
            max(100, 140 + detailShift / 2),   // 140–155
            max(150, 190 + detailShift / 2)    // 190–205
        ]

        return GraphitePipeline.Params(
            blurRadius: max(5, p.brushSize * 3.0),                   // 5–60 (fine pencil = low brush)
            thresholds: thresholds,
            contrast: 80.0 + p.contrast * 120.0,                     // 80–200
            paperTexture: p.texture * 0.6,                            // 0–0.6
            noiseStrength: 3.0 + p.texture * 12.0,                   // 3–15
            sharpAmount: 0.3 + p.detail * 1.2                        // 0.3–1.5
        )
    }

    /// Ink Wash: brushSize -> blurAmount, detail -> numBands,
    /// contrast -> inkDensity, texture -> edgeStrength (subtle mapping).
    private static func mapInkWashParams(_ p: MediumParameters) -> InkWashPipeline.Params {
        InkWashPipeline.Params(
            numBands: max(4, Int(4 + p.detail * 4)),                 // 4–8
            blurAmount: 1.0 + p.brushSize * 0.55,                    // 1–12
            edgeStrength: 0.2 + p.texture * 0.6,                     // 0.2–0.8
            inkDensity: p.contrast                                    // 0–1 direct
        )
    }

    /// Pastel: brushSize -> softness, detail -> numColors,
    /// colorSaturation -> saturation, texture -> textureGrain.
    private static func mapPastelParams(_ p: MediumParameters) -> PastelPipeline.Params {
        PastelPipeline.Params(
            numColors: max(6, Int(6 + p.detail * 14)),               // 6–20
            softness: p.brushSize * 0.4,                              // 0.4–8
            saturation: 0.5 + p.colorSaturation * 1.5,               // 0.5–2.0
            textureGrain: p.texture                                   // 0–1 direct
        )
    }

    /// Pen & Ink: detail -> edgeSensitivity (inverted: high detail = low sensitivity = more edges),
    /// brushSize -> lineWeight, contrast -> contrast.
    private static func mapPenAndInkParams(_ p: MediumParameters) -> PenAndInkPipeline.Params {
        PenAndInkPipeline.Params(
            edgeSensitivity: 1.0 - p.detail,                         // inverted: more detail = lower threshold = more edges
            lineWeight: max(0.3, p.brushSize * 0.15),                // 0.3–3.0
            contrast: 0.5 + p.contrast * 1.5                         // 0.5–2.0
        )
    }

}
