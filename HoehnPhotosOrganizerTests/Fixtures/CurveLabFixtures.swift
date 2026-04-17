// CurveLabFixtures.swift
// HoehnPhotosOrganizerTests
//
// Reusable test fixtures for PrintLab/CurveLab feature tests.
// Provides deterministic .quad file content, SpyderPRINT measurement data,
// curve helpers, PPD content, and ink channel builders.

import Foundation
@testable import HoehnPhotosOrganizer

// MARK: - Quad File Content Strings

/// Simple linear K-only .quad: K channel has a linear ramp 0-29695 in 256 steps,
/// other 7 channels all zeros. Useful for verifying basic QTRFileParser round-trip.
let testLinearKOnlyQuad: String = {
    var lines: [String] = []
    lines.append("## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK")
    lines.append("# Linear K curve max black value = 100")

    // K channel: linear ramp
    lines.append("# K curve")
    let kValues = buildLinearRamp(count: 256, maxValue: 29695)
    for v in kValues {
        lines.append("\(v)")
    }

    // C, M, Y, LC, LM, LK, LLK channels: all zeros
    let zeroChannelNames = ["C", "M", "Y", "LC", "LM", "LK", "LLK"]
    for name in zeroChannelNames {
        lines.append("# \(name) Curve")
        for _ in 0..<256 {
            lines.append("0")
        }
    }

    return lines.joined(separator: "\n")
}()

/// Multi-linearization cyanotype .quad with realistic non-linear K curve data
/// and 5 linearization history entries. C channel has non-zero values.
/// Tests linearization history parsing and multi-channel active detection.
let testCyanotypeMultiLinQuad: String = {
    var lines: [String] = []
    lines.append("## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK")
    lines.append("# Black and White Mastery QuadToneProfiler v3")
    lines.append("# Cyanotype on Arches Platine")
    lines.append("# Linearized from measurement file: CyanoArches_meas_01.txt")
    lines.append("# and input quad file: CyanoArches_base.quad")
    lines.append("# Linearized from measurement file: CyanoArches_meas_02.txt")
    lines.append("# and input quad file: CyanoArches_lin01.quad")
    lines.append("# Linearized from measurement file: CyanoArches_meas_03.txt")
    lines.append("# and input quad file: CyanoArches_lin02.quad")
    lines.append("# Linearized from measurement file: CyanoArches_meas_04.txt")
    lines.append("# and input quad file: CyanoArches_lin03.quad")
    lines.append("# Linearized from measurement file: CyanoArches_meas_05.txt")
    lines.append("# and input quad file: CyanoArches_lin04.quad")

    // K channel: first 30 values = 0, then non-linear accelerating ramp to ~15834
    lines.append("# K curve")
    let kValues = buildCyanotypeKCurve(count: 256)
    for v in kValues {
        lines.append("\(v)")
    }

    // C channel: non-zero values from index 0 (typical for cyanotype toning)
    lines.append("# C Curve")
    let cValues = buildCyanotypeCCurve(count: 256)
    for v in cValues {
        lines.append("\(v)")
    }

    // M, Y, LC, LM, LK, LLK channels: all zeros
    let zeroChannelNames = ["M", "Y", "LC", "LM", "LK", "LLK"]
    for name in zeroChannelNames {
        lines.append("# \(name) Curve")
        for _ in 0..<256 {
            lines.append("0")
        }
    }

    return lines.joined(separator: "\n")
}()

/// DTP-style single-ink photogravure quad with only K active.
/// Linear ramp 0-29695 step ~116 per entry.
let testDTPPhotogravureQuad: String = {
    var lines: [String] = []
    lines.append("## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK")
    lines.append("# DTP Photogravure Single Ink")
    lines.append("# max density = 100")

    // K channel: linear ramp (same as linear K-only but with DTP header)
    lines.append("# K curve")
    let kValues = buildLinearRamp(count: 256, maxValue: 29695)
    for v in kValues {
        lines.append("\(v)")
    }

    // Other channels: zeros
    let zeroChannelNames = ["C", "M", "Y", "LC", "LM", "LK", "LLK"]
    for name in zeroChannelNames {
        lines.append("# \(name) Curve")
        for _ in 0..<256 {
            lines.append("0")
        }
    }

    return lines.joined(separator: "\n")
}()

/// Invalid .quad content: missing channel markers, garbage text mixed with numbers.
/// Should cause QTRFileParser to produce empty/padded channels without crashing.
let testMalformedQuad: String = """
    This is not a valid quad file
    GARBAGE TEXT HERE
    12345
    some more nonsense
    ## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK
    not a channel marker
    999
    888
    another garbage line with special chars !@#$%
    777
    """

/// Empty .quad: just a header line with no channel data.
/// Parser should produce 8 channels of 256 zeros each.
let testEmptyQuad: String = """
    ## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK
    """

// MARK: - SpyderPRINT Measurement Content Strings

/// 21-step measurement with proper header. L* goes monotonically from
/// ~95.2 (paper white) down to ~5.1 (Dmax). Typical platinum/palladium target.
let testMeasurement21Steps: String = {
    var lines: [String] = []
    lines.append("QuadToneProfiler Measurement Data File")
    lines.append("Step\tL*\ta*\tb*")

    // 21 steps: paper white (95.2) -> Dmax (5.1)
    // L* drops monotonically; a* hovers near 0 (slight warm), b* slight yellow bias
    let lStarValues: [Double] = [
        95.20, 90.83, 86.41, 81.94, 77.40,
        72.78, 68.07, 63.25, 58.32, 53.27,
        48.10, 42.80, 37.38, 31.84, 26.21,
        20.52, 16.89, 13.44, 10.62,  7.71,
         5.10
    ]
    let aStarValues: [Double] = [
         0.12,  0.15,  0.18,  0.22,  0.25,
         0.30,  0.35,  0.41,  0.47,  0.52,
         0.58,  0.63,  0.67,  0.70,  0.72,
         0.74,  0.75,  0.76,  0.76,  0.77,
         0.77
    ]
    let bStarValues: [Double] = [
         1.80,  1.95,  2.12,  2.30,  2.50,
         2.72,  2.95,  3.18,  3.42,  3.65,
         3.87,  4.07,  4.24,  4.38,  4.48,
         4.54,  4.57,  4.58,  4.58,  4.57,
         4.55
    ]

    for i in 0..<21 {
        let step = i + 1
        lines.append("\(step)\t\(String(format: "%.2f", lStarValues[i]))\t\(String(format: "%.2f", aStarValues[i]))\t\(String(format: "%.2f", bStarValues[i]))")
    }

    return lines.joined(separator: "\n")
}()

/// 21-step measurement with a reversal at step 12 (L* jumps UP by 3.0)
/// and flat zone at steps 18-20 (L* barely changes). Tests anomaly detection.
let testMeasurementWithReversals: String = {
    var lines: [String] = []
    lines.append("QuadToneProfiler Measurement Data File")
    lines.append("Step\tL*\ta*\tb*")

    // Base monotonic L* values
    var lStarValues: [Double] = [
        95.20, 90.83, 86.41, 81.94, 77.40,
        72.78, 68.07, 63.25, 58.32, 53.27,
        48.10, 42.80, 37.38, 31.84, 26.21,
        20.52, 16.89, 13.44, 10.62,  7.71,
         5.10
    ]
    // Inject reversal at step 12 (index 11): L* jumps UP by 3.0
    lStarValues[11] = lStarValues[10] + 3.0  // 48.10 + 3.0 = 51.10

    // Inject flat zone at steps 18-20 (indices 17-19): nearly identical L*
    lStarValues[17] = 10.70
    lStarValues[18] = 10.72
    lStarValues[19] = 10.71

    let aStarValues: [Double] = [
         0.12,  0.15,  0.18,  0.22,  0.25,
         0.30,  0.35,  0.41,  0.47,  0.52,
         0.58,  0.63,  0.67,  0.70,  0.72,
         0.74,  0.75,  0.76,  0.76,  0.77,
         0.77
    ]
    let bStarValues: [Double] = [
         1.80,  1.95,  2.12,  2.30,  2.50,
         2.72,  2.95,  3.18,  3.42,  3.65,
         3.87,  4.07,  4.24,  4.38,  4.48,
         4.54,  4.57,  4.58,  4.58,  4.57,
         4.55
    ]

    for i in 0..<21 {
        let step = i + 1
        lines.append("\(step)\t\(String(format: "%.2f", lStarValues[i]))\t\(String(format: "%.2f", aStarValues[i]))\t\(String(format: "%.2f", bStarValues[i]))")
    }

    return lines.joined(separator: "\n")
}()

/// Valid measurement data but without the QuadToneProfiler header line.
/// Tests the `hasHeader` flag detection in QTRFileParser.parseMeasurement.
let testMeasurementNoHeader: String = {
    var lines: [String] = []

    // 11 steps, no header — simulates raw spectrophotometer export
    let lStarValues: [Double] = [
        94.80, 86.30, 77.50, 68.40, 59.10,
        49.50, 39.70, 29.60, 19.80, 10.20,
         4.90
    ]
    let aStarValues: [Double] = [
         0.10,  0.20,  0.30,  0.40,  0.50,
         0.55,  0.60,  0.65,  0.70,  0.72,
         0.74
    ]
    let bStarValues: [Double] = [
         1.50,  2.00,  2.50,  3.00,  3.40,
         3.70,  3.90,  4.05,  4.15,  4.20,
         4.22
    ]

    for i in 0..<11 {
        let step = i + 1
        lines.append("\(step)\t\(String(format: "%.2f", lStarValues[i]))\t\(String(format: "%.2f", aStarValues[i]))\t\(String(format: "%.2f", bStarValues[i]))")
    }

    return lines.joined(separator: "\n")
}()

// MARK: - Curve Data Helpers

/// Returns `[CurveStep]` with evenly spaced input/output from 0.0 to 1.0 (linear).
func testLinearCurveSteps(count: Int) -> [CurveStep] {
    guard count > 1 else {
        return [CurveStep(input: 0, output: 0)]
    }
    return (0..<count).map { i in
        let t = Double(i) / Double(count - 1)
        return CurveStep(input: t, output: t)
    }
}

/// Returns `[CurveStep]` with an S-curve (shadows compressed, highlights lifted)
/// using a sigmoid function: output = 1 / (1 + exp(-k*(x - 0.5)))
func testSCurveCurveSteps(count: Int) -> [CurveStep] {
    guard count > 1 else {
        return [CurveStep(input: 0, output: 0)]
    }
    let k = 8.0  // steepness of S-curve
    // Compute raw sigmoid endpoints for normalization
    let rawMin = 1.0 / (1.0 + exp(-k * (0.0 - 0.5)))
    let rawMax = 1.0 / (1.0 + exp(-k * (1.0 - 0.5)))

    return (0..<count).map { i in
        let input = Double(i) / Double(count - 1)
        let rawSigmoid = 1.0 / (1.0 + exp(-k * (input - 0.5)))
        // Normalize so output goes exactly 0.0 -> 1.0
        let output = (rawSigmoid - rawMin) / (rawMax - rawMin)
        return CurveStep(input: input, output: output)
    }
}

/// Typical blocking density values for digital negative calibration.
struct TestBlockingDensityValues {
    let highlightBlockingDensity: Double
    let mainBlockingDensity: Double
    let yellowBlockingDensity: Double
}

let testBlockingDensityValues = TestBlockingDensityValues(
    highlightBlockingDensity: 49.01,
    mainBlockingDensity: 55.0,
    yellowBlockingDensity: 5.0
)

// MARK: - OpenRIP PPD Fixture

/// Minimal PPD content for OpenRIP/EPSON Stylus SureColor P800 with key fields
/// for testing PPD parsing (Manufacturer, Product, cupsFilter, PageSize).
let testOpenRIPPPDContent: String = """
    *PPD-Adobe: "4.3"
    *FormatVersion: "4.3"
    *FileVersion: "1.0"
    *LanguageVersion: English
    *LanguageEncoding: ISOLatin1
    *Manufacturer: "OpenRIP"
    *ModelName: "OpenRIP EPSON Stylus SureColor P800"
    *ShortNickName: "OpenRIP P800"
    *NickName: "OpenRIP EPSON Stylus SureColor P800"
    *Product: "(EPSON Stylus SureColor P800)"
    *PSVersion: "(3010.000) 0"
    *cupsVersion: 1.4
    *cupsFilter: "application/vnd.cups-raster 0 /Library/Printers/OpenRIP/filter/openrip_filter"
    *cupsManualCopies: True
    *ColorDevice: True
    *DefaultColorSpace: RGB
    *Throughput: "1"
    *LandscapeOrientation: Plus90

    *OpenUI *PageSize/Media Size: PickOne
    *OrderDependency: 10 AnySetup *PageSize
    *DefaultPageSize: Letter
    *PageSize Letter/Letter (8.5x11): "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
    *PageSize Tabloid/Tabloid (11x17): "<</PageSize[792 1224]/ImagingBBox null>>setpagedevice"
    *PageSize 13x19/Super B (13x19): "<</PageSize[936 1368]/ImagingBBox null>>setpagedevice"
    *CloseUI: *PageSize

    *OpenUI *PageRegion: PickOne
    *OrderDependency: 10 AnySetup *PageRegion
    *DefaultPageRegion: Letter
    *PageRegion Letter/Letter (8.5x11): "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
    *PageRegion Tabloid/Tabloid (11x17): "<</PageSize[792 1224]/ImagingBBox null>>setpagedevice"
    *PageRegion 13x19/Super B (13x19): "<</PageSize[936 1368]/ImagingBBox null>>setpagedevice"
    *CloseUI: *PageRegion

    *DefaultImageableArea: Letter
    *ImageableArea Letter/Letter (8.5x11): "9 9 603 783"
    *ImageableArea Tabloid/Tabloid (11x17): "9 9 783 1215"
    *ImageableArea 13x19/Super B (13x19): "9 9 927 1359"

    *DefaultPaperDimension: Letter
    *PaperDimension Letter/Letter (8.5x11): "612 792"
    *PaperDimension Tabloid/Tabloid (11x17): "792 1224"
    *PaperDimension 13x19/Super B (13x19): "936 1368"

    *OpenUI *Resolution/Output Resolution: PickOne
    *OrderDependency: 20 AnySetup *Resolution
    *DefaultResolution: 1440x720dpi
    *Resolution 720x720dpi/720 x 720 DPI: "<</HWResolution[720 720]>>setpagedevice"
    *Resolution 1440x720dpi/1440 x 720 DPI: "<</HWResolution[1440 720]>>setpagedevice"
    *Resolution 2880x1440dpi/2880 x 1440 DPI: "<</HWResolution[2880 1440]>>setpagedevice"
    *CloseUI: *Resolution

    *OpenUI *MediaType/Media Type: PickOne
    *OrderDependency: 20 AnySetup *MediaType
    *DefaultMediaType: Matte
    *MediaType Matte/Matte Paper: "<</MediaType(Matte)>>setpagedevice"
    *MediaType Glossy/Glossy Paper: "<</MediaType(Glossy)>>setpagedevice"
    *MediaType FineArt/Fine Art Paper: "<</MediaType(FineArt)>>setpagedevice"
    *CloseUI: *MediaType

    *% End of PPD
    """

// MARK: - Ink Channel Fixture Helpers

/// Returns an `InkChannel` with 256 linearly spaced values from 0 to `maxValue`.
func testInkChannelLinear(name: String, maxValue: UInt16 = 29695) -> InkChannel {
    let values = buildLinearRamp(count: 256, maxValue: Int(maxValue))
    return InkChannel(name: name, values: values)
}

/// Returns an `InkChannel` with 256 zeros (inactive channel).
func testInkChannelEmpty(name: String) -> InkChannel {
    return InkChannel(name: name, values: Array(repeating: UInt16(0), count: 256))
}

/// Returns an `InkChannel` with a Gaussian-like bell curve.
/// Simulates light ink overlap: peaks at `peak` index with given `width` (sigma).
func testInkChannelBellCurve(name: String, peak: Int = 128, width: Double = 40.0) -> InkChannel {
    let values: [UInt16] = (0..<256).map { i in
        let x = Double(i)
        let mu = Double(peak)
        let sigma = width
        let gaussian = exp(-pow(x - mu, 2) / (2.0 * sigma * sigma))
        return UInt16(gaussian * 29695.0)
    }
    return InkChannel(name: name, values: values)
}

// MARK: - Private Curve Generation Helpers

/// Build a linear ramp of `count` UInt16 values from 0 to `maxValue`.
private func buildLinearRamp(count: Int, maxValue: Int) -> [UInt16] {
    guard count > 1 else { return [0] }
    return (0..<count).map { i in
        UInt16(Double(i) * Double(maxValue) / Double(count - 1))
    }
}

/// Build a realistic cyanotype K curve: first 30 values are 0,
/// then a non-linear accelerating ramp up to ~15834.
/// Simulates typical alt-process sensitivity rolloff.
private func buildCyanotypeKCurve(count: Int) -> [UInt16] {
    let deadZone = 30
    return (0..<count).map { i in
        if i < deadZone {
            return UInt16(0)
        }
        // Accelerating ramp: use power curve (exponent 2.2 simulates print gamma)
        let t = Double(i - deadZone) / Double(count - 1 - deadZone)
        let curved = pow(t, 2.2)
        return UInt16(curved * 15834.0)
    }
}

/// Build a realistic cyanotype C curve: non-zero from index 0.
/// Values follow a gentle ramp starting at ~1385 and rising to ~8500.
/// Simulates ferric ammonium citrate toning contribution.
private func buildCyanotypeCCurve(count: Int) -> [UInt16] {
    // Manually anchored start to match fixture spec, then smooth interpolation
    let anchors: [(index: Int, value: Double)] = [
        (0, 1385), (10, 1616), (20, 1749), (40, 2100),
        (80, 3200), (128, 4800), (180, 6400), (220, 7600),
        (255, 8500)
    ]

    return (0..<count).map { i in
        // Find the two surrounding anchor points
        var lo = anchors[0]
        var hi = anchors[anchors.count - 1]
        for a in 0..<(anchors.count - 1) {
            if i >= anchors[a].index && i <= anchors[a + 1].index {
                lo = anchors[a]
                hi = anchors[a + 1]
                break
            }
        }
        // Linear interpolation between anchors
        if hi.index == lo.index {
            return UInt16(lo.value)
        }
        let t = Double(i - lo.index) / Double(hi.index - lo.index)
        let value = lo.value + t * (hi.value - lo.value)
        return UInt16(min(max(value, 0), 65535))
    }
}
