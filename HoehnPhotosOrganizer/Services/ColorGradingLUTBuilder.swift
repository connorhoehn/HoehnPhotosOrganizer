import Foundation

// MARK: - ColorGradingLUTBuilder

/// Builds a 32³ RGBA-float colour lookup table from the advanced PhotoAdjustments
/// that CIFilter chains cannot express cleanly:
///
///   1. HSL per-channel  (8 colour ranges × H/S/L delta)
///   2. Camera Calibration (primary R/G/B hue + saturation)
///   3. Color Balance  (per tonal zone R/G/B shift)
///   4. Color Grading  (per tonal zone H/S/L — Camera Raw–style)
///
/// The returned Data blob is passed directly to CIColorCubeWithColorSpace.
/// Apple's GPU-accelerated trilinear interpolation handles the rest.
struct ColorGradingLUTBuilder {

    static let dimension = 32   // 32³ = 32 768 samples; ample for smooth grading

    /// Returns true when all four sub-systems are at their identity values,
    /// letting the caller skip LUT construction entirely.
    static func isIdentity(_ adj: PhotoAdjustments) -> Bool {
        adj.hsl          == PhotoAdjustments.HSLAdjustments() &&
        adj.colorGrading == PhotoAdjustments.ColorGrading()   &&
        adj.colorBalance == PhotoAdjustments.ColorBalance()   &&
        adj.calibration  == PhotoAdjustments.Calibration()
    }

    // MARK: - LUT construction

    static func buildLUT(from adj: PhotoAdjustments) -> Data {
        let dim = dimension
        let floatCount = dim * dim * dim * 4
        var cube = [Float](repeating: 0.0, count: floatCount)

        for bi in 0..<dim {
            for gi in 0..<dim {
                for ri in 0..<dim {
                    let r = Float(ri) / Float(dim - 1)
                    let g = Float(gi) / Float(dim - 1)
                    let b = Float(bi) / Float(dim - 1)

                    // Convert to HSL for perceptual ops
                    var (h, s, l) = rgbToHSL(r, g, b)

                    // Step 1 — HSL per-channel
                    let d = hslChannelDelta(h: h, hsl: adj.hsl)
                    h = fmod(h + d.dh + 720.0, 360.0)
                    s = clamp01(s + d.ds)
                    l = clamp01(l + d.dl)

                    // Step 2 — Camera calibration (primary H/S shift)
                    let cal = calibrationResult(h: h, s: s, l: l, cal: adj.calibration)
                    h = cal.h; s = cal.s

                    var (rO, gO, bO) = hslToRGB(h, s, l)

                    // Step 3 — Color balance (per-zone RGB shift)
                    let lum = perceptualLum(rO, gO, bO)
                    let (sw, mw, hw) = zoneWeights(lum: lum)
                    let cb = adj.colorBalance
                    rO = clamp01(rO + (sw * Float(cb.shadows.red)   + mw * Float(cb.midtones.red)   + hw * Float(cb.highlights.red))   * 0.005)
                    gO = clamp01(gO + (sw * Float(cb.shadows.green) + mw * Float(cb.midtones.green) + hw * Float(cb.highlights.green)) * 0.005)
                    bO = clamp01(bO + (sw * Float(cb.shadows.blue)  + mw * Float(cb.midtones.blue)  + hw * Float(cb.highlights.blue))  * 0.005)

                    // Step 4 — Color grading (tonal-zone H/S/L)
                    if adj.colorGrading != PhotoAdjustments.ColorGrading() {
                        (rO, gO, bO) = applyColorGrading(rO, gO, bO, cg: adj.colorGrading)
                    }

                    // CIColorCubeWithColorSpace: blue index outermost, green middle, red innermost
                    let idx = (bi * dim * dim + gi * dim + ri) * 4
                    cube[idx]     = clamp01(rO)
                    cube[idx + 1] = clamp01(gO)
                    cube[idx + 2] = clamp01(bO)
                    cube[idx + 3] = 1.0
                }
            }
        }

        return Data(bytes: &cube, count: floatCount * MemoryLayout<Float>.size)
    }

    // MARK: - HSL per-channel

    private struct HslDelta { let dh: Float; let ds: Float; let dl: Float }

    private static func hslChannelDelta(h: Float, hsl: PhotoAdjustments.HSLAdjustments) -> HslDelta {
        typealias Ch = (adj: PhotoAdjustments.HSLChannel, center: Float, halfW: Float)
        let channels: [Ch] = [
            (hsl.red,     0.0,   40.0),
            (hsl.orange,  30.0,  40.0),
            (hsl.yellow,  60.0,  40.0),
            (hsl.green,   120.0, 55.0),
            (hsl.aqua,    180.0, 55.0),
            (hsl.blue,    240.0, 55.0),
            (hsl.purple,  300.0, 40.0),
            (hsl.magenta, 330.0, 40.0),
        ]
        var dh: Float = 0, ds: Float = 0, dl: Float = 0
        for ch in channels {
            let w = hueWeight(h: h, center: ch.center, halfW: ch.halfW)
            guard w > 0 else { continue }
            dh += w * Float(ch.adj.hue) * 1.8         // ±100 → ±180°
            ds += w * Float(ch.adj.saturation) * 0.01  // ±100 → ±1.0
            dl += w * Float(ch.adj.luminance)  * 0.005 // ±100 → ±0.5
        }
        return HslDelta(dh: dh, ds: ds, dl: dl)
    }

    /// Smooth cosine weight; zero at or beyond halfW degrees from center.
    private static func hueWeight(h: Float, center: Float, halfW: Float) -> Float {
        var diff = abs(h - center)
        if diff > 180 { diff = 360 - diff }
        guard diff < halfW else { return 0 }
        return 0.5 + 0.5 * cos(.pi * diff / halfW)
    }

    // MARK: - Camera calibration

    private static func calibrationResult(
        h: Float, s: Float, l: Float,
        cal: PhotoAdjustments.Calibration
    ) -> (h: Float, s: Float) {
        typealias PC = (adj: PhotoAdjustments.PrimaryCalibration, center: Float, halfW: Float)
        let primaries: [PC] = [
            (cal.red,   0.0,   55.0),
            (cal.green, 120.0, 70.0),
            (cal.blue,  240.0, 70.0),
        ]
        var dh: Float = 0, dsMul: Float = 0
        for p in primaries {
            let w = hueWeight(h: h, center: p.center, halfW: p.halfW)
            guard w > 0 else { continue }
            dh    += w * Float(p.adj.hue) * 1.8
            dsMul += w * Float(p.adj.saturation) * 0.01
        }
        return (fmod(h + dh + 720.0, 360.0), clamp01(s * (1.0 + dsMul)))
    }

    // MARK: - Zone weights

    /// Soft, normalised shadow / midtone / highlight weights for a given perceptual luminance.
    private static func zoneWeights(lum: Float) -> (Float, Float, Float) {
        let sw = clamp01(1.0 - lum * 2.5)                    // peaks at 0
        let hw = clamp01((lum - 0.6) * 2.5)                  // peaks at 1
        let mw = clamp01(1.0 - abs(lum - 0.5) * 2.5)         // peaks at 0.5
        let total = sw + mw + hw
        guard total > 1e-5 else { return (0.333, 0.334, 0.333) }
        return (sw / total, mw / total, hw / total)
    }

    // MARK: - Color grading

    private static func applyColorGrading(
        _ r: Float, _ g: Float, _ b: Float,
        cg: PhotoAdjustments.ColorGrading
    ) -> (Float, Float, Float) {
        let lum      = perceptualLum(r, g, b)
        let balShift = Float(cg.balance) * 0.002              // ±100 → ±0.2
        let blend    = max(0.1, Float(cg.blending) * 0.01)    // 0–100 → 0–1

        let sCentre: Float = 0.20 - balShift * 0.15
        let hCentre: Float = 0.80 + balShift * 0.15

        let sw = clamp01(smoothstep(sCentre + blend * 0.3, sCentre - blend * 0.1, lum))
        let hw = clamp01(smoothstep(hCentre - blend * 0.3, hCentre + blend * 0.1, lum))
        let mw = clamp01(1.0 - sw - hw)

        var (h, s, l) = rgbToHSL(r, g, b)

        // Saturation ±100 → ±0.5
        let dS = (sw * Float(cg.shadows.saturation) + mw * Float(cg.midtones.saturation) + hw * Float(cg.highlights.saturation)) * 0.005
        // Luminance ±100 → ±0.25
        let dL = (sw * Float(cg.shadows.luminance) + mw * Float(cg.midtones.luminance) + hw * Float(cg.highlights.luminance)) * 0.0025

        // Hue: blend toward zone colour only when the zone has saturation set
        var dH: Float = 0
        if cg.shadows.saturation    > 0 { dH += sw * hueDeltaToward(h, Float(cg.shadows.hue))    * 0.3 }
        if cg.midtones.saturation   > 0 { dH += mw * hueDeltaToward(h, Float(cg.midtones.hue))   * 0.3 }
        if cg.highlights.saturation > 0 { dH += hw * hueDeltaToward(h, Float(cg.highlights.hue)) * 0.3 }

        h = fmod(h + dH + 720.0, 360.0)
        s = clamp01(s + dS)
        l = clamp01(l + dL)

        return hslToRGB(h, s, l)
    }

    // MARK: - Colour math helpers

    private static func perceptualLum(_ r: Float, _ g: Float, _ b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func rgbToHSL(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let cMax = max(r, max(g, b))
        let cMin = min(r, min(g, b))
        let delta = cMax - cMin
        let l = (cMax + cMin) * 0.5
        guard delta > 1e-6 else { return (0, 0, l) }
        let s = delta / (1.0 - abs(2.0 * l - 1.0))
        let h: Float
        if      cMax == r { h = 60.0 * fmod((g - b) / delta, 6.0) }
        else if cMax == g { h = 60.0 * ((b - r) / delta + 2.0) }
        else              { h = 60.0 * ((r - g) / delta + 4.0) }
        return (fmod(h + 360.0, 360.0), clamp01(s), clamp01(l))
    }

    private static func hslToRGB(_ h: Float, _ s: Float, _ l: Float) -> (Float, Float, Float) {
        guard s > 1e-6 else { return (l, l, l) }
        let c  = (1.0 - abs(2.0 * l - 1.0)) * s
        let hh = h / 60.0
        let x  = c * (1.0 - abs(fmod(hh, 2.0) - 1.0))
        let m  = l - c * 0.5
        let (r1, g1, b1): (Float, Float, Float)
        switch Int(hh) % 6 {
        case 0:  (r1, g1, b1) = (c, x, 0)
        case 1:  (r1, g1, b1) = (x, c, 0)
        case 2:  (r1, g1, b1) = (0, c, x)
        case 3:  (r1, g1, b1) = (0, x, c)
        case 4:  (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        return (r1 + m, g1 + m, b1 + m)
    }

    private static func hueDeltaToward(_ from: Float, _ to: Float) -> Float {
        var d = to - from
        if d >  180 { d -= 360 }
        if d < -180 { d += 360 }
        return d
    }

    private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = clamp01((x - edge0) / (edge1 - edge0))
        return t * t * (3.0 - 2.0 * t)
    }

    private static func clamp01(_ v: Float) -> Float { max(0, min(1, v)) }
}
