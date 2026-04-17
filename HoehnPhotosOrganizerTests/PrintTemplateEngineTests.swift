import XCTest
import AppKit
@testable import HoehnPhotosOrganizer

final class PrintTemplateEngineTests: XCTestCase {

    private var testImage: NSImage!

    override func setUp() {
        super.setUp()
        testImage = NSImage(size: NSSize(width: 1, height: 1))
        testImage.lockFocus()
        NSColor.gray.setFill()
        NSRect(origin: .zero, size: testImage.size).fill()
        testImage.unlockFocus()
    }

    override func tearDown() {
        testImage = nil
        super.tearDown()
    }

    // MARK: - PrintTemplate Identity & Codable

    func test_calibrationStrip_id_containsDimensions() {
        let template = PrintTemplate.calibrationStrip(columns: 4, rows: 2, brightnessRange: 0.3, saturationRange: 0.1)
        XCTAssertTrue(template.id.contains("4x2"), "Expected id to contain '4x2', got '\(template.id)'")
    }

    func test_digitalNegative_displayName() {
        XCTAssertEqual(PrintTemplate.digitalNegative.displayName, "Digital Negative")
    }

    func test_stepWedge_displayName_containsStepCount() {
        let template = PrintTemplate.stepWedge(steps: 21)
        XCTAssertTrue(template.displayName.contains("21"), "Expected displayName to contain '21', got '\(template.displayName)'")
    }

    func test_custom_displayName_matchesName() {
        let template = PrintTemplate.custom(name: "MyTemplate")
        XCTAssertEqual(template.displayName, "MyTemplate")
    }

    func test_printTemplate_codableRoundTrip_calibrationStrip() throws {
        let original = PrintTemplate.calibrationStrip(columns: 4, rows: 2, brightnessRange: 0.3, saturationRange: 0.1)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrintTemplate.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.displayName, original.displayName)
        // Verify the associated values survived the round trip
        if case .calibrationStrip(let c, let r, let b, let s) = decoded {
            XCTAssertEqual(c, 4)
            XCTAssertEqual(r, 2)
            XCTAssertEqual(b, 0.3, accuracy: 0.001)
            XCTAssertEqual(s, 0.1, accuracy: 0.001)
        } else {
            XCTFail("Decoded template is not .calibrationStrip")
        }
    }

    func test_printTemplate_codableRoundTrip_stepWedge() throws {
        let original = PrintTemplate.stepWedge(steps: 129)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrintTemplate.self, from: data)
        if case .stepWedge(let s) = decoded {
            XCTAssertEqual(s, 129)
        } else {
            XCTFail("Decoded template is not .stepWedge")
        }
    }

    func test_printTemplate_codableRoundTrip_custom() throws {
        let original = PrintTemplate.custom(name: "Platinum Print")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PrintTemplate.self, from: data)
        if case .custom(let name) = decoded {
            XCTAssertEqual(name, "Platinum Print")
        } else {
            XCTFail("Decoded template is not .custom")
        }
    }

    // MARK: - Default Brightness Steps

    func test_defaultBrightnessSteps_8tiles_symmetricAroundZero() {
        let steps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        XCTAssertEqual(steps.count, 8)
        // First should be approximately -0.15, last approximately +0.15
        XCTAssertEqual(steps.first!, -0.15, accuracy: 0.01)
        XCTAssertEqual(steps.last!, 0.15, accuracy: 0.01)
        // Symmetric: first + last should be approximately 0
        XCTAssertEqual(steps.first! + steps.last!, 0.0, accuracy: 0.001)
    }

    func test_defaultBrightnessSteps_1tile_isZero() {
        let steps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 1)
        assertArrayEqual(steps, [-0.15], accuracy: 0.01)
    }

    func test_defaultBrightnessSteps_0tiles_isEmpty() {
        let steps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 0)
        XCTAssertTrue(steps.isEmpty)
    }

    func test_defaultBrightnessSteps_range() {
        let steps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let range = steps.last! - steps.first!
        XCTAssertEqual(range, 0.30, accuracy: 0.001)
    }

    // MARK: - Calibration Strip Tiles

    func test_calibrationStripTiles_4x2_produces8Tiles() {
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let saturationSteps = Array(repeating: 0.0, count: 8)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 4, rows: 2,
            paperWidth: 13, paperHeight: 19, margin: 0.5,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        XCTAssertEqual(tiles.count, 8)
    }

    func test_calibrationStripTiles_allShareGroupID() {
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let saturationSteps = Array(repeating: 0.0, count: 8)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 4, rows: 2,
            paperWidth: 13, paperHeight: 19, margin: 0.5,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        let groupIDs = Set(tiles.compactMap(\.groupID))
        XCTAssertEqual(groupIDs.count, 1, "All tiles should share one groupID")
    }

    func test_calibrationStripTiles_groupLabelIsCalibrationStrip() {
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 4)
        let saturationSteps = Array(repeating: 0.0, count: 4)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 2, rows: 2,
            paperWidth: 13, paperHeight: 19, margin: 0.5,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        for tile in tiles {
            XCTAssertEqual(tile.groupLabel, "Calibration Strip")
        }
    }

    func test_calibrationStripTiles_eachHasTileLabel() {
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let saturationSteps = Array(repeating: 0.0, count: 8)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 4, rows: 2,
            paperWidth: 13, paperHeight: 19, margin: 0.5,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        for (i, tile) in tiles.enumerated() {
            XCTAssertNotNil(tile.tileLabel, "Tile \(i) should have a tileLabel")
            XCTAssertFalse(tile.tileLabel!.isEmpty, "Tile \(i) tileLabel should not be empty")
        }
    }

    func test_calibrationStripTiles_tilesWithinPaperBounds() {
        let paperWidth: CGFloat = 13
        let paperHeight: CGFloat = 19
        let margin: CGFloat = 0.5
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let saturationSteps = Array(repeating: 0.0, count: 8)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 4, rows: 2,
            paperWidth: paperWidth, paperHeight: paperHeight, margin: margin,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.position.x, margin - 0.01,
                                        "Tile x should be >= margin")
            XCTAssertGreaterThanOrEqual(tile.position.y, margin - 0.01,
                                        "Tile y should be >= margin")
            XCTAssertLessThanOrEqual(tile.position.x + tile.size.width, paperWidth - margin + 0.01,
                                     "Tile right edge should be <= paperWidth - margin")
            XCTAssertLessThanOrEqual(tile.position.y + tile.size.height, paperHeight - margin + 0.01,
                                     "Tile bottom edge should be <= paperHeight - margin")
        }
    }

    func test_calibrationStripTiles_tilesDontOverlap() {
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let saturationSteps = Array(repeating: 0.0, count: 8)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 4, rows: 2,
            paperWidth: 13, paperHeight: 19, margin: 0.5,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        for i in 0..<tiles.count {
            let rectA = CGRect(origin: tiles[i].position, size: tiles[i].size)
            for j in (i + 1)..<tiles.count {
                let rectB = CGRect(origin: tiles[j].position, size: tiles[j].size)
                XCTAssertFalse(rectA.intersects(rectB),
                               "Tile \(i) and tile \(j) should not overlap")
            }
        }
    }

    func test_calibrationStripTiles_eachHasCurveAdjustment() {
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let saturationSteps = Array(repeating: 0.0, count: 8)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 4, rows: 2,
            paperWidth: 13, paperHeight: 19, margin: 0.5,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        for (i, tile) in tiles.enumerated() {
            XCTAssertNotNil(tile.curveAdjustment, "Tile \(i) should have a curveAdjustment")
        }
    }

    func test_calibrationStripTiles_distinctBrightnessValues() {
        let brightnessSteps = PrintTemplateEngine.defaultBrightnessSteps(tileCount: 8)
        let saturationSteps = Array(repeating: 0.0, count: 8)
        let tiles = PrintTemplateEngine.calibrationStripTiles(
            image: testImage,
            columns: 4, rows: 2,
            paperWidth: 13, paperHeight: 19, margin: 0.5,
            brightnessSteps: brightnessSteps, saturationSteps: saturationSteps
        )
        let offsets = tiles.compactMap { $0.curveAdjustment?.brightnessOffset }
        let unique = Set(offsets)
        XCTAssertEqual(unique.count, tiles.count,
                       "Each tile should have a unique brightnessOffset")
    }

    // MARK: - Step Wedge Rendering

    func test_renderStepWedge_21Steps_returnsValidImage() {
        let result = PrintTemplateEngine.renderStepWedge(
            steps: 21, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        XCTAssertGreaterThan(result.image.size.width, 0)
        XCTAssertGreaterThan(result.image.size.height, 0)
        XCTAssertGreaterThan(result.inchWidth, 0)
        XCTAssertGreaterThan(result.inchHeight, 0)
    }

    func test_renderStepWedge_21Steps_widthMatchesUsable() {
        let paperWidth: CGFloat = 13
        let margin: CGFloat = 0.5
        let result = PrintTemplateEngine.renderStepWedge(
            steps: 21, paperWidth: paperWidth, paperHeight: 19, margin: margin
        )
        let expectedWidth = paperWidth - 2 * margin
        XCTAssertEqual(result.inchWidth, expectedWidth, accuracy: 0.01,
                       "inchWidth should equal paperWidth - 2*margin")
    }

    func test_renderStepWedge_2Steps_returnsValidImage() {
        let result = PrintTemplateEngine.renderStepWedge(
            steps: 2, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        XCTAssertGreaterThan(result.image.size.width, 0)
        XCTAssertGreaterThan(result.image.size.height, 0)
        XCTAssertGreaterThan(result.inchWidth, 0)
        XCTAssertGreaterThan(result.inchHeight, 0)
    }

    func test_renderStepWedge_1Step_returnsEmptyImage() {
        let result = PrintTemplateEngine.renderStepWedge(
            steps: 1, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        XCTAssertEqual(result.inchWidth, 0)
        XCTAssertEqual(result.inchHeight, 0)
    }

    func test_renderStepWedge_256Steps_16columns() {
        // 256 steps with 16 columns should produce 16 rows (256/16)
        let result = PrintTemplateEngine.renderStepWedge(
            steps: 256, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        // Multi-row layout: inchHeight should use the full usable height
        let usableH = 19.0 - 2.0 * 0.5
        XCTAssertEqual(result.inchHeight, usableH, accuracy: 0.01,
                       "256 steps should use the full usable paper height for a multi-row layout")
        XCTAssertGreaterThan(result.image.size.width, 0)
        XCTAssertGreaterThan(result.image.size.height, 0)
    }

    // MARK: - Step Wedge Tiles (Legacy)

    func test_stepWedgeTiles_21Steps_produces21Tiles() {
        let tiles = PrintTemplateEngine.stepWedgeTiles(
            steps: 21, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        XCTAssertEqual(tiles.count, 21)
    }

    func test_stepWedgeTiles_allShareGroupID() {
        let tiles = PrintTemplateEngine.stepWedgeTiles(
            steps: 21, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        let groupIDs = Set(tiles.compactMap(\.groupID))
        XCTAssertEqual(groupIDs.count, 1, "All step wedge tiles should share one groupID")
    }

    func test_stepWedgeTiles_tileLabelsDescending() {
        let tiles = PrintTemplateEngine.stepWedgeTiles(
            steps: 21, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        // First tile should be 255 (white), last should be 0 (black)
        let labels = tiles.compactMap { $0.tileLabel }.compactMap { Int($0) }
        XCTAssertEqual(labels.count, 21)
        XCTAssertEqual(labels.first, 255, "First tile should be 255 (white)")
        XCTAssertEqual(labels.last, 0, "Last tile should be 0 (black)")
        // Verify descending order
        for i in 0..<(labels.count - 1) {
            XCTAssertGreaterThanOrEqual(labels[i], labels[i + 1],
                                        "Tile labels should descend from white to black")
        }
    }

    func test_stepWedgeTiles_allWithinBounds() {
        let paperWidth: CGFloat = 13
        let paperHeight: CGFloat = 19
        let margin: CGFloat = 0.5
        let tiles = PrintTemplateEngine.stepWedgeTiles(
            steps: 21, paperWidth: paperWidth, paperHeight: paperHeight, margin: margin
        )
        for tile in tiles {
            XCTAssertGreaterThanOrEqual(tile.position.x, margin - 0.01)
            XCTAssertGreaterThanOrEqual(tile.position.y, margin - 0.01)
            XCTAssertLessThanOrEqual(tile.position.x + tile.size.width, paperWidth - margin + 0.01)
            XCTAssertLessThanOrEqual(tile.position.y + tile.size.height, paperHeight - margin + 0.01)
        }
    }

    func test_stepWedgeTiles_2Steps_minValid() {
        let tiles = PrintTemplateEngine.stepWedgeTiles(
            steps: 2, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        XCTAssertEqual(tiles.count, 2)
    }

    func test_stepWedgeTiles_1Step_empty() {
        let tiles = PrintTemplateEngine.stepWedgeTiles(
            steps: 1, paperWidth: 13, paperHeight: 19, margin: 0.5
        )
        XCTAssertTrue(tiles.isEmpty)
    }

    // MARK: - CanvasImage Computed Properties

    func test_canvasImage_defaultValues() {
        let canvas = CanvasImage(sourceImage: testImage)
        XCTAssertEqual(canvas.rotation, 0)
        XCTAssertTrue(canvas.aspectRatioLocked)
        XCTAssertEqual(canvas.borderWidthInches, 0)
    }
}

// MARK: - Helpers

private extension XCTestCase {
    /// Assert two Double arrays are equal within accuracy.
    func assertArrayEqual(_ lhs: [Double], _ rhs: [Double], accuracy: Double,
                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.count, rhs.count, "Array counts differ", file: file, line: line)
        for (i, (a, b)) in zip(lhs, rhs).enumerated() {
            XCTAssertEqual(a, b, accuracy: accuracy,
                           "Element \(i): \(a) != \(b)", file: file, line: line)
        }
    }
}
