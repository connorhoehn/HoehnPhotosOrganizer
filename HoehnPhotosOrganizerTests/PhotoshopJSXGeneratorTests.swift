import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

// MARK: - PhotoshopJSXGeneratorTests
// Requirements: M7.5 — Generate Photoshop JSX scripts from ToneMappingCurve data
//               EXT-3 — AppleScript / JSX automation to apply curves in Photoshop

final class PhotoshopJSXGeneratorTests: XCTestCase {

    override func setUp() async throws {}

    override func tearDown() async throws {}

    // M7.5 / EXT-3: Given a CurveData (CSV format), the generator produces a JSX string that
    // creates a valid Photoshop Curves action descriptor
    func testGenerateJSX_fromCurveData_producesValidACVAction() async throws {
        let generator = PhotoshopJSXGenerator()

        // Build a CSV curve: tab-separated "x\ty" lines
        let csvLines = ["0\t0", "64\t70", "192\t210", "255\t255"]
        let csvString = csvLines.joined(separator: "\n")
        let csvData = Data(csvString.utf8)

        let curveData = CurveData(
            id: UUID().uuidString,
            format: "csv",
            data: csvData,
            description: "Test curve",
            createdAt: Date()
        )

        let jsx = try await generator.generateJSX(from: curveData)

        // JSX must contain Photoshop action descriptor keywords
        XCTAssertTrue(jsx.contains("charIDToTypeID"), "JSX must use charIDToTypeID() API")
        XCTAssertTrue(jsx.contains("ActionDescriptor"), "JSX must create ActionDescriptor")
        XCTAssertTrue(jsx.contains("executeAction"), "JSX must call executeAction")
        XCTAssertFalse(jsx.isEmpty, "JSX must not be empty")
    }

    // M7.5 / EXT-3: The generated JSX curve descriptor matches Photoshop's expected
    // ActionDescriptor format (pointList + curvePoint keys, channel index)
    func testGenerateJSX_curveApplication_matchesPhotoshopDescriptorFormat() async throws {
        let generator = PhotoshopJSXGenerator()

        let csvLines = ["0\t0", "128\t140", "255\t255"]
        let csvString = csvLines.joined(separator: "\n")
        let csvData = Data(csvString.utf8)

        let curveData = CurveData(
            id: UUID().uuidString,
            format: "csv",
            data: csvData,
            description: "Test format curve",
            createdAt: Date()
        )

        let jsx = try await generator.generateJSX(from: curveData)

        // Must use correct Photoshop 4-char codes
        XCTAssertTrue(jsx.contains("\"hrzn\""), "JSX must contain 'hrzn' (horizontal/input) point field")
        XCTAssertTrue(jsx.contains("\"vrtn\""), "JSX must contain 'vrtn' (vertical/output) point field")
        XCTAssertTrue(jsx.contains("putInteger"), "JSX must use putInteger for curve point coordinates")
        XCTAssertTrue(jsx.contains("putObject"), "JSX must use putObject to add curve points")
    }

    // M7.5 (checkpoint): Running the generated JSX against a live Photoshop instance
    // applies the curve correctly — requires Photoshop to be running (human checkpoint)
    func testJSXGeneration_roundTrip_withActualPhotoshop() async throws {
        throw XCTSkip("TODO: Implement M7.5 — Live Photoshop round-trip test requires human checkpoint (Photoshop must be running)")
    }

    // M7.5: Passing nil or empty curve data returns an appropriate error (not a crash)
    func testJSXGeneration_errorHandling_invalidCurveData() async throws {
        let generator = PhotoshopJSXGenerator()

        // Empty data — should throw JSXGenerationError
        let emptyData = Data()
        let curveData = CurveData(
            id: UUID().uuidString,
            format: "csv",
            data: emptyData,
            description: "Invalid curve",
            createdAt: Date()
        )

        do {
            _ = try await generator.generateJSX(from: curveData)
            XCTFail("Expected JSXGenerationError to be thrown for empty curve data")
        } catch let error as JSXGenerationError {
            // Expected: invalid format or no points
            switch error {
            case .invalidCurveFormat, .pointsOutOfRange, .generationFailed:
                break // Any of these is acceptable
            }
        } catch {
            XCTFail("Expected JSXGenerationError but got: \(error)")
        }
    }
}
