import XCTest
@testable import HoehnPhotosOrganizer
import GRDB

@MainActor
final class MetadataExportTests: XCTestCase {

    private var db: AppDatabase!
    private var service: MetadataExportService!
    private var testPhoto: PhotoAsset!
    private var exportedURLs: [URL] = []

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        db = try AppDatabase.makeInMemory()
        service = MetadataExportService(db: db)

        // Build a PhotoAsset with user metadata and edit history.
        let metadataResult = MetadataExtractionResult(
            location: "beach",
            people: ["friend"],
            occasion: "vacation",
            mood: "joyful",
            keywords: ["golden hour", "ocean"],
            sceneType: nil,
            peopleDetected: nil
        )
        let metadataJSON = try JSONEncoder().encode(metadataResult)

        let edits: [[String: String]] = [
            ["field": "location", "oldValue": "", "newValue": "beach", "editedAt": "2026-03-01T10:00:00Z"],
            ["field": "mood",     "oldValue": "", "newValue": "joyful", "editedAt": "2026-03-01T10:01:00Z"]
        ]
        let editsJSON = try JSONSerialization.data(withJSONObject: edits)

        var photo = PhotoAsset.new(
            canonicalName: "TEST_\(UUID().uuidString)",
            role: .original,
            filePath: "/tmp/test_photo.jpg",
            fileSize: 1_024
        )
        photo.userMetadataJson = String(data: metadataJSON, encoding: .utf8)
        photo.metadataEdits = String(data: editsJSON, encoding: .utf8)
        photo.rawExifJson = "{\"Make\":\"Nikon\",\"Model\":\"Z9\"}"

        try await db.dbPool.write { try photo.insert($0) }
        testPhoto = photo
    }

    override func tearDown() async throws {
        // Clean up any sidecar files written during the test.
        let fm = FileManager.default
        for url in exportedURLs {
            try? fm.removeItem(at: url)
        }
        exportedURLs = []
        service = nil
        db = nil
        testPhoto = nil
    }

    // MARK: - Tests

    /// Export a photo and verify the result is valid, parseable JSON.
    func testMetadataExportGeneratesValidJSON() async throws {
        let url = try await service.exportMetadataAsJSON(photoId: testPhoto.id)
        exportedURLs.append(url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Sidecar JSON file must exist on disk after export")

        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(PhotoExportPayload.self, from: data)

        XCTAssertEqual(payload.photo.id, testPhoto.id)
        XCTAssertEqual(payload.photo.canonicalName, testPhoto.canonicalName)
        XCTAssertFalse(payload.exportTimestamp.isEmpty, "export_timestamp must be non-empty")
    }

    /// Verify the sidecar file path follows the {canonicalId}.json convention.
    func testSidecarFileLocationMatchesPhotoPath() async throws {
        let url = try await service.exportMetadataAsJSON(photoId: testPhoto.id)
        exportedURLs.append(url)

        let expectedFilename = "\(testPhoto.canonicalName).json"
        XCTAssertEqual(url.lastPathComponent, expectedFilename,
                       "Sidecar filename must be {canonicalName}.json")
        XCTAssertTrue(url.path.contains("exports"),
                      "Sidecar must be written inside the exports/ directory")
    }

    /// Verify that thread entries added to the photo appear in the exported JSON.
    func testExportIncludesThreadHistory() async throws {
        // Insert 3 thread entries.
        let repo = ThreadRepository(db: db)
        try await repo.addEntry(photoId: testPhoto.id, kind: "text_note",
                                 contentJson: "{\"text\":\"First note\"}", authoredBy: "user")
        try await repo.addEntry(photoId: testPhoto.id, kind: "ai_turn",
                                 contentJson: "{\"text\":\"AI response\"}", authoredBy: "ai")
        try await repo.addEntry(photoId: testPhoto.id, kind: "text_note",
                                 contentJson: "{\"text\":\"Third note\"}", authoredBy: "user")

        let url = try await service.exportMetadataAsJSON(photoId: testPhoto.id)
        exportedURLs.append(url)

        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(PhotoExportPayload.self, from: data)

        XCTAssertEqual(payload.thread.count, 3,
                       "All 3 thread entries must appear in the exported JSON thread array")
        XCTAssertEqual(payload.thread[0].kind, "text_note")
        XCTAssertEqual(payload.thread[1].kind, "ai_turn")
        XCTAssertEqual(payload.thread[1].authoredBy, "ai")
    }

    /// Verify that metadata_edits array is non-empty when edits exist.
    func testExportPreservesMetadataEditHistory() async throws {
        let url = try await service.exportMetadataAsJSON(photoId: testPhoto.id)
        exportedURLs.append(url)

        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(PhotoExportPayload.self, from: data)

        XCTAssertFalse(payload.metadataEdits.isEmpty,
                       "metadata_edits must be non-empty when the photo has edit history")
        XCTAssertEqual(payload.metadataEdits.count, 2,
                       "Both edit records must appear in the exported JSON")

        let locationEdit = payload.metadataEdits.first(where: { $0.field == "location" })
        XCTAssertNotNil(locationEdit, "Edit record for 'location' field must be present")
        XCTAssertEqual(locationEdit?.newValue, "beach")
    }
}
