import XCTest
import Foundation
@testable import HoehnPhotosOrganizer

final class XMPSidecarServiceTests: XCTestCase {
    var service: XMPSidecarService!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        service = XMPSidecarService()
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // Test 1: Read print metadata from XMP sidecar file
    func testReadPrintMetadata() throws {
        // Create a sample XMP sidecar with print namespace attributes
        let xmpContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:print="http://hoehns.photo/print-workflow/"
              print:printType="platinum_palladium"
              print:paper="Platinum Paper 100g"
              print:outcome="pass"
              print:outcomeNotes="Excellent density"
              print:curveFile="Density_v2.acv"
              print:loggedAt="2026-03-15T14:30:00Z"
            />
          </rdf:RDF>
        </x:xmpmeta>
        """

        let sidecarFile = tempDir.appendingPathComponent("test.xmp")
        try xmpContent.write(to: sidecarFile, atomically: true, encoding: .utf8)

        // Act: Read metadata
        let metadata = try service.readPrintMetadata(from: sidecarFile)

        // Assert: All print attributes extracted correctly
        XCTAssertEqual(metadata["printType"], "platinum_palladium")
        XCTAssertEqual(metadata["paper"], "Platinum Paper 100g")
        XCTAssertEqual(metadata["outcome"], "pass")
        XCTAssertEqual(metadata["outcomeNotes"], "Excellent density")
        XCTAssertEqual(metadata["curveFile"], "Density_v2.acv")
        XCTAssertEqual(metadata["loggedAt"], "2026-03-15T14:30:00Z")
    }

    // Test 2: Write print metadata to new XMP sidecar file
    func testWritePrintMetadata() throws {
        // Create a test PrintAttempt
        let attempt = PrintAttempt(
            id: "test-001",
            photoId: "photo-001",
            printType: .platinumPalladium,
            paper: "Platinum Paper 100g",
            outcome: .pass,
            outcomeNotes: "Excellent density and tone separation",
            curveFileId: "curve-123",
            curveFileName: "Density_v2.acv",
            printPhotoId: nil,
            createdAt: ISO8601DateFormatter().date(from: "2026-03-15T14:30:00Z") ?? Date(),
            updatedAt: Date(),
            processSpecificFields: [:]
        )

        let sidecarFile = tempDir.appendingPathComponent("test_new.xmp")

        // Act: Write metadata to new file
        try service.writePrintMetadata(to: sidecarFile, attempt: attempt, mergeWithExisting: false)

        // Assert: File created and contains print metadata
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarFile.path))
        let content = try String(contentsOf: sidecarFile, encoding: .utf8)
        XCTAssertTrue(content.contains("platinum_palladium"))
        XCTAssertTrue(content.contains("Platinum Paper 100g"))
        XCTAssertTrue(content.contains("pass"))
    }

    // Test 3: Merge XMP metadata preserves existing non-print fields
    func testMergeXMPMetadata() throws {
        // Create existing XMP with Lightroom metadata
        let existingXMP = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:lr="http://ns.adobe.com/lightroom/1.0/"
              lr:rating="5"
              lr:colorLabels="1"
            />
          </rdf:RDF>
        </x:xmpmeta>
        """

        let sidecarFile = tempDir.appendingPathComponent("test_merge.xmp")
        try existingXMP.write(to: sidecarFile, atomically: true, encoding: .utf8)

        // Create a test PrintAttempt
        let attempt = PrintAttempt(
            id: "test-002",
            photoId: "photo-002",
            printType: .cyanotype,
            paper: "Cyanotype Paper",
            outcome: .needsAdjustment,
            outcomeNotes: "Adjust exposure",
            curveFileId: nil,
            curveFileName: nil,
            printPhotoId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: [:]
        )

        // Act: Write metadata with merge enabled
        try service.writePrintMetadata(to: sidecarFile, attempt: attempt, mergeWithExisting: true)

        // Assert: Both Lightroom and print metadata present
        let merged = try String(contentsOf: sidecarFile, encoding: .utf8)
        XCTAssertTrue(merged.contains("cyanotype"), "Print type should be in merged XMP")
        XCTAssertTrue(merged.contains("lr:rating"), "Lightroom rating should be preserved")
        XCTAssertTrue(merged.contains("lr:colorLabels"), "Lightroom color labels should be preserved")
    }

    // Test 4: Round-trip (read -> write -> read) preserves metadata
    func testXMPRoundTrip() throws {
        // Create initial XMP
        let originalXMP = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about=""
              xmlns:print="http://hoehns.photo/print-workflow/"
              print:printType="silver_gelatin_darkroom"
              print:paper="Ilford Fiber Paper"
              print:outcome="pass"
              print:outcomeNotes="Perfect contrast"
              print:curveFile=""
              print:loggedAt="2026-03-15T10:00:00Z"
            />
          </rdf:RDF>
        </x:xmpmeta>
        """

        let sidecarFile = tempDir.appendingPathComponent("test_roundtrip.xmp")
        try originalXMP.write(to: sidecarFile, atomically: true, encoding: .utf8)

        // Act: Read metadata
        let readMetadata = try service.readPrintMetadata(from: sidecarFile)

        // Create a PrintAttempt from read metadata
        let attempt = PrintAttempt(
            id: "test-003",
            photoId: "photo-003",
            printType: PrintType(rawValue: readMetadata["printType"] ?? "") ?? .silverGelatinDarkroom,
            paper: readMetadata["paper"] ?? "",
            outcome: PrintOutcome(rawValue: readMetadata["outcome"] ?? "") ?? .testing,
            outcomeNotes: readMetadata["outcomeNotes"] ?? "",
            curveFileId: nil,
            curveFileName: readMetadata["curveFile"]?.isEmpty == false ? readMetadata["curveFile"] : nil,
            printPhotoId: nil,
            createdAt: Date(),
            updatedAt: Date(),
            processSpecificFields: [:]
        )

        // Write back
        try service.writePrintMetadata(to: sidecarFile, attempt: attempt, mergeWithExisting: false)

        // Read again
        let finalMetadata = try service.readPrintMetadata(from: sidecarFile)

        // Assert: Key fields preserved through round-trip
        XCTAssertEqual(finalMetadata["printType"], "silver_gelatin_darkroom")
        XCTAssertEqual(finalMetadata["paper"], "Ilford Fiber Paper")
        XCTAssertEqual(finalMetadata["outcome"], "pass")
        XCTAssertEqual(finalMetadata["outcomeNotes"], "Perfect contrast")
    }
}
