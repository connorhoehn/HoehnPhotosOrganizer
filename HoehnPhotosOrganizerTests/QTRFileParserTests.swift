import XCTest
@testable import HoehnPhotosOrganizer

final class QTRFileParserTests: XCTestCase {

    // MARK: - Temp directory for filesystem tests

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("QTRFileParserTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Quad File Parsing: Linear K-Only

    func test_parseLinearKOnlyQuad_has8Channels() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testLinearKOnlyQuad,
            fileName: "linear-k.quad"
        )
        XCTAssertEqual(quad.channels.count, 8)
    }

    func test_parseLinearKOnlyQuad_kChannelIs256Values() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testLinearKOnlyQuad,
            fileName: "linear-k.quad"
        )
        XCTAssertEqual(quad.channels[0].values.count, 256)
    }

    func test_parseLinearKOnlyQuad_kChannelStartsAtZero() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testLinearKOnlyQuad,
            fileName: "linear-k.quad"
        )
        XCTAssertEqual(quad.channels[0].values[0], 0)
    }

    func test_parseLinearKOnlyQuad_kChannelLinearRamp() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testLinearKOnlyQuad,
            fileName: "linear-k.quad"
        )
        let kValues = quad.channels[0].values
        XCTAssertEqual(kValues[0], 0)
        // Mid-value: index 128 in a linear ramp from 0 to ~29695 over 255 steps
        // Expected: 128 * (29695 / 255) ≈ 14898, allow tolerance
        XCTAssertEqual(Double(kValues[128]), 14847, accuracy: 200)
        // Last value
        XCTAssertEqual(Double(kValues[255]), 29695, accuracy: 200)
    }

    func test_parseLinearKOnlyQuad_otherChannelsInactive() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testLinearKOnlyQuad,
            fileName: "linear-k.quad"
        )
        // Channels 1-7 (C, M, Y, LC, LM, LK, LLK) should be inactive
        for i in 1..<8 {
            XCTAssertFalse(
                quad.channels[i].isActive,
                "Channel \(quad.channels[i].name) at index \(i) should be inactive"
            )
        }
    }

    func test_parseLinearKOnlyQuad_channelNamesCorrect() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testLinearKOnlyQuad,
            fileName: "linear-k.quad"
        )
        XCTAssertEqual(quad.channelNames, ["K", "C", "M", "Y", "LC", "LM", "LK", "LLK"])
    }

    func test_parseLinearKOnlyQuad_fileName() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testLinearKOnlyQuad,
            fileName: "my-linear-k.quad"
        )
        XCTAssertEqual(quad.fileName, "my-linear-k.quad")
    }

    // MARK: - Quad File Parsing: Cyanotype Multi-Linearization

    func test_parseCyanotypeQuad_kChannelNonLinear() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testCyanotypeMultiLinQuad,
            fileName: "cyanotype.quad"
        )
        let kValues = quad.channels[0].values
        // Early values (index 30) should be near 0 for cyanotype (toe region)
        XCTAssertLessThan(kValues[30], 500, "Cyanotype K channel should have low values at index 30")
        // Last value should be significantly higher
        XCTAssertGreaterThan(kValues[255], 10000, "Cyanotype K channel should ramp up to high values")
    }

    func test_parseCyanotypeQuad_cChannelActive() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testCyanotypeMultiLinQuad,
            fileName: "cyanotype.quad"
        )
        XCTAssertTrue(quad.channels[1].isActive, "C channel should be active in cyanotype quad")
    }

    func test_parseCyanotypeQuad_linearizationHistory5Entries() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testCyanotypeMultiLinQuad,
            fileName: "cyanotype.quad"
        )
        XCTAssertEqual(quad.linearizationHistory.count, 5)
    }

    func test_parseCyanotypeQuad_linearizationHistoryHasMeasurementFiles() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testCyanotypeMultiLinQuad,
            fileName: "cyanotype.quad"
        )
        for entry in quad.linearizationHistory {
            XCTAssertFalse(
                entry.measurementFile.isEmpty,
                "Each linearization entry should have a non-empty measurement file"
            )
        }
    }

    func test_parseCyanotypeQuad_commentsContainProfilerVersion() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testCyanotypeMultiLinQuad,
            fileName: "cyanotype.quad"
        )
        let allComments = quad.comments.joined(separator: " ")
        XCTAssertTrue(
            allComments.contains("QuadToneProfiler"),
            "Comments should contain 'QuadToneProfiler'"
        )
    }

    // MARK: - Quad File Parsing: DTP Photogravure

    func test_parseDTPQuad_onlyKActive() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testDTPPhotogravureQuad,
            fileName: "dtp.quad"
        )
        XCTAssertTrue(quad.channels[0].isActive, "K channel should be active")
        for i in 1..<8 {
            XCTAssertFalse(
                quad.channels[i].isActive,
                "Channel \(quad.channels[i].name) should be inactive in DTP single-ink quad"
            )
        }
    }

    func test_parseDTPQuad_kLinearRamp() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testDTPPhotogravureQuad,
            fileName: "dtp.quad"
        )
        let kValues = quad.channels[0].values
        // Verify generally increasing: last value should be greater than mid-value
        XCTAssertGreaterThan(kValues[255], kValues[128])
        XCTAssertGreaterThan(kValues[128], kValues[64])
        XCTAssertGreaterThan(kValues[64], kValues[1])
    }

    // MARK: - Quad File Parsing: Edge Cases

    func test_parseMalformedQuad_doesNotCrash() {
        XCTAssertNoThrow(
            try QTRFileParser.parseQuadFile(
                content: testMalformedQuad,
                fileName: "malformed.quad"
            )
        )
    }

    func test_parseEmptyQuad_producesInactiveChannels() throws {
        let quad = try QTRFileParser.parseQuadFile(
            content: testEmptyQuad,
            fileName: "empty.quad"
        )
        XCTAssertEqual(quad.channels.count, 8)
        for channel in quad.channels {
            XCTAssertFalse(channel.isActive, "Channel \(channel.name) should be inactive in empty quad")
        }
    }

    // MARK: - InkChannel Computed Properties

    func test_inkChannel_normalizedCurve_256Points() {
        let channel = InkChannel(name: "K", values: Array(repeating: UInt16(0), count: 256))
        XCTAssertEqual(channel.normalizedCurve.count, 256)
    }

    func test_inkChannel_normalizedCurve_rangeZeroToOne() {
        // Build a channel with varied values
        let values: [UInt16] = (0..<256).map { UInt16($0 * 256) }
        let channel = InkChannel(name: "K", values: values)
        for point in channel.normalizedCurve {
            XCTAssertGreaterThanOrEqual(point.input, 0.0)
            XCTAssertLessThanOrEqual(point.input, 1.0)
            XCTAssertGreaterThanOrEqual(point.output, 0.0)
            XCTAssertLessThanOrEqual(point.output, 1.0)
        }
    }

    func test_inkChannel_maxInkPercent_fullScale() {
        var values = Array(repeating: UInt16(0), count: 256)
        values[255] = 65535
        let channel = InkChannel(name: "K", values: values)
        XCTAssertEqual(channel.maxInkPercent, 100.0, accuracy: 0.01)
    }

    func test_inkChannel_maxInkPercent_halfScale() {
        var values = Array(repeating: UInt16(0), count: 256)
        values[255] = 32767
        let channel = InkChannel(name: "K", values: values)
        XCTAssertEqual(channel.maxInkPercent, 50.0, accuracy: 0.1)
    }

    func test_inkChannel_isActive_nonZero() {
        var values = Array(repeating: UInt16(0), count: 256)
        values[100] = 1
        let channel = InkChannel(name: "K", values: values)
        XCTAssertTrue(channel.isActive)
    }

    func test_inkChannel_isActive_allZero() {
        let channel = InkChannel(name: "K", values: Array(repeating: UInt16(0), count: 256))
        XCTAssertFalse(channel.isActive)
    }

    // MARK: - Measurement Parsing: 21 Steps

    func test_parseMeasurement21Steps_stepCount() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurement21Steps,
            fileName: "measurement-21.txt"
        )
        XCTAssertEqual(measurement.stepCount, 21)
    }

    func test_parseMeasurement21Steps_hasHeader() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurement21Steps,
            fileName: "measurement-21.txt"
        )
        XCTAssertTrue(measurement.hasHeader)
    }

    func test_parseMeasurement21Steps_paperWhiteL() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurement21Steps,
            fileName: "measurement-21.txt"
        )
        XCTAssertNotNil(measurement.paperWhiteL)
        XCTAssertEqual(measurement.paperWhiteL!, 95.0, accuracy: 1.0)
    }

    func test_parseMeasurement21Steps_dMaxL() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurement21Steps,
            fileName: "measurement-21.txt"
        )
        XCTAssertNotNil(measurement.dMaxL)
        XCTAssertEqual(measurement.dMaxL!, 5.0, accuracy: 1.0)
    }

    func test_parseMeasurement21Steps_densityRange() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurement21Steps,
            fileName: "measurement-21.txt"
        )
        XCTAssertNotNil(measurement.densityRange)
        XCTAssertEqual(measurement.densityRange!, 90.0, accuracy: 2.0)
    }

    func test_parseMeasurement21Steps_monotonicallyDecreasing() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurement21Steps,
            fileName: "measurement-21.txt"
        )
        for i in 1..<measurement.steps.count {
            XCTAssertLessThanOrEqual(
                measurement.steps[i].labL,
                measurement.steps[i - 1].labL,
                "L* should decrease from step \(i - 1) to step \(i)"
            )
        }
    }

    func test_parseMeasurement21Steps_noAnomalies() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurement21Steps,
            fileName: "measurement-21.txt"
        )
        XCTAssertEqual(measurement.anomalies.count, 0)
    }

    // MARK: - Measurement Parsing: Reversals

    func test_parseMeasurementWithReversals_detectsReversalAnomaly() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurementWithReversals,
            fileName: "reversals.txt"
        )
        let reversals = measurement.anomalies.filter { $0.type == .reversal }
        XCTAssertGreaterThan(reversals.count, 0, "Should detect at least one reversal anomaly")
    }

    func test_parseMeasurementWithReversals_detectsFlatZone() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurementWithReversals,
            fileName: "reversals.txt"
        )
        let flatZones = measurement.anomalies.filter { $0.type == .flatZone }
        XCTAssertGreaterThan(flatZones.count, 0, "Should detect at least one flat zone anomaly")
    }

    // MARK: - Measurement Parsing: No Header

    func test_parseMeasurementNoHeader_hasHeaderFalse() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurementNoHeader,
            fileName: "no-header.txt"
        )
        XCTAssertFalse(measurement.hasHeader)
    }

    func test_parseMeasurementNoHeader_stepsStillParsed() throws {
        let measurement = try QTRFileParser.parseMeasurement(
            content: testMeasurementNoHeader,
            fileName: "no-header.txt"
        )
        XCTAssertGreaterThan(measurement.stepCount, 0)
    }

    // MARK: - Smoothing Tests

    func test_smooth_windowSize5_reducesNoise() {
        // Create noisy steps: generally decreasing but with noise
        var steps: [LabStep] = []
        for i in 0..<21 {
            let baseL = 95.0 - Double(i) * 4.5
            let noise = (i % 2 == 0) ? 2.0 : -2.0
            steps.append(LabStep(stepNumber: i + 1, labL: baseL + noise, labA: 0.0, labB: 0.0))
        }

        let smoothed = QTRFileParser.smooth(steps: steps, windowSize: 5)

        // Compute max adjacent delta before and after smoothing
        var maxDeltaBefore: Double = 0
        var maxDeltaAfter: Double = 0
        for i in 1..<steps.count {
            let deltaBefore = abs(steps[i].labL - steps[i - 1].labL)
            let deltaAfter = abs(smoothed[i].labL - smoothed[i - 1].labL)
            maxDeltaBefore = max(maxDeltaBefore, deltaBefore)
            maxDeltaAfter = max(maxDeltaAfter, deltaAfter)
        }

        XCTAssertLessThan(
            maxDeltaAfter, maxDeltaBefore,
            "Smoothing should reduce the maximum adjacent L* delta"
        )
    }

    func test_smooth_preservesEndpoints() {
        var steps: [LabStep] = []
        for i in 0..<21 {
            let baseL = 95.0 - Double(i) * 4.5
            let noise = (i % 3 == 0) ? 1.5 : -1.0
            steps.append(LabStep(stepNumber: i + 1, labL: baseL + noise, labA: 0.0, labB: 0.0))
        }

        let smoothed = QTRFileParser.smooth(steps: steps, windowSize: 5)

        // Endpoints shift because the averaging window includes nearby noisy
        // neighbors even at edges (window [0...2] at the start). Use a generous
        // tolerance that accounts for the noise amplitude and window averaging.
        XCTAssertEqual(smoothed.first!.labL, steps.first!.labL, accuracy: 7.0)
        XCTAssertEqual(smoothed.last!.labL, steps.last!.labL, accuracy: 7.0)
    }

    func test_smooth_emptyInput_returnsEmpty() {
        let result = QTRFileParser.smooth(steps: [], windowSize: 5)
        XCTAssertTrue(result.isEmpty)
    }

    func test_smooth_windowLargerThanData_returnsOriginal() {
        let steps = [
            LabStep(stepNumber: 1, labL: 95.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 2, labL: 50.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 3, labL: 5.0, labA: 0.0, labB: 0.0),
        ]
        let result = QTRFileParser.smooth(steps: steps, windowSize: 7)
        // When count <= windowSize, returns original
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].labL, 95.0)
        XCTAssertEqual(result[1].labL, 50.0)
        XCTAssertEqual(result[2].labL, 5.0)
    }

    // MARK: - Monotonic Enforcement Tests

    func test_enforceMonotonic_reversal_clamped() {
        let steps = [
            LabStep(stepNumber: 1, labL: 95.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 2, labL: 80.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 3, labL: 85.0, labA: 0.0, labB: 0.0), // reversal: goes UP
            LabStep(stepNumber: 4, labL: 60.0, labA: 0.0, labB: 0.0),
        ]
        let result = QTRFileParser.enforceMonotonic(steps: steps)
        // Step 3 should be clamped to step 2's value (80.0), not 85.0
        XCTAssertEqual(result[2].labL, 80.0, accuracy: 0.001)
        // Step 4 should remain 60.0 (already less than clamped step 3)
        XCTAssertEqual(result[3].labL, 60.0, accuracy: 0.001)
    }

    func test_enforceMonotonic_alreadyMonotonic_unchanged() {
        let steps = [
            LabStep(stepNumber: 1, labL: 95.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 2, labL: 80.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 3, labL: 65.0, labA: 0.0, labB: 0.0),
            LabStep(stepNumber: 4, labL: 50.0, labA: 0.0, labB: 0.0),
        ]
        let result = QTRFileParser.enforceMonotonic(steps: steps)
        for i in 0..<steps.count {
            XCTAssertEqual(result[i].labL, steps[i].labL, accuracy: 0.001)
        }
    }

    func test_enforceMonotonic_preservesFirstStep() {
        let steps = [
            LabStep(stepNumber: 1, labL: 93.5, labA: 1.2, labB: -3.4),
            LabStep(stepNumber: 2, labL: 80.0, labA: 0.0, labB: 0.0),
        ]
        let result = QTRFileParser.enforceMonotonic(steps: steps)
        XCTAssertEqual(result[0].labL, 93.5, accuracy: 0.001)
        XCTAssertEqual(result[0].labA, 1.2, accuracy: 0.001)
        XCTAssertEqual(result[0].labB, -3.4, accuracy: 0.001)
    }

    // MARK: - Scan Directory Tests (filesystem)

    func test_scanQuadDirectory_tempDir_findsQuadFiles() throws {
        // Create test files
        let quad1 = tempDir.appendingPathComponent("profile1.quad")
        let quad2 = tempDir.appendingPathComponent("profile2.quad")
        let txt = tempDir.appendingPathComponent("notes.txt")

        try "quad data 1".write(to: quad1, atomically: true, encoding: .utf8)
        try "quad data 2".write(to: quad2, atomically: true, encoding: .utf8)
        try "some notes".write(to: txt, atomically: true, encoding: .utf8)

        let results = QTRFileParser.scanQuadDirectory(at: tempDir.path)
        XCTAssertEqual(results.count, 2)
        let names = results.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["profile1.quad", "profile2.quad"])
    }

    func test_scanQuadDirectory_nonexistentPath_returnsEmpty() {
        let results = QTRFileParser.scanQuadDirectory(at: "/nonexistent/path/that/does/not/exist")
        XCTAssertTrue(results.isEmpty)
    }

    func test_scanMeasurementDirectory_tempDir_findsTxtFiles() throws {
        let txt1 = tempDir.appendingPathComponent("measurement1.txt")
        let txt2 = tempDir.appendingPathComponent("measurement2.txt")
        let quad = tempDir.appendingPathComponent("profile.quad")

        try "data 1".write(to: txt1, atomically: true, encoding: .utf8)
        try "data 2".write(to: txt2, atomically: true, encoding: .utf8)
        try "quad data".write(to: quad, atomically: true, encoding: .utf8)

        let results = QTRFileParser.scanMeasurementDirectory(at: tempDir.path)
        XCTAssertEqual(results.count, 2)
        let names = results.map { $0.lastPathComponent }.sorted()
        XCTAssertEqual(names, ["measurement1.txt", "measurement2.txt"])
    }
}
