import Foundation

// MARK: - MediumParams

/// Type-safe, medium-specific parameter envelope.
/// Each case carries the native `Params` struct from its pipeline,
/// eliminating the lossy generic→specific mapping layer.
enum MediumParams: Equatable, Codable, Hashable {
    case oil(OilPaintPipeline.Params)
    case watercolor(WatercolorPipeline.Params)
    case charcoal(CharcoalPipeline.Params)
    case troisCrayon(TroisCrayonPipeline.Params)
    case graphite(GraphitePipeline.Params)
    case inkWash(InkWashPipeline.Params)
    case pastel(PastelPipeline.Params)
    case penAndInk(PenAndInkPipeline.Params)

    /// The art medium this params envelope belongs to.
    var medium: ArtMedium {
        switch self {
        case .oil:         return .oil
        case .watercolor:  return .watercolor
        case .charcoal:    return .charcoal
        case .troisCrayon: return .troisCrayon
        case .graphite:    return .graphite
        case .inkWash:     return .inkWash
        case .pastel:      return .pastel
        case .penAndInk:   return .penAndInk
        }
    }

    /// Default parameters for each medium (from pipeline defaults).
    static func defaults(for medium: ArtMedium) -> MediumParams {
        switch medium {
        case .oil:         return .oil(OilPaintPipeline.defaultParams)
        case .watercolor:  return .watercolor(WatercolorPipeline.defaultParams)
        case .charcoal:    return .charcoal(CharcoalPipeline.defaultParams)
        case .troisCrayon: return .troisCrayon(TroisCrayonPipeline.defaultParams)
        case .graphite:    return .graphite(GraphitePipeline.defaultParams)
        case .inkWash:     return .inkWash(InkWashPipeline.defaultParams)
        case .pastel:      return .pastel(PastelPipeline.defaultParams)
        case .penAndInk:   return .penAndInk(PenAndInkPipeline.defaultParams)
        }
    }
}

// MARK: - Legacy Migration

/// Temporary helper to forward-migrate old generic `MediumParameters` to `MediumParams`.
/// Used by version persistence loader to convert old JSON files on disk.
extension MediumParams {

    /// Convert legacy 5-generic-param model to medium-specific params
    /// using the same mapping logic the old `OpenCVStudioRenderer` used.
    static func fromLegacy(medium: ArtMedium, brushSize: Double, detail: Double, texture: Double, colorSaturation: Double, contrast: Double) -> MediumParams {
        switch medium {
        case .oil:
            return .oil(OilPaintPipeline.Params(
                numColors: Int(8 + detail * 16),
                bilateralD: Int(5 + brushSize * 1.0),
                sigmaColor: 30.0 + (1.0 - detail) * 120.0,
                sigmaSpace: 30.0 + brushSize * 6.0,
                pruneMinPixels: Int(50 + (1.0 - detail) * 350),
                brushTexture: texture
            ))
        case .watercolor:
            return .watercolor(WatercolorPipeline.Params(
                numColors: max(3, Int(4 + detail * 12)),
                washIntensity: min(1.0, brushSize / 20.0 * 1.2),
                bleedAmount: 2.0 + (1.0 - contrast) * 13.0,
                paperWetness: texture * 0.8
            ))
        case .charcoal:
            let detailShift = Int(detail * 30)
            return .charcoal(CharcoalPipeline.Params(
                blurRadius: max(0.1, brushSize * 0.15),
                thresholds: [
                    max(10, 20 + detailShift / 2),
                    max(30, 50 + detailShift),
                    max(60, 100 + detailShift),
                    max(100, 155 + detailShift)
                ],
                contrast: 80.0 + contrast * 120.0,
                paperRoughness: texture,
                smudgeAmount: max(0.5, brushSize * 0.25)
            ))
        case .troisCrayon:
            let detailShift = Int(detail * 40)
            let satBoost = colorSaturation
            return .troisCrayon(TroisCrayonPipeline.Params(
                blurRadius: max(5, brushSize * 2.5),
                thresholds: [
                    max(20, 40 + detailShift / 2),
                    max(60, 110 + detailShift / 2),
                    max(120, 170 + detailShift / 2)
                ],
                sanguineColor: TroisCrayonPipeline.RGBColor(
                    r: UInt8(min(255, 145 + Int(satBoost * 40))),
                    g: UInt8(max(30, 65 - Int(satBoost * 20))),
                    b: UInt8(max(20, 38 - Int(satBoost * 10)))
                ),
                paperColor: TroisCrayonPipeline.RGBColor(r: 194, g: 179, b: 158),
                contrast: 70.0 + contrast * 130.0
            ))
        case .graphite:
            let detailShift = Int(detail * 30)
            return .graphite(GraphitePipeline.Params(
                blurRadius: max(0.1, brushSize * 0.15),
                thresholds: [
                    max(15, 35 + detailShift / 2),
                    max(50, 85 + detailShift / 2),
                    max(100, 140 + detailShift / 2),
                    max(150, 190 + detailShift / 2)
                ],
                contrast: 80.0 + contrast * 120.0,
                paperTexture: texture * 0.6,
                noiseStrength: 3.0 + texture * 12.0,
                sharpAmount: 0.3 + detail * 1.2
            ))
        case .inkWash:
            return .inkWash(InkWashPipeline.Params(
                numBands: max(4, Int(4 + detail * 4)),
                blurAmount: 1.0 + brushSize * 0.55,
                edgeStrength: 0.2 + texture * 0.6,
                inkDensity: contrast
            ))
        case .pastel:
            return .pastel(PastelPipeline.Params(
                numColors: max(6, Int(6 + detail * 14)),
                softness: brushSize * 0.4,
                saturation: 0.5 + colorSaturation * 1.5,
                textureGrain: texture
            ))
        case .penAndInk:
            return .penAndInk(PenAndInkPipeline.Params(
                edgeSensitivity: 1.0 - detail,
                lineWeight: max(0.3, brushSize * 0.15),
                contrast: 0.5 + contrast * 1.5
            ))
        }
    }
}
