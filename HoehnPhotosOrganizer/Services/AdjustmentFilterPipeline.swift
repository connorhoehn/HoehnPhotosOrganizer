import CoreImage
import Foundation

// MARK: - AdjustmentFilterPipeline

/// Shared, static filter helpers for the Camera Raw-quality adjustment pipeline.
/// Used by both DevelopView and AdjustmentPanelView to ensure identical rendering.
struct AdjustmentFilterPipeline {

    // MARK: - Full Filter Chain

    /// Complete adjustment filter chain used for per-layer rendering.
    /// Mirrors the global chain order so layers get the same quality pipeline.
    static func applyFilterChain(_ input: CIImage, adjustments mAdj: PhotoAdjustments) -> CIImage {
        var mci = input

        // Temperature/Tint
        mci = applyTemperatureTint(mci, temperature: mAdj.temperature, tint: mAdj.tint)

        // Exposure
        if abs(Double(mAdj.exposure)) > 0.01 {
            let f = CIFilter(name: "CIExposureAdjust")!
            f.setValue(mci, forKey: kCIInputImageKey)
            f.setValue(Float(mAdj.exposure), forKey: "inputEV")
            if let out = f.outputImage { mci = out }
        }

        // Contrast + Saturation
        let mc = Float(1.0 + Double(mAdj.contrast) / 667.0)
        let ms = Float(max(0, 1.0 + Double(mAdj.saturation) / 100.0))
        if abs(mc - 1) > 0.005 || abs(ms - 1) > 0.005 {
            let f = CIFilter(name: "CIColorControls")!
            f.setValue(mci, forKey: kCIInputImageKey)
            f.setValue(mc, forKey: kCIInputContrastKey)
            f.setValue(ms, forKey: kCIInputSaturationKey)
            if let out = f.outputImage { mci = out }
        }

        // Vibrance
        if mAdj.vibrance != 0, let f = CIFilter(name: "CIVibrance") {
            f.setValue(mci, forKey: kCIInputImageKey)
            f.setValue(Float(mAdj.vibrance) / 100.0, forKey: "inputAmount")
            if let out = f.outputImage { mci = out }
        }

        // Highlights/Shadows
        mci = applyHighlightsShadows(mci, highlights: mAdj.highlights, shadows: mAdj.shadows)

        // Whites/Blacks
        mci = applyWhitesBlacks(mci, whites: mAdj.whites, blacks: mAdj.blacks)

        // Dehaze
        mci = applyDehaze(mci, amount: mAdj.dehaze)

        // Clarity
        mci = applyClarity(mci, amount: mAdj.clarity)

        return mci
    }

    // MARK: - Temperature & Tint

    /// CITemperatureAndTint: map temperature -100..+100 to 3000K..10000K (neutral 6500K).
    /// Tint maps -100..+100 to green/magenta shift on targetNeutral.
    static func applyTemperatureTint(_ ci: CIImage, temperature: Double, tint: Double) -> CIImage {
        guard abs(Double(temperature)) > 0.5 || abs(Double(tint)) > 0.5 else { return ci }
        guard let f = CIFilter(name: "CITemperatureAndTint") else { return ci }
        // Map slider -100..+100 to Kelvin offset: neutral is 6500K, range 3000K..10000K
        let kelvin = 6500.0 + temperature * 35.0  // -100->3000, +100->10000
        let tintVal = tint * 1.0  // -100..+100 maps to green(-)/magenta(+) shift
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: CGFloat(kelvin), y: 0), forKey: "inputNeutral")
        f.setValue(CIVector(x: 6500, y: CGFloat(tintVal)), forKey: "inputTargetNeutral")
        return f.outputImage ?? ci
    }

    // MARK: - Highlights & Shadows

    /// Luminance-preserving highlight/shadow recovery using tone curve control points.
    /// Instead of CIHighlightShadowAdjust (which clips), this computes a smooth
    /// spline that compresses highlights or lifts shadows gradually.
    static func applyHighlightsShadows(_ ci: CIImage, highlights: Int, shadows: Int) -> CIImage {
        guard highlights != 0 || shadows != 0 else { return ci }

        let hNorm = Float(highlights) / 100.0  // -1..+1
        let sNorm = Float(shadows) / 100.0     // -1..+1

        // Shadow lift: raise the lower quarter of the curve
        let p0y: Float = max(0, sNorm * 0.15)                 // black point lift
        let p1y: Float = 0.25 + sNorm * 0.08                  // quarter-tone lift

        // Highlight recovery: compress the upper quarter
        let p3y: Float = 0.75 + hNorm * 0.08                  // three-quarter pull
        let p4y: Float = min(1.0, 1.0 + hNorm * 0.15)         // white point pull

        let f = CIFilter(name: "CIToneCurve")!
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: 0,    y: CGFloat(p0y)), forKey: "inputPoint0")
        f.setValue(CIVector(x: 0.25, y: CGFloat(p1y)), forKey: "inputPoint1")
        f.setValue(CIVector(x: 0.5,  y: 0.5),          forKey: "inputPoint2")
        f.setValue(CIVector(x: 0.75, y: CGFloat(p3y)), forKey: "inputPoint3")
        f.setValue(CIVector(x: 1.0,  y: CGFloat(p4y)), forKey: "inputPoint4")
        return f.outputImage ?? ci
    }

    // MARK: - Whites & Blacks

    /// Non-linear tone curve with smoother endpoint gradation for finer
    /// tonal separation near blacks and whites.
    static func applyWhitesBlacks(_ ci: CIImage, whites: Int, blacks: Int) -> CIImage {
        guard whites != 0 || blacks != 0 else { return ci }

        let bNorm = Float(blacks) / 100.0
        let wNorm = Float(whites) / 100.0

        let bO = bNorm * 0.06
        let wO = 1.0 + wNorm * 0.06

        let range = wO - bO
        let q1 = bO + 0.25 * range + bNorm * 0.01   // slight toe near blacks
        let mid = bO + 0.50 * range
        let q3 = bO + 0.75 * range + wNorm * 0.01   // slight shoulder near whites

        let f = CIFilter(name: "CIToneCurve")!
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: 0,    y: CGFloat(bO)),  forKey: "inputPoint0")
        f.setValue(CIVector(x: 0.25, y: CGFloat(q1)),  forKey: "inputPoint1")
        f.setValue(CIVector(x: 0.5,  y: CGFloat(mid)), forKey: "inputPoint2")
        f.setValue(CIVector(x: 0.75, y: CGFloat(q3)),  forKey: "inputPoint3")
        f.setValue(CIVector(x: 1.0,  y: CGFloat(wO)),  forKey: "inputPoint4")
        return f.outputImage ?? ci
    }

    // MARK: - Custom Tone Curve (interactive)

    /// Apply user-defined tone curve control points via CIToneCurve (5-point spline).
    /// Points should be sorted by input. We sample up to 5 evenly spaced points
    /// from the user's curve for the CIToneCurve filter.
    static func applyCurvePoints(_ ci: CIImage, points: [CurvePoint]) -> CIImage {
        guard points.count >= 2 else { return ci }

        // CIToneCurve accepts exactly 5 points. Sample from user points.
        let normalized = sampleFivePoints(from: points)

        let f = CIFilter(name: "CIToneCurve")!
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(CIVector(x: CGFloat(normalized[0].0), y: CGFloat(normalized[0].1)), forKey: "inputPoint0")
        f.setValue(CIVector(x: CGFloat(normalized[1].0), y: CGFloat(normalized[1].1)), forKey: "inputPoint1")
        f.setValue(CIVector(x: CGFloat(normalized[2].0), y: CGFloat(normalized[2].1)), forKey: "inputPoint2")
        f.setValue(CIVector(x: CGFloat(normalized[3].0), y: CGFloat(normalized[3].1)), forKey: "inputPoint3")
        f.setValue(CIVector(x: CGFloat(normalized[4].0), y: CGFloat(normalized[4].1)), forKey: "inputPoint4")
        return f.outputImage ?? ci
    }

    /// Produce exactly 5 (x, y) pairs in 0…1 range from an arbitrary number of curve points.
    /// Uses Catmull-Rom interpolation to evaluate the user curve at 5 evenly spaced x positions.
    private static func sampleFivePoints(from pts: [CurvePoint]) -> [(Double, Double)] {
        let sorted = pts.sorted { $0.input < $1.input }

        // Target x positions for the 5 CIToneCurve control points
        let targets: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

        return targets.map { tx in
            let xVal = tx * 255.0
            // Find surrounding points
            let y = interpolateCatmullRom(x: xVal, points: sorted)
            return (tx, max(0, min(1, y / 255.0)))
        }
    }

    /// Catmull-Rom interpolation at a given x value through sorted curve points.
    private static func interpolateCatmullRom(x: Double, points: [CurvePoint]) -> Double {
        guard points.count >= 2 else { return x }

        // Clamp to range
        if x <= Double(points.first!.input) { return Double(points.first!.output) }
        if x >= Double(points.last!.input) { return Double(points.last!.output) }

        // Find segment
        var segIdx = 0
        for i in 0..<(points.count - 1) {
            if x >= Double(points[i].input) && x <= Double(points[i + 1].input) {
                segIdx = i
                break
            }
        }

        let p0 = segIdx > 0 ? points[segIdx - 1] : points[segIdx]
        let p1 = points[segIdx]
        let p2 = points[segIdx + 1]
        let p3 = segIdx + 2 < points.count ? points[segIdx + 2] : points[segIdx + 1]

        let range = Double(p2.input - p1.input)
        guard range > 0 else { return Double(p1.output) }
        let t = (x - Double(p1.input)) / range

        let y0 = Double(p0.output), y1 = Double(p1.output)
        let y2 = Double(p2.output), y3 = Double(p3.output)

        // Catmull-Rom spline
        let a = -0.5 * y0 + 1.5 * y1 - 1.5 * y2 + 0.5 * y3
        let b = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3
        let c = -0.5 * y0 + 0.5 * y2
        let d = y1

        return a * t * t * t + b * t * t + c * t + d
    }

    // MARK: - Clarity

    /// Local contrast enhancement via CIUnsharpMask with large radius.
    /// Standard approach used in Lightroom/Camera Raw — large radius (30px),
    /// low intensity, blended proportionally to the clarity amount.
    static func applyClarity(_ ci: CIImage, amount: Double) -> CIImage {
        guard abs(Double(amount)) > 0.5 else { return ci }
        guard let f = CIFilter(name: "CIUnsharpMask") else { return ci }
        let radius: Double = 30.0
        let intensity: Double = abs(Double(amount)) / 100.0 * 0.6  // max 0.6 to avoid halos
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(radius, forKey: kCIInputRadiusKey)
        f.setValue(intensity, forKey: kCIInputIntensityKey)
        guard let sharpened = f.outputImage else { return ci }

        if amount > 0 {
            return sharpened
        } else {
            // Negative clarity: blend with a blurred version for softness
            let blurred = ci.applyingGaussianBlur(sigma: 10.0 * abs(Double(amount)) / 100.0)
                .cropped(to: ci.extent)
            return blurred
        }
    }

    // MARK: - Dehaze

    /// Combination of shadow-region contrast boost + saturation increase.
    /// Positive values cut haze; negative adds atmospheric effect.
    static func applyDehaze(_ ci: CIImage, amount: Double) -> CIImage {
        guard abs(Double(amount)) > 0.5 else { return ci }
        let norm = Float(amount) / 100.0

        let contrastBoost = Float(1.0 + Double(norm) * 0.15)
        let satBoost = Float(max(0.3, 1.0 + Double(norm) * 0.12))

        guard let f = CIFilter(name: "CIColorControls") else { return ci }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(contrastBoost, forKey: kCIInputContrastKey)
        f.setValue(satBoost, forKey: kCIInputSaturationKey)
        f.setValue(Float(0), forKey: kCIInputBrightnessKey)
        guard let boosted = f.outputImage else { return ci }

        // For positive dehaze, also deepen the black point to cut haze
        if norm > 0.05 {
            let blackLift = norm * 0.03
            let tc = CIFilter(name: "CIToneCurve")!
            tc.setValue(boosted, forKey: kCIInputImageKey)
            tc.setValue(CIVector(x: 0,    y: CGFloat(-blackLift)), forKey: "inputPoint0")
            tc.setValue(CIVector(x: 0.15, y: CGFloat(0.15)),       forKey: "inputPoint1")
            tc.setValue(CIVector(x: 0.5,  y: 0.5),                 forKey: "inputPoint2")
            tc.setValue(CIVector(x: 0.85, y: 0.85),                forKey: "inputPoint3")
            tc.setValue(CIVector(x: 1.0,  y: 1.0),                 forKey: "inputPoint4")
            return tc.outputImage ?? boosted
        }
        return boosted
    }
}
