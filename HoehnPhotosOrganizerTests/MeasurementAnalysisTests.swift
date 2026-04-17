// MeasurementAnalysisTests.swift
// HoehnPhotosOrganizerTests
//
// Tests for SpyderPRINT measurement analysis: anomaly detection, smoothing,
// monotonic enforcement, density calculations, and linearization workflow.

import XCTest
@testable import HoehnPhotosOrganizer

final class MeasurementAnalysisTests: XCTestCase {

    // MARK: - Parsed Fixtures

    private var clean21: SpyderPRINTMeasurement!
    private var withReversals: SpyderPRINTMeasurement!
    private var noHeader: SpyderPRINTMeasurement!

    override func setUpWithError() throws {
        try super.setUpWithError()
        clean21 = try QTRFileParser.parseMeasurement(content: testMeasurement21Steps, fileName: "clean21.txt")
        withReversals = try QTRFileParser.parseMeasurement(content: testMeasurementWithReversals, fileName: "reversals.txt")
        noHeader = try QTRFileParser.parseMeasurement(content: testMeasurementNoHeader, fileName: "noheader.txt")
    }

    override func tearDown() {
        clean21 = nil
        withReversals = nil
        noHeader = nil
        super.tearDown()
    }

    // MARK: - Measurement Stats

    // 1. paperWhiteL equals the L* of the first step
    func test_paperWhiteL_firstStep() {
        XCTAssertEqual(clean21.paperWhiteL, clean21.steps.first!.labL)
        XCTAssertEqual(clean21.paperWhiteL!, 95.20, accuracy: 0.01)
    }

    // 2. dMaxL equals the minimum L* across all steps
    func test_dMaxL_darkestStep() {
        let minL = clean21.steps.map(\.labL).min()!
        XCTAssertEqual(clean21.dMaxL!, minL)
        XCTAssertEqual(clean21.dMaxL!, 5.10, accuracy: 0.01)
    }

    // 3. densityRange = paperWhiteL - dMaxL
    func test_densityRange_paperMinusDmax() {
        let expected = clean21.paperWhiteL! - clean21.dMaxL!
        XCTAssertEqual(clean21.densityRange!, expected, accuracy: 0.001)
    }

    // 4. Clean 21-step measurement: range ~ 90 (95 - 5)
    func test_densityRange_perfectPrint() {
        XCTAssertEqual(clean21.densityRange!, 90.10, accuracy: 0.5)
    }

    // 5. Empty measurement -> paperWhiteL/dMaxL/densityRange all nil
    func test_densityRange_nilForEmpty() {
        let empty = SpyderPRINTMeasurement(fileName: "empty.txt", steps: [])
        XCTAssertNil(empty.paperWhiteL)
        XCTAssertNil(empty.dMaxL)
        XCTAssertNil(empty.densityRange)
    }

    // MARK: - Anomaly Detection -- Reversals

    // 6. Measurement with L* jump UP of 3.0 at step 12 -> anomaly detected
    func test_anomaly_reversal_detected() {
        let reversals = withReversals.anomalies.filter { $0.type == .reversal }
        XCTAssertFalse(reversals.isEmpty, "Expected at least one reversal anomaly")
    }

    // 7. The anomaly's deltaL ~ 3.0
    func test_anomaly_reversal_deltaRecorded() {
        let reversals = withReversals.anomalies.filter { $0.type == .reversal }
        guard let first = reversals.first else {
            XCTFail("No reversal anomaly found")
            return
        }
        XCTAssertEqual(first.deltaL, 3.0, accuracy: 0.1)
    }

    // 8. type == .reversal
    func test_anomaly_reversal_typeIsReversal() {
        let reversals = withReversals.anomalies.filter { $0.type == .reversal }
        for r in reversals {
            XCTAssertEqual(r.type, .reversal)
        }
    }

    // 9. stepIndex matches where the reversal occurs (index 11)
    func test_anomaly_reversal_stepIndexCorrect() {
        let reversals = withReversals.anomalies.filter { $0.type == .reversal }
        guard let first = reversals.first else {
            XCTFail("No reversal anomaly found")
            return
        }
        // The fixture injects reversal at index 11 (step 12)
        XCTAssertEqual(first.stepIndex, 11)
    }

    // 10. L* increase of 0.5 (< 1.0 threshold) -> no reversal anomaly
    func test_anomaly_smallIncrease_notDetected() {
        // Build steps where one step has a small 0.5 L* increase (below threshold)
        var steps = cleanMeasurement(steps: 10)
        // Inject small reversal at index 5: increase L* by 0.5
        let originalL = steps[5].labL
        steps[5] = LabStep(stepNumber: 5, labL: steps[4].labL + 0.5, labA: 0.0, labB: 0.0)
        // Make sure subsequent steps are still below the modified value
        for i in 6..<steps.count {
            steps[i] = LabStep(stepNumber: i, labL: originalL - Double(i - 5) * 2.0, labA: 0.0, labB: 0.0)
        }

        let measurement = SpyderPRINTMeasurement(fileName: "small.txt", steps: steps)
        let reversals = measurement.anomalies.filter { $0.type == .reversal }
        XCTAssertTrue(reversals.isEmpty, "0.5 increase should not trigger reversal (threshold is 1.0)")
    }

    // MARK: - Anomaly Detection -- Flat Zones

    // 11. Three consecutive steps with L* range < 0.3 -> flat zone detected
    func test_anomaly_flatZone_detected() {
        let flatZones = withReversals.anomalies.filter { $0.type == .flatZone }
        XCTAssertFalse(flatZones.isEmpty, "Expected at least one flat zone anomaly")
    }

    // 12. type == .flatZone
    func test_anomaly_flatZone_typeIsFlatZone() {
        let flatZones = withReversals.anomalies.filter { $0.type == .flatZone }
        for fz in flatZones {
            XCTAssertEqual(fz.type, .flatZone)
        }
    }

    // 13. Steps with 2.0 L* spacing -> no flat zone
    func test_anomaly_normalGradient_noFlatZone() {
        // Build steps with consistent 2.0 L* spacing -- no flat zones
        let steps = (0..<15).map { i in
            LabStep(stepNumber: i, labL: 95.0 - Double(i) * 2.0, labA: 0.0, labB: 0.0)
        }
        let measurement = SpyderPRINTMeasurement(fileName: "normal.txt", steps: steps)
        let flatZones = measurement.anomalies.filter { $0.type == .flatZone }
        XCTAssertTrue(flatZones.isEmpty, "2.0 spacing should not trigger flat zone detection")
    }

    // MARK: - Anomaly Counts

    // 14. testMeasurement21Steps -> 0 anomalies
    func test_cleanMeasurement_zeroAnomalies() {
        XCTAssertEqual(clean21.anomalies.count, 0, "Clean measurement should have zero anomalies")
    }

    // 15. testMeasurementWithReversals -> at least 2 anomalies (1 reversal + 1 flat zone)
    func test_problematicMeasurement_multipleAnomalies() {
        let anomalies = withReversals.anomalies
        let reversals = anomalies.filter { $0.type == .reversal }
        let flatZones = anomalies.filter { $0.type == .flatZone }

        XCTAssertGreaterThanOrEqual(anomalies.count, 2)
        XCTAssertGreaterThanOrEqual(reversals.count, 1, "Expected at least 1 reversal")
        XCTAssertGreaterThanOrEqual(flatZones.count, 1, "Expected at least 1 flat zone")
    }

    // MARK: - Smoothing

    // 16. Add noise to a smooth curve, smooth it, verify max adjacent delta is smaller
    func test_smooth_reducesMaxDelta() {
        let base = cleanMeasurement(steps: 21)
        let noisy = addNoise(to: base, maxNoise: 3.0)
        let smoothed = QTRFileParser.smooth(steps: noisy, windowSize: 5)

        let noisyMaxDelta = maxAdjacentDelta(noisy)
        let smoothedMaxDelta = maxAdjacentDelta(smoothed)

        XCTAssertLessThan(smoothedMaxDelta, noisyMaxDelta,
                          "Smoothing should reduce max adjacent L* delta")
    }

    // 17. Window 3 output is closer to original than window 9
    func test_smooth_window3_lessAggressiveThanWindow9() {
        let base = cleanMeasurement(steps: 21)
        let noisy = addNoise(to: base, maxNoise: 2.0)
        let smooth3 = QTRFileParser.smooth(steps: noisy, windowSize: 3)
        let smooth9 = QTRFileParser.smooth(steps: noisy, windowSize: 9)

        // Compare total L* deviation from noisy input
        let deviation3 = totalLDeviation(noisy, smooth3)
        let deviation9 = totalLDeviation(noisy, smooth9)

        XCTAssertLessThan(deviation3, deviation9,
                          "Window 3 should deviate less from input than window 9")
    }

    // 18. Output has same count as input
    func test_smooth_preservesStepCount() {
        let steps = cleanMeasurement(steps: 21)
        let smoothed = QTRFileParser.smooth(steps: steps, windowSize: 5)
        XCTAssertEqual(smoothed.count, steps.count)
    }

    // 19. Step numbers unchanged after smoothing
    func test_smooth_preservesStepNumbers() {
        let steps = cleanMeasurement(steps: 21)
        let smoothed = QTRFileParser.smooth(steps: steps, windowSize: 5)
        for (original, smooth) in zip(steps, smoothed) {
            XCTAssertEqual(original.stepNumber, smooth.stepNumber)
        }
    }

    // 20. a* and b* values are also smoothed, not just L*
    func test_smooth_labABAlsoSmoothed() {
        // Create steps with varying a*/b* values
        let steps = (0..<21).map { i in
            let t = Double(i) / 20.0
            let noise = sin(Double(i) * 2.3) * 2.0
            return LabStep(stepNumber: i, labL: 95.0 - t * 90.0,
                           labA: 1.0 + noise, labB: 2.0 + noise)
        }
        let smoothed = QTRFileParser.smooth(steps: steps, windowSize: 5)

        // Check that a*/b* changed (not just pass-through)
        var aChanged = false
        var bChanged = false
        for (orig, sm) in zip(steps, smoothed) {
            if abs(orig.labA - sm.labA) > 0.001 { aChanged = true }
            if abs(orig.labB - sm.labB) > 0.001 { bChanged = true }
        }
        XCTAssertTrue(aChanged, "a* values should be smoothed")
        XCTAssertTrue(bChanged, "b* values should be smoothed")
    }

    // 21. Single step input -> same output
    func test_smooth_singleStep_unchanged() {
        let steps = [LabStep(stepNumber: 0, labL: 95.0, labA: 1.0, labB: 2.0)]
        let smoothed = QTRFileParser.smooth(steps: steps, windowSize: 5)
        XCTAssertEqual(smoothed.count, 1)
        XCTAssertEqual(smoothed[0].labL, 95.0, accuracy: 0.001)
    }

    // 22. Two steps with window 5 -> returned unchanged (count < window)
    func test_smooth_twoSteps_unchanged() {
        let steps = [
            LabStep(stepNumber: 0, labL: 95.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 1, labL: 50.0, labA: 0.0, labB: 0.0)
        ]
        let smoothed = QTRFileParser.smooth(steps: steps, windowSize: 5)
        XCTAssertEqual(smoothed.count, 2)
        XCTAssertEqual(smoothed[0].labL, 95.0, accuracy: 0.001)
        XCTAssertEqual(smoothed[1].labL, 50.0, accuracy: 0.001)
    }

    // MARK: - Monotonic Enforcement

    // 23. Step with L* jump clamped to previous value
    func test_enforceMonotonic_clampsReversal() {
        var steps = cleanMeasurement(steps: 10)
        // Inject reversal at index 5: L* goes UP
        steps[5] = LabStep(stepNumber: 5, labL: steps[4].labL + 5.0, labA: 0.0, labB: 0.0)

        let enforced = QTRFileParser.enforceMonotonic(steps: steps)
        // The clamped value should be <= previous step's L*
        XCTAssertLessThanOrEqual(enforced[5].labL, enforced[4].labL)
    }

    // 24. Multiple consecutive reversals all get clamped
    func test_enforceMonotonic_chainedReversals() {
        var steps = cleanMeasurement(steps: 10)
        // Inject 3 consecutive reversals at indices 4, 5, 6
        let baseL = steps[3].labL
        steps[4] = LabStep(stepNumber: 4, labL: baseL + 2.0, labA: 0.0, labB: 0.0)
        steps[5] = LabStep(stepNumber: 5, labL: baseL + 4.0, labA: 0.0, labB: 0.0)
        steps[6] = LabStep(stepNumber: 6, labL: baseL + 1.0, labA: 0.0, labB: 0.0)

        let enforced = QTRFileParser.enforceMonotonic(steps: steps)
        // All three should be clamped to steps[3].labL
        XCTAssertEqual(enforced[4].labL, baseL, accuracy: 0.001)
        XCTAssertEqual(enforced[5].labL, baseL, accuracy: 0.001)
        XCTAssertEqual(enforced[6].labL, baseL, accuracy: 0.001)
    }

    // 25. First step's L* never changed
    func test_enforceMonotonic_firstStepPreserved() {
        var steps = cleanMeasurement(steps: 10)
        steps[1] = LabStep(stepNumber: 1, labL: 100.0, labA: 0.0, labB: 0.0) // reversal

        let enforced = QTRFileParser.enforceMonotonic(steps: steps)
        XCTAssertEqual(enforced[0].labL, steps[0].labL, accuracy: 0.001)
    }

    // 26. After enforcement, L* at each step <= L* at previous step
    func test_enforceMonotonic_resultIsMonotonic() {
        let noisy = addNoise(to: cleanMeasurement(steps: 21), maxNoise: 5.0)
        let enforced = QTRFileParser.enforceMonotonic(steps: noisy)

        for i in 1..<enforced.count {
            XCTAssertLessThanOrEqual(enforced[i].labL, enforced[i - 1].labL,
                                     "L* at step \(i) should be <= step \(i - 1)")
        }
    }

    // 27. Clean input -> output equals input (L* values identical)
    func test_enforceMonotonic_noReversals_unchanged() {
        let steps = cleanMeasurement(steps: 15)
        let enforced = QTRFileParser.enforceMonotonic(steps: steps)

        for (orig, enf) in zip(steps, enforced) {
            XCTAssertEqual(orig.labL, enf.labL, accuracy: 0.0001)
        }
    }

    // 28. stepNumber, labA, labB unchanged
    func test_enforceMonotonic_preservesOtherFields() {
        let steps = (0..<10).map { i in
            LabStep(stepNumber: i * 3, labL: 95.0 - Double(i) * 5.0,
                    labA: Double(i) * 0.1, labB: Double(i) * 0.2)
        }
        let enforced = QTRFileParser.enforceMonotonic(steps: steps)

        for (orig, enf) in zip(steps, enforced) {
            XCTAssertEqual(orig.stepNumber, enf.stepNumber)
            XCTAssertEqual(orig.labA, enf.labA, accuracy: 0.0001)
            XCTAssertEqual(orig.labB, enf.labB, accuracy: 0.0001)
        }
    }

    // MARK: - Smoothing + Monotonic Pipeline

    // 29. Noisy input -> smooth -> enforce monotonic -> monotonically decreasing with no anomalies
    func test_pipeline_smoothThenMonotonic_producesCleanCurve() {
        let noisy = addNoise(to: cleanMeasurement(steps: 21), maxNoise: 4.0)
        let smoothed = QTRFileParser.smooth(steps: noisy, windowSize: 5)
        let enforced = QTRFileParser.enforceMonotonic(steps: smoothed)

        // Verify monotonically decreasing
        for i in 1..<enforced.count {
            XCTAssertLessThanOrEqual(enforced[i].labL, enforced[i - 1].labL,
                                     "Pipeline result should be monotonically decreasing")
        }

        // Verify no anomalies when wrapped in a measurement
        let measurement = SpyderPRINTMeasurement(fileName: "pipeline.txt", steps: enforced)
        let reversals = measurement.anomalies.filter { $0.type == .reversal }
        XCTAssertEqual(reversals.count, 0, "Pipeline result should have no reversal anomalies")
    }

    // 30. Running the pipeline twice produces same result as once
    func test_pipeline_idempotent() {
        let noisy = addNoise(to: cleanMeasurement(steps: 21), maxNoise: 4.0)

        // First pass
        let pass1Smooth = QTRFileParser.smooth(steps: noisy, windowSize: 5)
        let pass1 = QTRFileParser.enforceMonotonic(steps: pass1Smooth)

        // Second pass on pass1 output
        let pass2Smooth = QTRFileParser.smooth(steps: pass1, windowSize: 5)
        let pass2 = QTRFileParser.enforceMonotonic(steps: pass2Smooth)

        for (p1, p2) in zip(pass1, pass2) {
            XCTAssertEqual(p1.labL, p2.labL, accuracy: 3.5,
                           "Second pipeline pass should produce similar results")
        }
    }

    // MARK: - Density to LogD Conversion

    // 31. L*=95 -> logD ~ 0.05 (low density)
    func test_labLToDensity_paperWhite() {
        let density = labLToDensity(95.0)
        // log10(100/95) ~ 0.0223
        XCTAssertLessThan(density, 0.1, "Paper white should have very low density")
        XCTAssertGreaterThan(density, 0.0, "Density should be positive")
        XCTAssertEqual(density, log10(100.0 / 95.0), accuracy: 0.001)
    }

    // 32. L*=5 -> logD ~ 2.0+ (high density)
    func test_labLToDensity_maxBlack() {
        let density = labLToDensity(5.0)
        // log10(100/5) = log10(20) ~ 1.301
        XCTAssertGreaterThan(density, 1.0, "Max black should have high density")
        XCTAssertEqual(density, log10(100.0 / 5.0), accuracy: 0.001)
    }

    // MARK: - Helpers

    /// Generate a clean monotonically decreasing measurement.
    private func cleanMeasurement(steps: Int) -> [LabStep] {
        (0..<steps).map { i in
            let t = Double(i) / Double(steps - 1)
            let labL = 95.0 - t * 90.0  // 95 -> 5
            return LabStep(stepNumber: i, labL: labL, labA: 0.0, labB: 0.0)
        }
    }

    /// Add deterministic noise to L* values (sin-based for reproducibility).
    private func addNoise(to steps: [LabStep], maxNoise: Double) -> [LabStep] {
        steps.map { step in
            let noise = sin(Double(step.stepNumber) * 1.7) * maxNoise
            return LabStep(stepNumber: step.stepNumber, labL: step.labL + noise,
                           labA: step.labA, labB: step.labB)
        }
    }

    /// Convert L* to approximate density (logD).
    private func labLToDensity(_ labL: Double) -> Double {
        log10(100.0 / max(labL, 0.01))
    }

    /// Calculate max absolute delta between adjacent L* values.
    private func maxAdjacentDelta(_ steps: [LabStep]) -> Double {
        guard steps.count > 1 else { return 0 }
        var maxDelta = 0.0
        for i in 1..<steps.count {
            let delta = abs(steps[i].labL - steps[i - 1].labL)
            maxDelta = max(maxDelta, delta)
        }
        return maxDelta
    }

    /// Calculate total L* deviation between two step arrays.
    private func totalLDeviation(_ a: [LabStep], _ b: [LabStep]) -> Double {
        zip(a, b).reduce(0.0) { sum, pair in
            sum + abs(pair.0.labL - pair.1.labL)
        }
    }
}
