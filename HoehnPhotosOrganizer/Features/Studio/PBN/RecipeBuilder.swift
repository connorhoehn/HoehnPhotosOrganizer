import Foundation

// MARK: - PBNNumberAssignment

/// Maps each color index from k-means to a display-number + mixing recipe.
struct PBNNumberAssignment {
    let recipeByColorIndex: [Int: ColorMixRecipe]

    var legendEntries: [ColorMixRecipe] {
        recipeByColorIndex.values.sorted { $0.displayNumber < $1.displayNumber }
    }
}

// MARK: - PBNRecipeBuilder

/// Assigns display numbers and computes K-M mixing recipes for all k-means color centers.
///
/// Pure palette matches (ΔE < 2.0) get the palette's 1-based index as their display number.
/// Mixed colors get numbers starting at palette.count + 1, ordered by descending coverage.
final class PBNRecipeBuilder {

    private let engine = ColorMixingEngine()

    /// The ΔE2000 threshold below which a center is considered a pure palette match.
    private let pureMatchThreshold: Double = 2.0

    /// Assign display numbers and compute recipes for all k-means centers.
    ///
    /// - Parameters:
    ///   - centers: RGB tuples (0-1 sRGB) for each k-means cluster center.
    ///   - palette: The PBN palette to match/mix against.
    ///   - facetCoverage: Maps colorIndex to its coverage percentage (0-100).
    /// - Returns: A `PBNNumberAssignment` with recipes keyed by color index.
    func assignNumbers(
        centers: [(r: Double, g: Double, b: Double)],
        palette: PBNPalette,
        facetCoverage: [Int: Double]
    ) -> PBNNumberAssignment {
        guard !centers.isEmpty, !palette.colors.isEmpty else {
            return PBNNumberAssignment(recipeByColorIndex: [:])
        }

        // Step 1: For each center, find closest palette color by ΔE2000
        struct CenterInfo {
            let colorIndex: Int
            let center: (r: Double, g: Double, b: Double)
            let closestPaletteIndex: Int
            let closestDeltaE: Double
        }

        var infos: [CenterInfo] = []
        for (idx, center) in centers.enumerated() {
            var bestPaletteIdx = 0
            var bestDE = Double.greatestFiniteMagnitude

            for (pIdx, pColor) in palette.colors.enumerated() {
                let de = engine.deltaE2000(
                    r1: center.r, g1: center.g, b1: center.b,
                    r2: pColor.red, g2: pColor.green, b2: pColor.blue
                )
                if de < bestDE {
                    bestDE = de
                    bestPaletteIdx = pIdx
                }
            }

            infos.append(CenterInfo(
                colorIndex: idx,
                center: center,
                closestPaletteIndex: bestPaletteIdx,
                closestDeltaE: bestDE
            ))
        }

        var recipeMap: [Int: ColorMixRecipe] = [:]

        // Track which palette indices have been claimed by pure matches
        // to avoid duplicate display numbers.
        var claimedPaletteIndices: Set<Int> = []

        // Step 2: Pure matches — ΔE < threshold
        // If multiple centers match the same palette color, pick the one with lowest ΔE.
        // Group by closest palette index first.
        var pureByPalette: [Int: [CenterInfo]] = [:]
        var mixCandidates: [CenterInfo] = []

        for info in infos {
            if info.closestDeltaE < pureMatchThreshold {
                pureByPalette[info.closestPaletteIndex, default: []].append(info)
            } else {
                mixCandidates.append(info)
            }
        }

        // For each palette slot, the best matching center gets the pure number;
        // others become mix candidates.
        for (paletteIdx, candidates) in pureByPalette {
            let sorted = candidates.sorted { $0.closestDeltaE < $1.closestDeltaE }
            let winner = sorted[0]
            claimedPaletteIndices.insert(paletteIdx)

            let pureColor = palette.colors[paletteIdx]
            let displayNumber = paletteIdx + 1 // 1-based

            recipeMap[winner.colorIndex] = ColorMixRecipe(
                id: UUID(),
                displayNumber: displayNumber,
                components: [
                    ColorMixRecipe.Component(
                        paletteIndex: paletteIdx,
                        colorName: pureColor.name,
                        fraction: 1.0
                    )
                ],
                deltaE: winner.closestDeltaE,
                resultColor: PBNColor(
                    red: pureColor.red, green: pureColor.green, blue: pureColor.blue,
                    name: pureColor.name
                )
            )

            // Remaining candidates for this palette slot become mixes
            for i in 1..<sorted.count {
                mixCandidates.append(sorted[i])
            }
        }

        // Step 3: Compute mix recipes for non-pure centers
        // Sort by coverage descending to assign lower numbers to larger regions.
        let sortedMixes = mixCandidates.sorted {
            (facetCoverage[$0.colorIndex] ?? 0) > (facetCoverage[$1.colorIndex] ?? 0)
        }

        var nextMixNumber = palette.colors.count + 1

        for info in sortedMixes {
            let targetColor = PBNColor(
                red: info.center.r, green: info.center.g, blue: info.center.b,
                name: "Target"
            )

            var recipe = engine.findRecipe(target: targetColor, palette: palette)

            // Reassign with correct display number
            recipe = ColorMixRecipe(
                id: recipe.id,
                displayNumber: nextMixNumber,
                components: recipe.components,
                deltaE: recipe.deltaE,
                resultColor: recipe.resultColor
            )

            recipeMap[info.colorIndex] = recipe
            nextMixNumber += 1
        }

        return PBNNumberAssignment(recipeByColorIndex: recipeMap)
    }
}
