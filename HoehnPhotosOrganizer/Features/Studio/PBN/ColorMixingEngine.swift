import Foundation

// MARK: - ColorMixRecipe

/// A mixing recipe that tells the painter how to reproduce a target color from palette pigments.
struct ColorMixRecipe: Codable, Equatable, Identifiable {
    let id: UUID
    let displayNumber: Int
    let components: [Component]
    let deltaE: Double
    let resultColor: PBNColor

    var isPure: Bool { components.count == 1 && components[0].fraction >= 0.95 }

    struct Component: Codable, Equatable {
        let paletteIndex: Int
        let colorName: String
        let fraction: Double
    }

    var canvasLabel: String { "\(displayNumber)" }

    var legendDescription: String {
        if isPure { return "\(displayNumber) = \(components[0].colorName)" }
        return "\(displayNumber) = " + components.map {
            "\(Int($0.fraction * 100))% \($0.colorName)"
        }.joined(separator: " + ")
    }
}

// MARK: - ColorMixingEngine

/// Kubelka-Munk color mixing engine with ΔE2000 evaluation.
/// Computes physically-plausible pigment mix recipes from a PBN palette.
final class ColorMixingEngine {

    // MARK: - sRGB ↔ Linear RGB

    func srgbToLinear(_ c: Double) -> Double {
        c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    func linearToSrgb(_ c: Double) -> Double {
        c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    // MARK: - Linear RGB ↔ XYZ (D65)

    /// sRGB to XYZ D65 matrix (IEC 61966-2-1)
    private func linearRGBToXYZ(r: Double, g: Double, b: Double) -> (x: Double, y: Double, z: Double) {
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        return (x, y, z)
    }

    private func xyzToLinearRGB(x: Double, y: Double, z: Double) -> (r: Double, g: Double, b: Double) {
        let r =  3.2404542 * x - 1.5371385 * y - 0.4985314 * z
        let g = -0.9692660 * x + 1.8760108 * y + 0.0415560 * z
        let b =  0.0556434 * x - 0.2040259 * y + 1.0572252 * z
        return (r, g, b)
    }

    // MARK: - XYZ ↔ CIELab

    private static let d65White = (x: 0.95047, y: 1.0, z: 1.08883)
    private static let labEpsilon: Double = 216.0 / 24389.0
    private static let labKappa: Double = 24389.0 / 27.0

    private func labF(_ t: Double) -> Double {
        t > Self.labEpsilon ? cbrt(t) : (Self.labKappa * t + 16.0) / 116.0
    }

    func xyzToLab(x: Double, y: Double, z: Double) -> (L: Double, a: Double, b: Double) {
        let fx = labF(x / Self.d65White.x)
        let fy = labF(y / Self.d65White.y)
        let fz = labF(z / Self.d65White.z)
        let L = 116.0 * fy - 16.0
        let a = 500.0 * (fx - fy)
        let b = 200.0 * (fy - fz)
        return (L, a, b)
    }

    func srgbToLab(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        let lr = srgbToLinear(r)
        let lg = srgbToLinear(g)
        let lb = srgbToLinear(b)
        let xyz = linearRGBToXYZ(r: lr, g: lg, b: lb)
        return xyzToLab(x: xyz.x, y: xyz.y, z: xyz.z)
    }

    // MARK: - ΔE2000 (CIEDE2000)

    /// Full CIEDE2000 color difference.
    func deltaE2000(
        L1: Double, a1: Double, b1: Double,
        L2: Double, a2: Double, b2: Double
    ) -> Double {
        let Lbar = (L1 + L2) / 2.0
        let C1 = sqrt(a1 * a1 + b1 * b1)
        let C2 = sqrt(a2 * a2 + b2 * b2)
        let Cbar = (C1 + C2) / 2.0

        let Cbar7 = pow(Cbar, 7.0)
        let G = 0.5 * (1.0 - sqrt(Cbar7 / (Cbar7 + pow(25.0, 7.0))))
        let a1p = a1 * (1.0 + G)
        let a2p = a2 * (1.0 + G)

        let C1p = sqrt(a1p * a1p + b1 * b1)
        let C2p = sqrt(a2p * a2p + b2 * b2)
        let Cbarp = (C1p + C2p) / 2.0

        var h1p = atan2(b1, a1p) * 180.0 / .pi
        if h1p < 0 { h1p += 360.0 }
        var h2p = atan2(b2, a2p) * 180.0 / .pi
        if h2p < 0 { h2p += 360.0 }

        var dHp: Double
        if abs(h1p - h2p) <= 180.0 {
            dHp = h2p - h1p
        } else if h2p <= h1p {
            dHp = h2p - h1p + 360.0
        } else {
            dHp = h2p - h1p - 360.0
        }

        let dLp = L2 - L1
        let dCp = C2p - C1p
        let dHpTerm = 2.0 * sqrt(C1p * C2p) * sin(dHp * .pi / 360.0)

        var Hbarp: Double
        if C1p * C2p == 0 {
            Hbarp = h1p + h2p
        } else if abs(h1p - h2p) <= 180.0 {
            Hbarp = (h1p + h2p) / 2.0
        } else if h1p + h2p < 360.0 {
            Hbarp = (h1p + h2p + 360.0) / 2.0
        } else {
            Hbarp = (h1p + h2p - 360.0) / 2.0
        }

        let T = 1.0
            - 0.17 * cos((Hbarp - 30.0) * .pi / 180.0)
            + 0.24 * cos((2.0 * Hbarp) * .pi / 180.0)
            + 0.32 * cos((3.0 * Hbarp + 6.0) * .pi / 180.0)
            - 0.20 * cos((4.0 * Hbarp - 63.0) * .pi / 180.0)

        let Lbar50sq = (Lbar - 50.0) * (Lbar - 50.0)
        let SL = 1.0 + 0.015 * Lbar50sq / sqrt(20.0 + Lbar50sq)
        let SC = 1.0 + 0.045 * Cbarp
        let SH = 1.0 + 0.015 * Cbarp * T

        let Cbarp7 = pow(Cbarp, 7.0)
        let RC = 2.0 * sqrt(Cbarp7 / (Cbarp7 + pow(25.0, 7.0)))
        let dTheta = 30.0 * exp(-pow((Hbarp - 275.0) / 25.0, 2.0))
        let RT = -sin(2.0 * dTheta * .pi / 180.0) * RC

        let valL = dLp / SL
        let valC = dCp / SC
        let valH = dHpTerm / SH

        return sqrt(valL * valL + valC * valC + valH * valH + RT * valC * valH)
    }

    /// Convenience: ΔE2000 between two sRGB colors.
    func deltaE2000(r1: Double, g1: Double, b1: Double,
                    r2: Double, g2: Double, b2: Double) -> Double {
        let lab1 = srgbToLab(r: r1, g: g1, b: b1)
        let lab2 = srgbToLab(r: r2, g: g2, b: b2)
        return deltaE2000(L1: lab1.L, a1: lab1.a, b1: lab1.b,
                          L2: lab2.L, a2: lab2.a, b2: lab2.b)
    }

    // MARK: - Kubelka-Munk Mixing

    /// Reflectance to K/S ratio (absorption / scattering).
    func reflectanceToKS(_ r: Double) -> Double {
        let r = max(0.001, min(0.999, r))
        return (1.0 - r) * (1.0 - r) / (2.0 * r)
    }

    /// K/S ratio back to reflectance.
    func ksToReflectance(_ ks: Double) -> Double {
        1.0 + ks - sqrt(ks * ks + 2.0 * ks)
    }

    /// Mix N pigments with weights in K/S space, per RGB channel.
    /// Pigment colors are in linear RGB (used as reflectance proxy).
    func kmMix(pigments: [(r: Double, g: Double, b: Double)],
               weights: [Double]) -> (r: Double, g: Double, b: Double) {
        guard !pigments.isEmpty, pigments.count == weights.count else {
            return (0.5, 0.5, 0.5)
        }

        var ksR = 0.0, ksG = 0.0, ksB = 0.0
        for i in pigments.indices {
            let w = weights[i]
            ksR += w * reflectanceToKS(pigments[i].r)
            ksG += w * reflectanceToKS(pigments[i].g)
            ksB += w * reflectanceToKS(pigments[i].b)
        }

        return (
            r: ksToReflectance(ksR),
            g: ksToReflectance(ksG),
            b: ksToReflectance(ksB)
        )
    }

    // MARK: - Recipe Computation

    /// Find the best mixing recipe for a target color from the given palette.
    /// Grid-searches singles, pairs (5% steps), and triples (10% steps).
    func findRecipe(target: PBNColor, palette: PBNPalette, maxComponents: Int = 3) -> ColorMixRecipe {
        let targetLinear = (
            r: srgbToLinear(target.red),
            g: srgbToLinear(target.green),
            b: srgbToLinear(target.blue)
        )
        let targetLab = srgbToLab(r: target.red, g: target.green, b: target.blue)

        let pigments: [(r: Double, g: Double, b: Double)] = palette.colors.map {
            (r: srgbToLinear($0.red), g: srgbToLinear($0.green), b: srgbToLinear($0.blue))
        }

        var bestDE = Double.greatestFiniteMagnitude
        var bestWeights: [Double] = []
        var bestIndices: [Int] = []

        let n = pigments.count

        // Helper: evaluate a candidate mix and update best if improved.
        func evaluate(indices: [Int], weights: [Double]) {
            let selected = indices.map { pigments[$0] }
            let mixed = kmMix(pigments: selected, weights: weights)
            let mixedSRGB = (
                r: linearToSrgb(mixed.r),
                g: linearToSrgb(mixed.g),
                b: linearToSrgb(mixed.b)
            )
            let de = deltaE2000(
                L1: targetLab.L, a1: targetLab.a, b1: targetLab.b,
                L2: srgbToLab(r: mixedSRGB.r, g: mixedSRGB.g, b: mixedSRGB.b).L,
                a2: srgbToLab(r: mixedSRGB.r, g: mixedSRGB.g, b: mixedSRGB.b).a,
                b2: srgbToLab(r: mixedSRGB.r, g: mixedSRGB.g, b: mixedSRGB.b).b
            )
            if de < bestDE {
                bestDE = de
                bestWeights = weights
                bestIndices = indices
            }
        }

        // 1. Singles
        for i in 0..<n {
            evaluate(indices: [i], weights: [1.0])
        }

        // 2. Pairs (5% steps)
        if maxComponents >= 2 {
            for i in 0..<n {
                for j in (i + 1)..<n {
                    var w = 0.05
                    while w <= 0.95 + 1e-9 {
                        evaluate(indices: [i, j], weights: [w, 1.0 - w])
                        w += 0.05
                    }
                }
            }
        }

        // 3. Triples (10% steps, sum to 1)
        if maxComponents >= 3 {
            for i in 0..<n {
                for j in (i + 1)..<n {
                    for k in (j + 1)..<n {
                        var w1 = 0.1
                        while w1 <= 0.8 + 1e-9 {
                            var w2 = 0.1
                            while w2 <= (1.0 - w1 - 0.1 + 1e-9) {
                                let w3 = 1.0 - w1 - w2
                                if w3 >= 0.1 - 1e-9 {
                                    evaluate(indices: [i, j, k], weights: [w1, w2, w3])
                                }
                                w2 += 0.1
                            }
                            w1 += 0.1
                        }
                    }
                }
            }
        }

        // Round weights to nearest 5% and re-normalize
        let rounded = roundWeights(bestWeights)

        // Compute the actual mixed result color with rounded weights
        let finalPigments = bestIndices.map { pigments[$0] }
        let finalMixed = kmMix(pigments: finalPigments, weights: rounded)
        let finalSRGB = (
            r: max(0, min(1, linearToSrgb(finalMixed.r))),
            g: max(0, min(1, linearToSrgb(finalMixed.g))),
            b: max(0, min(1, linearToSrgb(finalMixed.b)))
        )

        let resultColor = PBNColor(
            red: finalSRGB.r, green: finalSRGB.g, blue: finalSRGB.b,
            name: "Mix"
        )

        let components = zip(bestIndices, rounded).map { idx, w in
            ColorMixRecipe.Component(
                paletteIndex: idx,
                colorName: palette.colors[idx].name,
                fraction: w
            )
        }

        return ColorMixRecipe(
            id: UUID(),
            displayNumber: 0, // assigned later by RecipeBuilder
            components: components,
            deltaE: bestDE,
            resultColor: resultColor
        )
    }

    // MARK: - Weight Rounding

    /// Round each weight to the nearest 5%, then re-normalize so they sum to 1.0.
    private func roundWeights(_ weights: [Double]) -> [Double] {
        guard !weights.isEmpty else { return weights }

        var rounded = weights.map { (($0 * 20.0).rounded() / 20.0) }

        // Ensure no weight is zero after rounding (minimum 5%)
        for i in rounded.indices {
            if rounded[i] < 0.05 { rounded[i] = 0.05 }
        }

        let sum = rounded.reduce(0, +)
        if sum > 0 {
            rounded = rounded.map { $0 / sum }
        }
        return rounded
    }
}
