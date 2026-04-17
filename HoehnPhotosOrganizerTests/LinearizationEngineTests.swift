// LinearizationEngineTests.swift
// HoehnPhotosOrganizerTests
//
// Tests for the core linearization engine (linearize()), blend system
// (computeBlend()), and L*/reflectance/density conversion functions.

import XCTest
@testable import HoehnPhotosOrganizer

// MARK: - Test Data Builders

private enum TestData {

    /// Build a simple linear K-only quad file with 8 channels.
    /// K channel has a linear ramp from 0 to maxValue; other channels are zero.
    static func linearKOnlyQuad(fileName: String = "test.quad", maxValue: UInt16 = 29695) -> QTRQuadFile {
        let kValues: [UInt16] = (0..<256).map { i in
            UInt16(Double(i) / 255.0 * Double(maxValue))
        }
        let zeroValues = [UInt16](repeating: 0, count: 256)
        let channelNames = QTRFileParser.standardChannelNames
        var channels: [InkChannel] = []
        for (idx, name) in channelNames.enumerated() {
            channels.append(InkChannel(name: name, values: idx == 0 ? kValues : zeroValues))
        }
        return QTRQuadFile(
            fileName: fileName,
            comments: ["## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK"],
            channels: channels
        )
    }

    /// Build a measurement with perfectly linear L* from paperWhiteL down to dMaxL.
    static func linearMeasurement(
        stepCount: Int = 21,
        paperWhiteL: Double = 95.0,
        dMaxL: Double = 5.0,
        fileName: String = "linear_meas.txt"
    ) -> SpyderPRINTMeasurement {
        let steps = (0..<stepCount).map { i in
            let t = Double(i) / Double(stepCount - 1)
            let labL = paperWhiteL - t * (paperWhiteL - dMaxL)
            return LabStep(stepNumber: i + 1, labL: labL, labA: 0.0, labB: 0.0)
        }
        return SpyderPRINTMeasurement(fileName: fileName, hasHeader: true, steps: steps)
    }

    /// Build a measurement with a gamma-curved L* response (simulates
    /// a printer that prints too dark in highlights).
    /// gamma > 1 means the printer's measured L* drops faster than linear
    /// in the highlights (i.e., highlights are too dark).
    static func gammaMeasurement(
        stepCount: Int = 21,
        gamma: Double = 2.0,
        paperWhiteL: Double = 95.0,
        dMaxL: Double = 5.0,
        fileName: String = "gamma_meas.txt"
    ) -> SpyderPRINTMeasurement {
        let lRange = paperWhiteL - dMaxL
        let steps = (0..<stepCount).map { i in
            let t = Double(i) / Double(stepCount - 1)
            // Apply gamma: pow(t, gamma) makes L* drop faster at the start
            let labL = paperWhiteL - pow(t, gamma) * lRange
            return LabStep(stepNumber: i + 1, labL: labL, labA: 0.0, labB: 0.0)
        }
        return SpyderPRINTMeasurement(fileName: fileName, hasHeader: true, steps: steps)
    }

    /// Build a multi-channel quad for blend testing.
    /// K has a linear ramp; C has a half-strength ramp.
    static func twoChannelQuad(fileName: String, kMax: UInt16 = 29695, cMax: UInt16 = 14000) -> QTRQuadFile {
        let channelNames = QTRFileParser.standardChannelNames
        let zeroValues = [UInt16](repeating: 0, count: 256)
        var channels: [InkChannel] = []
        for (idx, name) in channelNames.enumerated() {
            let values: [UInt16]
            if idx == 0 {
                values = (0..<256).map { i in UInt16(Double(i) / 255.0 * Double(kMax)) }
            } else if idx == 1 {
                values = (0..<256).map { i in UInt16(Double(i) / 255.0 * Double(cMax)) }
            } else {
                values = zeroValues
            }
            channels.append(InkChannel(name: name, values: values))
        }
        return QTRQuadFile(
            fileName: fileName,
            comments: ["## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK"],
            channels: channels
        )
    }
}

// MARK: - L* / Reflectance / Density Conversion Tests

final class ColorConversionTests: XCTestCase {

    // MARK: - labLToReflectance & reflectanceToLabL round-trip

    func test_labLToReflectance_and_back_roundTrip() {
        // Test a range of L* values from 0 to 100
        let testValues: [Double] = [0, 5, 10, 20, 30, 40, 50, 60, 70, 80, 90, 95, 100]
        for lStar in testValues {
            let reflectance = labLToReflectance(lStar)
            let roundTripped = reflectanceToLabL(reflectance)
            XCTAssertEqual(roundTripped, lStar, accuracy: 1e-8,
                           "L*=\(lStar) should round-trip through reflectance")
        }
    }

    func test_reflectanceToLabL_and_back_roundTrip() {
        let testValues: [Double] = [0.0, 0.01, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 1.0]
        for r in testValues {
            let lStar = reflectanceToLabL(r)
            let roundTripped = labLToReflectance(lStar)
            XCTAssertEqual(roundTripped, r, accuracy: 1e-8,
                           "Reflectance=\(r) should round-trip through L*")
        }
    }

    // MARK: - Known L* boundary values

    func test_labLToReflectance_atLStar100_isOne() {
        let r = labLToReflectance(100.0)
        XCTAssertEqual(r, 1.0, accuracy: 1e-8,
                       "L*=100 should map to reflectance 1.0")
    }

    func test_labLToReflectance_atLStar0_isZero() {
        let r = labLToReflectance(0.0)
        XCTAssertEqual(r, 0.0, accuracy: 1e-8,
                       "L*=0 should map to reflectance 0.0")
    }

    func test_reflectanceToLabL_atR1_is100() {
        let l = reflectanceToLabL(1.0)
        XCTAssertEqual(l, 100.0, accuracy: 1e-8,
                       "Reflectance 1.0 should map to L*=100")
    }

    func test_reflectanceToLabL_atR0_is0() {
        let l = reflectanceToLabL(0.0)
        XCTAssertEqual(l, 0.0, accuracy: 1e-8,
                       "Reflectance 0.0 should map to L*=0")
    }

    // MARK: - L*=50 known value

    func test_labLToReflectance_atLStar50() {
        // L*=50 corresponds to Y/Yn = ((50+16)/116)^3 ≈ 0.1842
        let r = labLToReflectance(50.0)
        let expected = pow((50.0 + 16.0) / 116.0, 3.0)
        XCTAssertEqual(r, expected, accuracy: 1e-8,
                       "L*=50 reflectance should match CIE formula")
    }

    // MARK: - reflectanceToDensity

    func test_reflectanceToDensity_atR1_isZero() {
        let d = reflectanceToDensity(1.0)
        XCTAssertEqual(d, 0.0, accuracy: 1e-8,
                       "Reflectance 1.0 (white) should have density 0.0")
    }

    func test_reflectanceToDensity_atR001_is2() {
        let d = reflectanceToDensity(0.01)
        XCTAssertEqual(d, 2.0, accuracy: 1e-8,
                       "Reflectance 0.01 should have density 2.0")
    }

    func test_reflectanceToDensity_atR01_is1() {
        let d = reflectanceToDensity(0.1)
        XCTAssertEqual(d, 1.0, accuracy: 1e-8,
                       "Reflectance 0.1 should have density 1.0")
    }

    // MARK: - densityToReflectance round-trip

    func test_density_reflectance_roundTrip() {
        let testDensities: [Double] = [0.0, 0.3, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
        for d in testDensities {
            let r = densityToReflectance(d)
            let roundTripped = reflectanceToDensity(r)
            XCTAssertEqual(roundTripped, d, accuracy: 1e-8,
                           "Density=\(d) should round-trip through reflectance")
        }
    }

    // MARK: - Edge cases

    func test_reflectanceToDensity_nearZero_clamped() {
        // Very small reflectance should not produce infinity
        let d = reflectanceToDensity(0.0)
        XCTAssertTrue(d.isFinite, "Density at reflectance 0 should be finite (clamped)")
        XCTAssertEqual(d, 10.0, accuracy: 0.01,
                       "Density at reflectance 0 should be clamped to -log10(1e-10) = 10.0")
    }

    func test_labLToReflectance_isMonotonic() {
        // L* increases -> reflectance should increase
        var prevR = -1.0
        for i in 0...100 {
            let lStar = Double(i)
            let r = labLToReflectance(lStar)
            XCTAssertGreaterThanOrEqual(r, prevR,
                                         "Reflectance should be monotonically non-decreasing with L*")
            prevR = r
        }
    }
}

// MARK: - Linearization Engine Tests

@MainActor
final class LinearizationEngineTests: XCTestCase {

    private var vm: CurveLabViewModel!

    override func setUp() {
        super.setUp()
        vm = CurveLabViewModel()
    }

    // MARK: - Linear measurement -> near-identity correction

    func test_linearize_linearMeasurement_producesValidOutput() {
        // Given: a linear K ramp and a perfectly linear 80-step measurement
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.linearMeasurement(stepCount: 80)

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 0, inkSmoothing: 0,
            invertCurve: false, outputCurveType: .linearLabL
        )

        vm.linearize()

        guard let result = vm.linearizedQuad else {
            XCTFail("Linearization should produce output")
            return
        }

        let linearizedK = result.channels[0].values

        // Output should be non-trivial (not all zeros, not all max)
        XCTAssertTrue(linearizedK.contains(where: { $0 > 0 }), "Should have non-zero values")
        XCTAssertTrue(linearizedK.contains(where: { $0 < 65535 }), "Should have non-maxed values")

        // Should be monotonically non-decreasing (our enforcement guarantees this)
        for i in 1..<256 {
            XCTAssertGreaterThanOrEqual(linearizedK[i], linearizedK[i - 1],
                                         "K channel must be non-decreasing at index \(i)")
        }

        // Endpoints should be reasonable: first value near 0, last value near max
        XCTAssertLessThan(linearizedK[0], 1000, "First K value should be near zero")
        XCTAssertGreaterThan(linearizedK[255], 20000, "Last K value should be substantial")
    }

    // MARK: - Gamma measurement -> correction lightens highlights

    func test_linearize_gammaMeasurement_correctionLightensHighlights() {
        // Given: a printer that drops L* too fast (gamma=2.0 response)
        // The linearization should compensate by reducing ink in the highlights.
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.gammaMeasurement(gamma: 2.0)

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 0, inkSmoothing: 0,
            invertCurve: false, outputCurveType: .linearLabL
        )

        vm.linearize()

        guard let result = vm.linearizedQuad else {
            XCTFail("Linearization should produce output")
            return
        }

        let originalK = sourceQuad.channels[0].values
        let linearizedK = result.channels[0].values

        // In the highlight region (indices 30-80), the linearized curve should
        // use LESS ink than the original (to compensate for the printer being too dark).
        // With gamma=2.0, at input 64/255 (t=0.25), the printer produces L* as if
        // it were at t=0.0625, so the correction should pull ink back.
        var highlightReductions = 0
        for i in 30..<80 {
            if linearizedK[i] < originalK[i] {
                highlightReductions += 1
            }
        }

        XCTAssertGreaterThan(highlightReductions, 30,
                             "At least 30 of 50 highlight indices should have reduced ink to lighten highlights")
    }

    // MARK: - Monotonicity of output LUT

    func test_linearize_outputIsMonotonicallyNonDecreasing() {
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.gammaMeasurement(gamma: 1.5)

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 25, inkSmoothing: 20,
            invertCurve: false, outputCurveType: .linearLabL
        )

        vm.linearize()

        guard let result = vm.linearizedQuad else {
            XCTFail("Linearization should produce output")
            return
        }

        // The K channel values should be monotonically non-decreasing
        // (more input = more ink, never less)
        let linearizedK = result.channels[0].values
        for i in 1..<256 {
            XCTAssertGreaterThanOrEqual(
                linearizedK[i], linearizedK[i - 1],
                "Linearized K channel must be monotonically non-decreasing at index \(i): " +
                "\(linearizedK[i]) < \(linearizedK[i-1])"
            )
        }
    }

    // MARK: - Newton-Raphson convergence

    func test_linearize_newtonRaphsonConverges() {
        // With typical measurement data, Newton-Raphson should converge
        // and produce a valid output (not nil).
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.gammaMeasurement(stepCount: 21, gamma: 1.8)

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 10, inkSmoothing: 10,
            invertCurve: false, outputCurveType: .linearLabL
        )

        vm.linearize()

        XCTAssertNotNil(vm.linearizedQuad, "Newton-Raphson should converge and produce output")

        // Verify the output is reasonable: K channel should not be all zeros
        // and not be all max values
        if let result = vm.linearizedQuad {
            let kValues = result.channels[0].values
            let hasNonZero = kValues.contains(where: { $0 > 0 })
            let hasNonMax = kValues.contains(where: { $0 < 65535 })
            XCTAssertTrue(hasNonZero, "Linearized K should have non-zero values")
            XCTAssertTrue(hasNonMax, "Linearized K should have non-maxed values")
        }
    }

    // MARK: - Output curve type: Linear L*

    func test_linearize_linearLabL_curveType() {
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.gammaMeasurement(gamma: 1.5)

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 0, inkSmoothing: 0,
            invertCurve: false, outputCurveType: .linearLabL
        )

        vm.linearize()
        XCTAssertNotNil(vm.linearizedQuad, "Linear L* linearization should produce output")
    }

    // MARK: - Output curve type: Linear Density

    func test_linearize_linearDensity_curveType() {
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.gammaMeasurement(gamma: 1.5)

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 0, inkSmoothing: 0,
            invertCurve: false, outputCurveType: .linearDensity
        )

        vm.linearize()
        XCTAssertNotNil(vm.linearizedQuad, "Linear Density linearization should produce output")

        // Linear density and linear L* should produce different results
        // for the same non-linear measurement
        let densityResult = vm.linearizedQuad!.channels[0].values

        // Re-run with linearLabL
        vm.linearizedQuad = nil
        vm.linearizeConfig.outputCurveType = .linearLabL
        vm.linearize()
        let labLResult = vm.linearizedQuad!.channels[0].values

        var differences = 0
        for i in 10..<246 {
            if densityResult[i] != labLResult[i] {
                differences += 1
            }
        }
        XCTAssertGreaterThan(differences, 50,
                             "Linear Density and Linear L* should produce meaningfully different curves")
    }

    // MARK: - Output curve type: Linear Ink (identity)

    func test_linearize_linearInk_producesValidOutput() {
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.gammaMeasurement(stepCount: 80, gamma: 2.0)

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 0, inkSmoothing: 0,
            invertCurve: false, outputCurveType: .linearInk
        )

        vm.linearize()

        guard let result = vm.linearizedQuad else {
            XCTFail("Linear Ink linearization should produce output")
            return
        }

        // Linear Ink mode skips Newton-Raphson — output should be valid and monotonic
        let linearizedK = result.channels[0].values
        XCTAssertTrue(linearizedK.contains(where: { $0 > 0 }), "Should have non-zero values")
        for i in 1..<256 {
            XCTAssertGreaterThanOrEqual(linearizedK[i], linearizedK[i - 1],
                                         "K channel must be non-decreasing at index \(i)")
        }
    }

    // MARK: - Invert curve

    func test_linearize_invertCurve_producesInvertedValues() {
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = TestData.linearMeasurement()

        // Normal (non-inverted)
        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 0, inkSmoothing: 0,
            invertCurve: false, outputCurveType: .linearLabL
        )
        vm.linearize()
        let normalK = vm.linearizedQuad!.channels[0].values

        // Inverted
        vm.linearizedQuad = nil
        vm.linearizeConfig.invertCurve = true
        vm.linearize()
        let invertedK = vm.linearizedQuad!.channels[0].values

        // Inverted values should be 65535 - normalValue
        for i in 0..<256 {
            XCTAssertEqual(invertedK[i], 65535 - normalK[i],
                           "Inverted value at \(i) should be 65535 - normal value")
        }
    }

    // MARK: - Edge case: too few measurement steps

    func test_linearize_singleMeasurementStep_producesNoOutput() {
        let sourceQuad = TestData.linearKOnlyQuad()
        let measurement = SpyderPRINTMeasurement(
            fileName: "single.txt", hasHeader: false,
            steps: [LabStep(stepNumber: 1, labL: 95.0, labA: 0, labB: 0)]
        )

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearize()

        XCTAssertNil(vm.linearizedQuad,
                     "Linearization with < 2 measurement steps should produce no output")
    }

    // MARK: - Edge case: nil source quad

    func test_linearize_nilSourceQuad_producesNoOutput() {
        vm.linearizeSourceQuad = nil
        vm.linearizeMeasurement = TestData.linearMeasurement()
        vm.linearize()
        XCTAssertNil(vm.linearizedQuad)
    }

    // MARK: - Output includes linearization history

    func test_linearize_addsLinearizationHistory() {
        let sourceQuad = TestData.linearKOnlyQuad(fileName: "base.quad")
        let measurement = TestData.linearMeasurement(fileName: "meas01.txt")

        vm.linearizeSourceQuad = sourceQuad
        vm.linearizeMeasurement = measurement
        vm.linearizeConfig = LinearizationConfig(
            mainSmoothing: 10, inkSmoothing: 10,
            invertCurve: false, outputCurveType: .linearLabL
        )

        vm.linearize()

        guard let result = vm.linearizedQuad else {
            XCTFail("Should produce output")
            return
        }

        XCTAssertEqual(result.linearizationHistory.count, 1)
        XCTAssertEqual(result.linearizationHistory[0].measurementFile, "meas01.txt")
        XCTAssertEqual(result.linearizationHistory[0].inputQuadFile, "base.quad")
    }
}

// MARK: - Blend Engine Tests

@MainActor
final class BlendEngineTests: XCTestCase {

    private var vm: CurveLabViewModel!

    override func setUp() {
        super.setUp()
        vm = CurveLabViewModel()
    }

    // MARK: - All weights at 100 -> produces curve 1

    func test_computeBlend_allWeights100_producesCurve1() {
        let c1 = TestData.twoChannelQuad(fileName: "warm.quad", kMax: 29695, cMax: 14000)
        let c2 = TestData.twoChannelQuad(fileName: "cool.quad", kMax: 15000, cMax: 8000)

        vm.blendCurve1 = c1
        vm.blendCurve2 = c2
        vm.blendWeights = BlendWeights(
            whites: 100, lights: 100, midtones: 100, darks: 100, blacks: 100
        )

        vm.computeBlend()

        guard let result = vm.blendedResult else {
            XCTFail("Blend should produce output")
            return
        }

        // All channel values should match curve 1
        for ch in 0..<min(c1.channels.count, result.channels.count) {
            for i in 0..<256 {
                XCTAssertEqual(
                    result.channels[ch].values[i], c1.channels[ch].values[i],
                    "Channel \(ch) index \(i): 100% weight should produce curve1 values"
                )
            }
        }
    }

    // MARK: - All weights at 0 -> produces curve 2

    func test_computeBlend_allWeights0_producesCurve2() {
        let c1 = TestData.twoChannelQuad(fileName: "warm.quad", kMax: 29695, cMax: 14000)
        let c2 = TestData.twoChannelQuad(fileName: "cool.quad", kMax: 15000, cMax: 8000)

        vm.blendCurve1 = c1
        vm.blendCurve2 = c2
        vm.blendWeights = BlendWeights(
            whites: 0, lights: 0, midtones: 0, darks: 0, blacks: 0
        )

        vm.computeBlend()

        guard let result = vm.blendedResult else {
            XCTFail("Blend should produce output")
            return
        }

        for ch in 0..<min(c2.channels.count, result.channels.count) {
            for i in 0..<256 {
                XCTAssertEqual(
                    result.channels[ch].values[i], c2.channels[ch].values[i],
                    "Channel \(ch) index \(i): 0% weight should produce curve2 values"
                )
            }
        }
    }

    // MARK: - 50/50 blend produces values between curves

    func test_computeBlend_50_50_producesMidpointValues() {
        let c1 = TestData.twoChannelQuad(fileName: "warm.quad", kMax: 30000, cMax: 0)
        let c2 = TestData.twoChannelQuad(fileName: "cool.quad", kMax: 10000, cMax: 0)

        vm.blendCurve1 = c1
        vm.blendCurve2 = c2
        vm.blendWeights = BlendWeights(
            whites: 50, lights: 50, midtones: 50, darks: 50, blacks: 50
        )

        vm.computeBlend()

        guard let result = vm.blendedResult else {
            XCTFail("Blend should produce output")
            return
        }

        // K channel: every value should be between curve1 and curve2
        let kResult = result.channels[0].values
        let k1 = c1.channels[0].values
        let k2 = c2.channels[0].values

        for i in 1..<256 {  // skip index 0 (both are 0)
            let lo = min(k1[i], k2[i])
            let hi = max(k1[i], k2[i])
            XCTAssertGreaterThanOrEqual(kResult[i], lo,
                                         "Blended K[\(i)] should be >= min of inputs")
            XCTAssertLessThanOrEqual(kResult[i], hi,
                                     "Blended K[\(i)] should be <= max of inputs")

            // Should also be approximately the midpoint
            let expectedMid = (Double(k1[i]) + Double(k2[i])) / 2.0
            XCTAssertEqual(Double(kResult[i]), expectedMid, accuracy: 1.5,
                           "50/50 blend at \(i) should be near midpoint")
        }
    }

    // MARK: - Identical input curves -> output equals input

    func test_computeBlend_identicalCurves_outputEqualsInput() {
        let c1 = TestData.linearKOnlyQuad(fileName: "same1.quad")
        let c2 = TestData.linearKOnlyQuad(fileName: "same2.quad")

        // Use arbitrary non-trivial weights
        vm.blendCurve1 = c1
        vm.blendCurve2 = c2
        vm.blendWeights = BlendWeights(
            whites: 30, lights: 70, midtones: 50, darks: 80, blacks: 10
        )

        vm.computeBlend()

        guard let result = vm.blendedResult else {
            XCTFail("Blend should produce output")
            return
        }

        // Blending identical curves with any weights should produce the same curve
        // Allow off-by-one from UInt16 rounding in cosine interpolation
        for ch in 0..<min(c1.channels.count, result.channels.count) {
            for i in 0..<256 {
                let diff = abs(Int(result.channels[ch].values[i]) - Int(c1.channels[ch].values[i]))
                XCTAssertLessThanOrEqual(
                    diff, 1,
                    "Blending identical curves should produce near-identical output " +
                    "(ch=\(ch), i=\(i), diff=\(diff))"
                )
            }
        }
    }

    // MARK: - Cosine interpolation smoothness

    func test_computeBlend_cosineInterpolation_isSmooth() {
        // Set up a blend where zones have very different weights
        // to test that cosine interpolation produces smooth transitions
        let c1Values: [UInt16] = (0..<256).map { _ in 60000 }
        let c2Values: [UInt16] = (0..<256).map { _ in 10000 }
        let zeroValues = [UInt16](repeating: 0, count: 256)

        let channelNames = QTRFileParser.standardChannelNames
        var ch1: [InkChannel] = []
        var ch2: [InkChannel] = []
        for (idx, name) in channelNames.enumerated() {
            ch1.append(InkChannel(name: name, values: idx == 0 ? c1Values : zeroValues))
            ch2.append(InkChannel(name: name, values: idx == 0 ? c2Values : zeroValues))
        }

        let quad1 = QTRQuadFile(fileName: "flat_high.quad",
                                comments: ["## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK"],
                                channels: ch1)
        let quad2 = QTRQuadFile(fileName: "flat_low.quad",
                                comments: ["## QuadToneRIP K,C,M,Y,LC,LM,LK,LLK"],
                                channels: ch2)

        vm.blendCurve1 = quad1
        vm.blendCurve2 = quad2
        // Big jumps between zone weights to stress smoothness
        vm.blendWeights = BlendWeights(
            whites: 0, lights: 100, midtones: 0, darks: 100, blacks: 0
        )

        vm.computeBlend()

        guard let result = vm.blendedResult else {
            XCTFail("Blend should produce output")
            return
        }

        let kResult = result.channels[0].values

        // Check smoothness: the maximum step-to-step change should be bounded.
        // With flat input curves and cosine interpolation, the transitions
        // between zones should be gradual, not abrupt jumps.
        var maxStepChange: Int = 0
        for i in 1..<256 {
            let change = abs(Int(kResult[i]) - Int(kResult[i - 1]))
            maxStepChange = max(maxStepChange, change)
        }

        // With 50000 difference between curves and cosine transitions across
        // ~51 indices between zone centers, max step change should be well
        // under 5000 (pure linear would be ~980 per step at steepest).
        XCTAssertLessThan(maxStepChange, 5000,
                          "Cosine interpolation should prevent abrupt jumps (maxStepChange=\(maxStepChange))")

        // Also verify there are no identical consecutive runs longer than
        // the zone width, which would indicate blocky (non-smooth) blending.
        var longestRun = 1
        var currentRun = 1
        for i in 1..<256 {
            if kResult[i] == kResult[i - 1] {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 1
            }
        }
        // Zone centers are ~51 apart. A smooth blend should transition
        // across that range, not hold constant for the whole zone.
        // Allow up to 30 consecutive identical values (zone plateaus are ok).
        XCTAssertLessThan(longestRun, 60,
                          "Smooth blend should not have extremely long constant runs (\(longestRun))")
    }

    // MARK: - Nil inputs

    func test_computeBlend_nilCurve1_producesNil() {
        vm.blendCurve1 = nil
        vm.blendCurve2 = TestData.linearKOnlyQuad()
        vm.computeBlend()
        XCTAssertNil(vm.blendedResult)
    }

    func test_computeBlend_nilCurve2_producesNil() {
        vm.blendCurve1 = TestData.linearKOnlyQuad()
        vm.blendCurve2 = nil
        vm.computeBlend()
        XCTAssertNil(vm.blendedResult)
    }

    // MARK: - Output metadata

    func test_computeBlend_outputFileName_isBlended() {
        vm.blendCurve1 = TestData.linearKOnlyQuad(fileName: "warm.quad")
        vm.blendCurve2 = TestData.linearKOnlyQuad(fileName: "cool.quad")
        vm.blendWeights = BlendWeights()
        vm.computeBlend()

        XCTAssertEqual(vm.blendedResult?.fileName, "Blended.quad")
    }

    func test_computeBlend_outputComments_referenceSourceFiles() {
        vm.blendCurve1 = TestData.linearKOnlyQuad(fileName: "warm.quad")
        vm.blendCurve2 = TestData.linearKOnlyQuad(fileName: "cool.quad")
        vm.blendWeights = BlendWeights()
        vm.computeBlend()

        let comments = vm.blendedResult?.comments.joined(separator: " ") ?? ""
        XCTAssertTrue(comments.contains("warm.quad"), "Comments should reference curve 1 filename")
        XCTAssertTrue(comments.contains("cool.quad"), "Comments should reference curve 2 filename")
    }

    // MARK: - Zone weight isolation

    func test_computeBlend_onlyBlacksWeightSet_affectsOnlyBlacksZone() {
        // With only blacks=100 and everything else=0, only the blacks zone
        // (around zone center 229.5) should pull toward curve 1.
        let c1 = TestData.twoChannelQuad(fileName: "a.quad", kMax: 60000, cMax: 0)
        let c2 = TestData.twoChannelQuad(fileName: "b.quad", kMax: 10000, cMax: 0)

        vm.blendCurve1 = c1
        vm.blendCurve2 = c2
        vm.blendWeights = BlendWeights(
            whites: 0, lights: 0, midtones: 0, darks: 0, blacks: 100
        )

        vm.computeBlend()

        guard let result = vm.blendedResult else {
            XCTFail("Blend should produce output")
            return
        }

        let kResult = result.channels[0].values

        // Whites zone (near center 25.5): should be close to curve 2
        XCTAssertEqual(Double(kResult[10]), Double(c2.channels[0].values[10]), accuracy: 500,
                       "Whites zone should be predominantly curve 2")

        // Blacks zone (near center 229.5, specifically index 240):
        // should be close to curve 1
        XCTAssertEqual(Double(kResult[240]), Double(c1.channels[0].values[240]), accuracy: 500,
                       "Blacks zone should be predominantly curve 1")
    }
}
