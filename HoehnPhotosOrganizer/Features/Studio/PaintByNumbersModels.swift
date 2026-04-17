import SwiftUI
import Foundation

// MARK: - PBNColor

/// Platform-agnostic color that is Codable (RGB 0–1 range).
struct PBNColor: Codable, Equatable, Identifiable {
    let id: UUID
    var red: Double   // 0–1
    var green: Double // 0–1
    var blue: Double  // 0–1
    var name: String  // e.g., "Venetian Red", "Sanguine"

    init(id: UUID = UUID(), red: Double, green: Double, blue: Double, name: String) {
        self.id = id
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.name = name
    }

    var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1)
    }

    var color: Color {
        Color(red: red, green: green, blue: blue)
    }
}

// MARK: - PBNPalette

/// A named color palette for paint-by-numbers regions.
struct PBNPalette: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    /// Colors in order from darkest (shadows) to lightest (highlights).
    /// The last color is also used as the paper/background color.
    var colors: [PBNColor]

    init(id: UUID = UUID(), name: String, colors: [PBNColor]) {
        self.id = id
        self.name = name
        self.colors = colors
    }

    /// Stable UUID from a deterministic string (for built-in palettes).
    private static func stableID(_ name: String) -> UUID {
        // Pad/truncate name bytes to exactly 16 for a stable UUID
        var bytes = [UInt8](repeating: 0, count: 16)
        let utf8 = Array(name.utf8)
        for i in 0..<min(utf8.count, 16) {
            bytes[i] = utf8[i]
        }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - Built-in Palettes

    /// Trois Crayon: black charcoal, venetian red, sanguine, light sanguine, warm toned paper.
    static let troisCrayon = PBNPalette(
        id: stableID("troisCrayon"),
        name: "Trois Crayon",
        colors: [
            PBNColor(red: 0.08, green: 0.07, blue: 0.06, name: "Black Charcoal"),
            PBNColor(red: 0.51, green: 0.16, blue: 0.12, name: "Venetian Red"),
            PBNColor(red: 0.72, green: 0.35, blue: 0.24, name: "Sanguine"),
            PBNColor(red: 0.86, green: 0.62, blue: 0.48, name: "Light Sanguine"),
            PBNColor(red: 0.76, green: 0.70, blue: 0.62, name: "Toned Paper"),
        ]
    )

    /// Warm earth tones from raw umber through yellow ochre.
    static let brownEarth = PBNPalette(
        id: stableID("brownEarth"),
        name: "Brown Earth",
        colors: [
            PBNColor(red: 0.15, green: 0.10, blue: 0.06, name: "Raw Umber Dark"),
            PBNColor(red: 0.36, green: 0.22, blue: 0.12, name: "Burnt Umber"),
            PBNColor(red: 0.55, green: 0.36, blue: 0.20, name: "Raw Sienna"),
            PBNColor(red: 0.76, green: 0.58, blue: 0.34, name: "Yellow Ochre"),
            PBNColor(red: 0.93, green: 0.88, blue: 0.78, name: "Buff"),
        ]
    )

    /// Red sanguine tones from deep crimson to pale rose.
    static let redSanguine = PBNPalette(
        id: stableID("redSanguine"),
        name: "Red Sanguine",
        colors: [
            PBNColor(red: 0.28, green: 0.06, blue: 0.06, name: "Deep Crimson"),
            PBNColor(red: 0.55, green: 0.14, blue: 0.12, name: "Red Chalk"),
            PBNColor(red: 0.74, green: 0.30, blue: 0.22, name: "Sanguine"),
            PBNColor(red: 0.88, green: 0.56, blue: 0.46, name: "Salmon"),
            PBNColor(red: 0.96, green: 0.88, blue: 0.84, name: "Pale Rose"),
        ]
    )

    /// Cool blue ink tones from indigo to pale sky.
    static let blueInk = PBNPalette(
        id: stableID("blueInk"),
        name: "Blue Ink",
        colors: [
            PBNColor(red: 0.06, green: 0.08, blue: 0.22, name: "Indigo"),
            PBNColor(red: 0.14, green: 0.22, blue: 0.48, name: "Prussian Blue"),
            PBNColor(red: 0.28, green: 0.42, blue: 0.68, name: "Cobalt"),
            PBNColor(red: 0.56, green: 0.68, blue: 0.84, name: "Cerulean Light"),
            PBNColor(red: 0.88, green: 0.92, blue: 0.96, name: "Pale Sky"),
        ]
    )

    /// Warm sepia tones from dark brown through parchment.
    static let warmSepia = PBNPalette(
        id: stableID("warmSepia"),
        name: "Warm Sepia",
        colors: [
            PBNColor(red: 0.16, green: 0.10, blue: 0.04, name: "Sepia Dark"),
            PBNColor(red: 0.38, green: 0.24, blue: 0.12, name: "Sepia"),
            PBNColor(red: 0.60, green: 0.44, blue: 0.28, name: "Sepia Medium"),
            PBNColor(red: 0.80, green: 0.68, blue: 0.52, name: "Sepia Light"),
            PBNColor(red: 0.94, green: 0.90, blue: 0.82, name: "Parchment"),
        ]
    )

    /// Cool neutral grays for a modern look.
    static let coolGray = PBNPalette(
        id: stableID("coolGray"),
        name: "Cool Gray",
        colors: [
            PBNColor(red: 0.12, green: 0.13, blue: 0.15, name: "Charcoal"),
            PBNColor(red: 0.32, green: 0.34, blue: 0.36, name: "Dark Gray"),
            PBNColor(red: 0.54, green: 0.56, blue: 0.58, name: "Medium Gray"),
            PBNColor(red: 0.78, green: 0.80, blue: 0.82, name: "Light Gray"),
            PBNColor(red: 0.95, green: 0.96, blue: 0.97, name: "Off White"),
        ]
    )

    /// Classic paint-by-numbers kit: bright, distinct, primary/secondary colors.
    static let classicPBN = PBNPalette(
        id: stableID("classicPBN"),
        name: "Classic PBN",
        colors: [
            PBNColor(red: 0.10, green: 0.10, blue: 0.10, name: "Black"),
            PBNColor(red: 0.80, green: 0.12, blue: 0.14, name: "Red"),
            PBNColor(red: 0.16, green: 0.30, blue: 0.70, name: "Blue"),
            PBNColor(red: 0.98, green: 0.82, blue: 0.10, name: "Yellow"),
            PBNColor(red: 0.14, green: 0.58, blue: 0.24, name: "Green"),
            PBNColor(red: 0.94, green: 0.50, blue: 0.12, name: "Orange"),
            PBNColor(red: 0.56, green: 0.18, blue: 0.56, name: "Purple"),
            PBNColor(red: 0.54, green: 0.30, blue: 0.16, name: "Brown"),
            PBNColor(red: 0.96, green: 0.58, blue: 0.66, name: "Pink"),
            PBNColor(red: 0.98, green: 0.98, blue: 0.96, name: "White"),
        ]
    )

    /// Pure monochrome grays from black to white.
    static let monochrome = PBNPalette(
        id: stableID("monochrome"),
        name: "Monochrome",
        colors: [
            PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
            PBNColor(red: 0.25, green: 0.25, blue: 0.25, name: "Dark Gray"),
            PBNColor(red: 0.50, green: 0.50, blue: 0.50, name: "Mid Gray"),
            PBNColor(red: 0.75, green: 0.75, blue: 0.75, name: "Light Gray"),
            PBNColor(red: 1.0, green: 1.0, blue: 1.0, name: "White"),
        ]
    )

    /// Oil painter's standard palette — the essential 14 pigments for classical oil painting.
    static let oilClassic = PBNPalette(
        id: stableID("oilClassic"),
        name: "Oil — Classic",
        colors: [
            PBNColor(red: 0.06, green: 0.06, blue: 0.06, name: "Mars Black"),
            PBNColor(red: 0.36, green: 0.20, blue: 0.10, name: "Burnt Umber"),
            PBNColor(red: 0.55, green: 0.27, blue: 0.14, name: "Burnt Sienna"),
            PBNColor(red: 0.60, green: 0.38, blue: 0.22, name: "Raw Sienna"),
            PBNColor(red: 0.50, green: 0.08, blue: 0.10, name: "Alizarin Crimson"),
            PBNColor(red: 0.80, green: 0.18, blue: 0.14, name: "Cadmium Red Pale"),
            PBNColor(red: 0.90, green: 0.45, blue: 0.10, name: "Cadmium Orange"),
            PBNColor(red: 0.78, green: 0.68, blue: 0.38, name: "Yellow Ochre"),
            PBNColor(red: 0.98, green: 0.88, blue: 0.30, name: "Cadmium Yellow Lt."),
            PBNColor(red: 0.22, green: 0.55, blue: 0.28, name: "Cadmium Green Pale"),
            PBNColor(red: 0.30, green: 0.48, blue: 0.32, name: "Cinnabar Green Med."),
            PBNColor(red: 0.16, green: 0.42, blue: 0.36, name: "Viridian"),
            PBNColor(red: 0.38, green: 0.60, blue: 0.78, name: "Cerulean Blue"),
            PBNColor(red: 0.14, green: 0.12, blue: 0.50, name: "Ultramarine Blue"),
        ]
    )

    /// Watercolor palette — transparent pigments for luminous washes.
    static let watercolorField = PBNPalette(
        id: stableID("watercolorField"),
        name: "Watercolor — Field",
        colors: [
            PBNColor(red: 0.05, green: 0.05, blue: 0.08, name: "Payne's Gray"),
            PBNColor(red: 0.36, green: 0.22, blue: 0.12, name: "Burnt Umber"),
            PBNColor(red: 0.60, green: 0.32, blue: 0.16, name: "Burnt Sienna"),
            PBNColor(red: 0.72, green: 0.18, blue: 0.16, name: "Cadmium Red"),
            PBNColor(red: 0.48, green: 0.06, blue: 0.12, name: "Alizarin Crimson"),
            PBNColor(red: 0.92, green: 0.52, blue: 0.14, name: "Cadmium Orange"),
            PBNColor(red: 0.96, green: 0.84, blue: 0.26, name: "Cadmium Yellow"),
            PBNColor(red: 0.74, green: 0.64, blue: 0.36, name: "Yellow Ochre"),
            PBNColor(red: 0.22, green: 0.58, blue: 0.32, name: "Sap Green"),
            PBNColor(red: 0.16, green: 0.40, blue: 0.34, name: "Viridian"),
            PBNColor(red: 0.36, green: 0.58, blue: 0.76, name: "Cerulean Blue"),
            PBNColor(red: 0.12, green: 0.14, blue: 0.48, name: "Ultramarine Blue"),
        ]
    )

    /// Zorn palette — limited palette used by Anders Zorn (4 colors + white).
    static let zornPalette = PBNPalette(
        id: stableID("zornPalette"),
        name: "Zorn Palette",
        colors: [
            PBNColor(red: 0.04, green: 0.04, blue: 0.04, name: "Ivory Black"),
            PBNColor(red: 0.72, green: 0.18, blue: 0.14, name: "Cadmium Red"),
            PBNColor(red: 0.78, green: 0.68, blue: 0.38, name: "Yellow Ochre"),
            PBNColor(red: 0.96, green: 0.94, blue: 0.90, name: "Titanium White"),
        ]
    )

    /// Earth tones expanded — for landscape and portrait work.
    static let earthExpanded = PBNPalette(
        id: stableID("earthExpanded"),
        name: "Earth Tones",
        colors: [
            PBNColor(red: 0.06, green: 0.05, blue: 0.04, name: "Lamp Black"),
            PBNColor(red: 0.22, green: 0.14, blue: 0.08, name: "Van Dyke Brown"),
            PBNColor(red: 0.36, green: 0.20, blue: 0.10, name: "Burnt Umber"),
            PBNColor(red: 0.55, green: 0.27, blue: 0.14, name: "Burnt Sienna"),
            PBNColor(red: 0.60, green: 0.38, blue: 0.22, name: "Raw Sienna"),
            PBNColor(red: 0.68, green: 0.52, blue: 0.30, name: "Gold Ochre"),
            PBNColor(red: 0.78, green: 0.68, blue: 0.38, name: "Yellow Ochre"),
            PBNColor(red: 0.86, green: 0.78, blue: 0.62, name: "Naples Yellow"),
            PBNColor(red: 0.94, green: 0.90, blue: 0.80, name: "Buff Titanium"),
            PBNColor(red: 0.98, green: 0.96, blue: 0.92, name: "Titanium White"),
        ]
    )

    /// Grisaille — burnt umber value scale for monochrome underpainting.
    static let grisaille = PBNPalette(
        id: stableID("grisaille"),
        name: "Grisaille",
        colors: [
            PBNColor(red: 0.10, green: 0.06, blue: 0.03, name: "Burnt Umber Deep"),
            PBNColor(red: 0.25, green: 0.16, blue: 0.09, name: "Burnt Umber"),
            PBNColor(red: 0.42, green: 0.30, blue: 0.20, name: "Burnt Umber Mid"),
            PBNColor(red: 0.60, green: 0.48, blue: 0.34, name: "Burnt Umber Light"),
            PBNColor(red: 0.78, green: 0.68, blue: 0.54, name: "Warm Gray"),
            PBNColor(red: 0.90, green: 0.84, blue: 0.74, name: "Warm Off-White"),
            PBNColor(red: 0.96, green: 0.94, blue: 0.90, name: "Titanium White"),
        ]
    )

    /// Classic — the standard oil painter's full palette (14 pigments).
    /// Cadmium Yellow Lt., Yellow Ochre, Cadmium Orange, Cadmium Red Pale,
    /// Alizarin Crimson, Raw Sienna, Burnt Sienna, Burnt Umber,
    /// Cadmium Green Pale, Cinnabar Green Med., Viridian,
    /// Cerulean Blue, Ultramarine Blue, Mars Black.
    static let classic = PBNPalette(
        id: stableID("classicOil"),
        name: "Classic",
        colors: [
            PBNColor(red: 0.06, green: 0.06, blue: 0.06, name: "Mars Black"),
            PBNColor(red: 0.36, green: 0.20, blue: 0.10, name: "Burnt Umber"),
            PBNColor(red: 0.55, green: 0.27, blue: 0.14, name: "Burnt Sienna"),
            PBNColor(red: 0.60, green: 0.38, blue: 0.22, name: "Raw Sienna"),
            PBNColor(red: 0.50, green: 0.08, blue: 0.10, name: "Alizarin Crimson"),
            PBNColor(red: 0.80, green: 0.18, blue: 0.14, name: "Cadmium Red Pale"),
            PBNColor(red: 0.90, green: 0.45, blue: 0.10, name: "Cadmium Orange"),
            PBNColor(red: 0.78, green: 0.68, blue: 0.38, name: "Yellow Ochre"),
            PBNColor(red: 0.98, green: 0.88, blue: 0.30, name: "Cadmium Yellow Lt."),
            PBNColor(red: 0.22, green: 0.55, blue: 0.28, name: "Cadmium Green Pale"),
            PBNColor(red: 0.30, green: 0.48, blue: 0.32, name: "Cinnabar Green Med."),
            PBNColor(red: 0.16, green: 0.42, blue: 0.36, name: "Viridian"),
            PBNColor(red: 0.38, green: 0.60, blue: 0.78, name: "Cerulean Blue"),
            PBNColor(red: 0.14, green: 0.12, blue: 0.50, name: "Ultramarine Blue"),
        ]
    )

    /// All built-in palettes — the three canonical painter's palettes.
    static var builtIn: [PBNPalette] {
        [grisaille, zornPalette, classic]
    }

    // MARK: - Palette Utilities

    /// Luminance of a PBNColor using BT.601 weights.
    private static func luminance(of c: PBNColor) -> Double {
        0.299 * c.red + 0.587 * c.green + 0.114 * c.blue
    }

    /// Return a copy of this palette with colors sorted dark-to-light by luminance.
    func sortedByLuminance() -> PBNPalette {
        let sorted = colors.sorted { PBNPalette.luminance(of: $0) < PBNPalette.luminance(of: $1) }
        return PBNPalette(id: id, name: name, colors: sorted)
    }

    /// Whether the palette is already ordered dark-to-light.
    var isDarkToLight: Bool {
        for i in 1..<colors.count {
            if PBNPalette.luminance(of: colors[i]) < PBNPalette.luminance(of: colors[i - 1]) - 0.01 {
                return false
            }
        }
        return true
    }

    /// Expand (or contract) the palette to exactly `count` colors by interpolating
    /// between existing palette colors.
    static func expandedColors(from palette: PBNPalette, count: Int) -> [PBNColor] {
        guard !palette.colors.isEmpty else {
            return (0..<count).map { i in
                let gray = count > 1 ? Double(i) / Double(count - 1) : 0.5
                return PBNColor(red: gray, green: gray, blue: gray, name: "Region \(i + 1)")
            }
        }

        if count <= palette.colors.count {
            return Array(palette.colors.prefix(count))
        }

        let srcCount = palette.colors.count
        var result: [PBNColor] = []
        result.reserveCapacity(count)

        for i in 0..<count {
            let t = count > 1 ? Double(i) / Double(count - 1) : 0.0
            let srcPos = t * Double(srcCount - 1)
            let loIdx = min(Int(srcPos), srcCount - 1)
            let hiIdx = min(loIdx + 1, srcCount - 1)
            let frac = srcPos - Double(loIdx)

            let lo = palette.colors[loIdx]
            let hi = palette.colors[hiIdx]

            if loIdx == hiIdx || frac < 0.001 {
                result.append(PBNColor(
                    red: lo.red, green: lo.green, blue: lo.blue,
                    name: lo.name
                ))
            } else if frac > 0.999 {
                result.append(PBNColor(
                    red: hi.red, green: hi.green, blue: hi.blue,
                    name: hi.name
                ))
            } else {
                let r = lo.red + (hi.red - lo.red) * frac
                let g = lo.green + (hi.green - lo.green) * frac
                let b = lo.blue + (hi.blue - lo.blue) * frac
                let name = "\(lo.name)/\(hi.name)"
                result.append(PBNColor(red: r, green: g, blue: b, name: name))
            }
        }

        return result
    }

    /// Returns a palette with at least `count` colors by interpolating between existing colors.
    /// If the palette already has enough colors, returns the colors as-is.
    func expandedColors(toCount count: Int) -> [PBNColor] {
        guard count > colors.count, colors.count >= 2 else { return colors }

        var result: [PBNColor] = []
        let segments = colors.count - 1
        let colorsPerSegment = Double(count - 1) / Double(segments)

        for seg in 0..<segments {
            let c1 = colors[seg]
            let c2 = colors[seg + 1]
            let stepsInSeg = seg < segments - 1
                ? Int(ceil(colorsPerSegment))
                : count - result.count

            for step in 0..<stepsInSeg {
                let t = stepsInSeg > 1 ? Double(step) / Double(stepsInSeg) : 0
                let r = c1.red + (c2.red - c1.red) * t
                let g = c1.green + (c2.green - c1.green) * t
                let b = c1.blue + (c2.blue - c1.blue) * t
                let name = step == 0 ? c1.name : "\(c1.name)/\(c2.name) \(step)"
                result.append(PBNColor(red: r, green: g, blue: b, name: name))
            }
        }
        // Always include the last color
        if result.count < count {
            result.append(colors.last!)
        }
        // Trim to exact count
        return Array(result.prefix(count))
    }
}

// MARK: - PBNThresholdSet

/// The set of threshold boundaries that divide 0–255 into regions.
/// For N colors you need N-1 thresholds (the implicit boundaries are 0 and 255).
struct PBNThresholdSet: Codable, Equatable {
    /// Threshold values in ascending order, each 1–254.
    private(set) var thresholds: [Int]

    /// Number of regions = thresholds.count + 1
    var regionCount: Int { thresholds.count + 1 }

    init(thresholds: [Int]) {
        let clamped = thresholds.map { min(max($0, 1), 254) }
        self.thresholds = clamped.sorted()
    }

    /// Generate evenly-spaced thresholds for a given number of regions.
    static func evenlySpaced(regions: Int) -> PBNThresholdSet {
        guard regions >= 2 else { return PBNThresholdSet(thresholds: []) }
        let step = 256.0 / Double(regions)
        let values = (1..<regions).map { i in
            Int((Double(i) * step).rounded())
        }
        return PBNThresholdSet(thresholds: values)
    }

    /// Get the (lower, upper) bounds for region at index.
    /// Region 0 spans [0, thresholds[0]), region N spans [thresholds[N-1], 255].
    func bounds(for regionIndex: Int) -> (lower: Int, upper: Int) {
        let lower: Int
        let upper: Int

        if regionIndex <= 0 {
            lower = 0
        } else if regionIndex <= thresholds.count {
            lower = thresholds[regionIndex - 1]
        } else {
            lower = thresholds.last ?? 0
        }

        if regionIndex >= thresholds.count {
            upper = 255
        } else {
            upper = thresholds[regionIndex] - 1
        }

        return (lower: lower, upper: upper)
    }

    /// Update thresholds with validation.
    mutating func setThresholds(_ newValues: [Int]) {
        let clamped = newValues.map { min(max($0, 1), 254) }
        thresholds = clamped.sorted()
    }
}

// MARK: - PBNContourSettings

struct PBNContourSettings: Codable, Equatable {
    var lineWeight: Double       // 1–5 points
    var lineColor: PBNColor      // typically black
    var showContours: Bool = true // render boundary lines
    var showNumbers: Bool        // overlay region numbers
    var numberFontSize: Double   // 8–24
    var smoothing: Double        // 0–1 gaussian blur on contours

    static var `default`: PBNContourSettings {
        PBNContourSettings(
            lineWeight: 2.0,
            lineColor: PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
            showContours: true,
            showNumbers: true,
            numberFontSize: 12.0,
            smoothing: 0.3
        )
    }
}

// MARK: - PBNConfig

/// **Region count** is determined solely by `thresholds` (regionCount = thresholds + 1).
/// **Posterization** is a pre-processing step that quantizes the source grayscale into
/// discrete tonal bands *before* thresholding. It does NOT control the number of output
/// regions.
///
/// Complete configuration for a paint-by-numbers render.
struct PBNConfig: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var palette: PBNPalette
    var thresholds: PBNThresholdSet
    var contourSettings: PBNContourSettings
    /// Pre-processing: quantize grayscale to this many tonal levels before thresholding.
    /// 0 = no posterization (smooth input). 2–20 = reduce to N discrete tonal bands.
    /// This is independent of region count — it affects input smoothness, not output regions.
    var posterizationLevels: Int
    var blurRadius: Double        // 0–10 gaussian pre-blur for smoother regions

    // V2 pipeline settings
    var useKMeans: Bool = true
    var kMeansIterations: Int = 12
    var minFacetPixels: Int = 20
    var narrowStripPasses: Int = 3
    var restrictToPalette: Bool = true
    var bilateralPreFilter: Bool = true
    var bilateralRadius: Int = 5

    init(
        id: UUID = UUID(),
        name: String,
        palette: PBNPalette,
        thresholds: PBNThresholdSet,
        contourSettings: PBNContourSettings = .default,
        posterizationLevels: Int = 0,
        blurRadius: Double = 0
    ) {
        self.id = id
        self.name = name
        self.palette = palette
        self.thresholds = thresholds
        self.contourSettings = contourSettings
        self.posterizationLevels = min(max(posterizationLevels, 0), 20)
        self.blurRadius = min(max(blurRadius, 0), 10)
    }

    /// Default config: Classic PBN palette, 5 evenly-spaced regions, standard contour settings.
    static var `default`: PBNConfig {
        PBNConfig(
            name: "Classic PBN Default",
            palette: .classicPBN,
            thresholds: .evenlySpaced(regions: 5),
            contourSettings: .default,
            posterizationLevels: 0,
            blurRadius: 1.5
        )
    }
}

// MARK: - PBNRegion

/// A single identified region in the paint-by-numbers decomposition.
struct PBNRegion: Identifiable {
    let id: Int  // region index (0-based)
    let label: String  // "Region 1", "Region 2", etc.
    let color: PBNColor
    let thresholdBounds: (lower: Int, upper: Int)
    var isHighlighted: Bool = false
    /// Percentage of total image pixels in this region.
    var coveragePercent: Double = 0
    /// Color mixing recipe for this region (nil until PBNRecipeBuilder assigns one).
    var recipe: ColorMixRecipe?

    init(
        id: Int,
        label: String,
        color: PBNColor,
        thresholdBounds: (lower: Int, upper: Int),
        isHighlighted: Bool = false,
        coveragePercent: Double = 0
    ) {
        self.id = id
        self.label = label
        self.color = color
        self.thresholdBounds = thresholdBounds
        self.isHighlighted = isHighlighted
        self.coveragePercent = coveragePercent
    }

    /// Build regions from a config, pairing each threshold range with its palette color.
    static func regions(from config: PBNConfig) -> [PBNRegion] {
        let palette = config.palette
        let thresholds = config.thresholds
        let count = thresholds.regionCount

        let expandedColors = PBNPalette.expandedColors(from: palette, count: count)

        return (0..<count).map { index in
            let color = expandedColors[index]

            return PBNRegion(
                id: index,
                label: "Region \(index + 1)",
                color: color,
                thresholdBounds: thresholds.bounds(for: index)
            )
        }
    }
}

// MARK: - PBNDisplayMode

enum PBNDisplayMode: String, CaseIterable, Identifiable {
    case colorFill = "Color Fill"
    case contourOnly = "Contours Only"
    case numbered = "Numbered"
    case colorWithContour = "Color + Contour"
    case highlightRegion = "Highlight Region"
    case original = "Original"
    case sideBySide = "Side by Side"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .colorFill:        return "rectangle.fill"
        case .contourOnly:      return "square.dashed"
        case .numbered:         return "number.square"
        case .colorWithContour: return "rectangle.on.rectangle"
        case .highlightRegion:  return "target"
        case .original:         return "photo"
        case .sideBySide:       return "rectangle.split.2x1"
        }
    }
}

// MARK: - PBNExportFormat

enum PBNExportFormat: String, CaseIterable {
    case colorFillPNG = "Color Fill (PNG)"
    case contoursPNG = "Contours (PNG)"
    case numberedPNG = "Numbered (PNG)"
    case regionMaskPNG = "Region Mask (PNG)"
    case paletteSwatch = "Palette Swatch (PNG)"
    case fullKit = "Full Kit (ZIP)"
}

// MARK: - PBNPreset

/// A named preset configuration optimized for a specific artistic effect.
struct PBNPreset: Identifiable {
    let id: String
    let name: String
    let description: String
    let icon: String  // SF Symbol
    let config: PBNConfig

    // MARK: - All Presets

    static var presets: [PBNPreset] {
        [
            // Traditional drawing
            troisCrayonClassic,
            troisCrayonDetailed,
            charcoalStudy,
            sanguineSketch,
            sepiaPortrait,
            // Printmaking
            aquatintEtch,
            woodcutBold,
            // Paint-by-numbers
            classicPBN,
            kidsPBN,
            advancedPBN,
            // Tonal study
            highKey,
            lowKey,
            fullRange,
        ]
    }

    // MARK: - Traditional Drawing Presets

    /// Trois Crayon Classic — 5 regions, gentle blur softens transitions between
    /// charcoal, sanguine, and white chalk on toned paper.
    static let troisCrayonClassic = PBNPreset(
        id: "troisCrayonClassic",
        name: "Trois Crayon Classic",
        description: "Traditional trois crayon on toned paper with soft transitions",
        icon: "pencil.and.outline",
        config: PBNConfig(
            name: "Trois Crayon Classic",
            palette: .troisCrayon,
            // Thresholds cluster around the mid-darks where charcoal and sanguine meet
            thresholds: PBNThresholdSet(thresholds: [55, 110, 165, 210]),
            contourSettings: .default,
            posterizationLevels: 0,
            blurRadius: 2.0
        )
    )

    /// Trois Crayon Detailed — 8 regions with tight midtone thresholds that preserve
    /// subtle tonal shifts in the sanguine-to-chalk transition zone.
    static let troisCrayonDetailed = PBNPreset(
        id: "troisCrayonDetailed",
        name: "Trois Crayon Detailed",
        description: "Fine-grained trois crayon with tight midtone separation",
        icon: "pencil.and.outline",
        config: PBNConfig(
            name: "Trois Crayon Detailed",
            palette: .troisCrayon,
            // Packed tight in the 80-180 midtone range where sanguine detail lives
            thresholds: PBNThresholdSet(thresholds: [40, 80, 110, 135, 160, 185, 220]),
            contourSettings: PBNContourSettings(
                lineWeight: 1.5,
                lineColor: PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                showContours: true,
                showNumbers: true,
                numberFontSize: 10.0,
                smoothing: 0.2
            ),
            posterizationLevels: 0,
            blurRadius: 0
        )
    )

    /// Charcoal Study — 4 stark regions with heavy contrast separation. Thresholds
    /// push most tones into deep darks, capturing the dramatic weight of charcoal.
    static let charcoalStudy = PBNPreset(
        id: "charcoalStudy",
        name: "Charcoal Study",
        description: "Bold charcoal with heavy dark bias and dramatic contrast",
        icon: "scribble.variable",
        config: PBNConfig(
            name: "Charcoal Study",
            palette: PBNPalette(
                name: "Charcoal Dark",
                colors: [
                    PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                    PBNColor(red: 0.22, green: 0.22, blue: 0.22, name: "Deep Charcoal"),
                    PBNColor(red: 0.52, green: 0.52, blue: 0.52, name: "Mid Tone"),
                    PBNColor(red: 0.92, green: 0.90, blue: 0.88, name: "Paper White"),
                ]
            ),
            // Dark-biased: most of the image falls into shadow and deep charcoal
            thresholds: PBNThresholdSet(thresholds: [45, 100, 180]),
            contourSettings: PBNContourSettings(
                lineWeight: 2.5,
                lineColor: PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                showContours: true,
                showNumbers: true,
                numberFontSize: 12.0,
                smoothing: 0.4
            ),
            posterizationLevels: 0,
            blurRadius: 1.0
        )
    )

    /// Sanguine Sketch — 5 red-chalk regions with a gentle blur that evokes
    /// a life-drawing study in conte crayon.
    static let sanguineSketch = PBNPreset(
        id: "sanguineSketch",
        name: "Sanguine Sketch",
        description: "Warm red chalk tones with gentle softening",
        icon: "paintbrush.pointed",
        config: PBNConfig(
            name: "Sanguine Sketch",
            palette: .redSanguine,
            // Slightly shadow-biased for life-drawing feel
            thresholds: PBNThresholdSet(thresholds: [50, 105, 160, 210]),
            contourSettings: PBNContourSettings(
                lineWeight: 1.5,
                lineColor: PBNColor(red: 0.28, green: 0.06, blue: 0.06, name: "Deep Crimson"),
                showNumbers: true,
                numberFontSize: 11.0,
                smoothing: 0.3
            ),
            posterizationLevels: 0,
            blurRadius: 2.5
        )
    )

    /// Sepia Portrait — 6 warm sepia regions with fine thresholds clustered in the
    /// 100-200 range where skin tones live, giving nuanced face rendering.
    static let sepiaPortrait = PBNPreset(
        id: "sepiaPortrait",
        name: "Sepia Portrait",
        description: "Warm sepia with fine skin-tone separation for portraits",
        icon: "person.crop.rectangle",
        config: PBNConfig(
            name: "Sepia Portrait",
            palette: PBNPalette(
                name: "Sepia Portrait",
                colors: [
                    PBNColor(red: 0.16, green: 0.10, blue: 0.04, name: "Sepia Dark"),
                    PBNColor(red: 0.38, green: 0.24, blue: 0.12, name: "Sepia"),
                    PBNColor(red: 0.55, green: 0.38, blue: 0.22, name: "Sepia Medium"),
                    PBNColor(red: 0.72, green: 0.56, blue: 0.38, name: "Warm Tan"),
                    PBNColor(red: 0.86, green: 0.74, blue: 0.60, name: "Light Flesh"),
                    PBNColor(red: 0.94, green: 0.90, blue: 0.82, name: "Parchment"),
                ]
            ),
            // Skin-tone-focused: 3 of 5 thresholds land in the 100-200 zone
            thresholds: PBNThresholdSet(thresholds: [55, 110, 150, 190, 225]),
            contourSettings: PBNContourSettings(
                lineWeight: 1.5,
                lineColor: PBNColor(red: 0.30, green: 0.20, blue: 0.10, name: "Sepia Line"),
                showNumbers: true,
                numberFontSize: 10.0,
                smoothing: 0.25
            ),
            posterizationLevels: 0,
            blurRadius: 1.5
        )
    )

    // MARK: - Printmaking Presets

    /// Aquatint Etch — 8 cool gray regions with thin contours simulating
    /// an etched copper plate with aquatint grain.
    static let aquatintEtch = PBNPreset(
        id: "aquatintEtch",
        name: "Aquatint Etch",
        description: "Cool gray tonal etching with thin precise contours",
        icon: "square.grid.3x3",
        config: PBNConfig(
            name: "Aquatint Etch",
            palette: .coolGray,
            // Fine gradations with slight dark bias (aquatint builds tone from darks)
            thresholds: PBNThresholdSet(thresholds: [28, 58, 90, 122, 158, 195, 228]),
            contourSettings: PBNContourSettings(
                lineWeight: 1.0,
                lineColor: PBNColor(red: 0.08, green: 0.09, blue: 0.12, name: "Plate Black"),
                showNumbers: true,
                numberFontSize: 9.0,
                smoothing: 0.15
            ),
            posterizationLevels: 0,
            blurRadius: 0
        )
    )

    /// Woodcut Bold — 3 stark regions (black, mid gray, white) with thick contours
    /// and no numbers, evoking a bold relief print.
    static let woodcutBold = PBNPreset(
        id: "woodcutBold",
        name: "Woodcut Bold",
        description: "Bold 3-tone woodcut with thick outlines, no numbers",
        icon: "rectangle.split.3x1",
        config: PBNConfig(
            name: "Woodcut Bold",
            palette: PBNPalette(
                name: "Woodcut",
                colors: [
                    PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                    PBNColor(red: 0.48, green: 0.48, blue: 0.48, name: "Mid Gray"),
                    PBNColor(red: 1.0, green: 1.0, blue: 1.0, name: "White"),
                ]
            ),
            // Two thresholds splitting into shadow, mid, highlight
            thresholds: PBNThresholdSet(thresholds: [85, 170]),
            contourSettings: PBNContourSettings(
                lineWeight: 4.0,
                lineColor: PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                showContours: true,
                showNumbers: false,
                numberFontSize: 12.0,
                smoothing: 0.5
            ),
            posterizationLevels: 0,
            blurRadius: 1.0
        )
    )


    // MARK: - Paint-by-Numbers Presets

    /// Classic PBN — 10 bright, distinct colors with moderate posterization
    /// for clean region boundaries and numbered guides.
    static let classicPBN = PBNPreset(
        id: "classicPBN",
        name: "Classic PBN",
        description: "Traditional paint-by-numbers kit with 10 bold colors",
        icon: "paintpalette",
        config: PBNConfig(
            name: "Classic PBN",
            palette: .classicPBN,
            // Spread thresholds across full range for diverse color assignment
            thresholds: PBNThresholdSet(thresholds: [28, 55, 82, 108, 135, 162, 188, 215, 240]),
            contourSettings: PBNContourSettings(
                lineWeight: 2.0,
                lineColor: PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                showContours: true,
                showNumbers: true,
                numberFontSize: 12.0,
                smoothing: 0.3
            ),
            posterizationLevels: 8,
            blurRadius: 2.0
        )
    )

    /// Kids PBN — 5 large, simple regions with heavy posterization, thick lines,
    /// and large numbers for young artists.
    static let kidsPBN = PBNPreset(
        id: "kidsPBN",
        name: "Kids PBN",
        description: "Simple big regions with thick lines and large numbers for kids",
        icon: "face.smiling",
        config: PBNConfig(
            name: "Kids PBN",
            palette: PBNPalette(
                name: "Kids Colors",
                colors: Array(PBNPalette.classicPBN.colors.prefix(5))
            ),
            // Wide, even bands for simple shapes
            thresholds: PBNThresholdSet(thresholds: [50, 105, 160, 210]),
            contourSettings: PBNContourSettings(
                lineWeight: 3.5,
                lineColor: PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                showContours: true,
                showNumbers: true,
                numberFontSize: 18.0,
                smoothing: 0.5
            ),
            posterizationLevels: 4,
            blurRadius: 5.0
        )
    )

    /// Advanced PBN — 12 regions with extended palette, light posterization,
    /// and thin contours for experienced painters.
    static let advancedPBN = PBNPreset(
        id: "advancedPBN",
        name: "Advanced PBN",
        description: "12-color detailed kit for experienced painters",
        icon: "paintpalette.fill",
        config: PBNConfig(
            name: "Advanced PBN",
            palette: PBNPalette(
                name: "Extended PBN",
                colors: PBNPalette.classicPBN.colors + [
                    PBNColor(red: 0.40, green: 0.75, blue: 0.72, name: "Teal"),
                    PBNColor(red: 0.85, green: 0.72, blue: 0.52, name: "Gold"),
                ]
            ),
            // Tighter spacing in midtones for more detail in the interesting zones
            thresholds: PBNThresholdSet(thresholds: [22, 48, 72, 95, 118, 140, 162, 185, 208, 230, 246]),
            contourSettings: PBNContourSettings(
                lineWeight: 1.0,
                lineColor: PBNColor(red: 0.15, green: 0.15, blue: 0.15, name: "Dark Gray"),
                showNumbers: true,
                numberFontSize: 9.0,
                smoothing: 0.2
            ),
            posterizationLevels: 3,
            blurRadius: 1.0
        )
    )

    // MARK: - Tonal Study Presets

    /// High Key — 5 monochrome regions with thresholds biased toward highlights,
    /// capturing subtle differences in bright tones while compressing shadows.
    static let highKey = PBNPreset(
        id: "highKey",
        name: "High Key",
        description: "Highlight-biased tonal study — subtle bright-tone separation",
        icon: "sun.max",
        config: PBNConfig(
            name: "High Key",
            palette: .monochrome,
            // Shadows compressed into one region; highlights get fine detail
            thresholds: PBNThresholdSet(thresholds: [150, 180, 200, 230]),
            contourSettings: PBNContourSettings(
                lineWeight: 1.5,
                lineColor: PBNColor(red: 0.40, green: 0.40, blue: 0.40, name: "Mid Gray"),
                showNumbers: true,
                numberFontSize: 10.0,
                smoothing: 0.2
            ),
            posterizationLevels: 0,
            blurRadius: 1.0
        )
    )

    /// Low Key — 5 monochrome regions with thresholds biased toward shadows,
    /// revealing detail in dark tones while compressing highlights.
    static let lowKey = PBNPreset(
        id: "lowKey",
        name: "Low Key",
        description: "Shadow-biased tonal study — detail in the darks",
        icon: "moon.fill",
        config: PBNConfig(
            name: "Low Key",
            palette: .monochrome,
            // Highlights compressed; shadows get fine separation
            thresholds: PBNThresholdSet(thresholds: [30, 60, 90, 130]),
            contourSettings: PBNContourSettings(
                lineWeight: 1.5,
                lineColor: PBNColor(red: 0.70, green: 0.70, blue: 0.70, name: "Light Gray"),
                showNumbers: true,
                numberFontSize: 10.0,
                smoothing: 0.2
            ),
            posterizationLevels: 0,
            blurRadius: 1.0
        )
    )

    /// Full Range — 10 monochrome regions evenly spaced across the entire tonal
    /// range, no processing. A neutral reference for tonal analysis.
    static let fullRange = PBNPreset(
        id: "fullRange",
        name: "Full Range",
        description: "Even 10-zone tonal scale — neutral reference study",
        icon: "chart.bar",
        config: PBNConfig(
            name: "Full Range",
            palette: .monochrome,
            thresholds: .evenlySpaced(regions: 10),
            contourSettings: PBNContourSettings(
                lineWeight: 1.5,
                lineColor: PBNColor(red: 0.0, green: 0.0, blue: 0.0, name: "Black"),
                showContours: true,
                showNumbers: true,
                numberFontSize: 10.0,
                smoothing: 0.2
            ),
            posterizationLevels: 0,
            blurRadius: 0
        )
    )
}
