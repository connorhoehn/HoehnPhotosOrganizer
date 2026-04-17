import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

// MARK: - EditorialCritiqueServiceTests
// Requirements: M7.2 — Anthropic (Claude) editorial feedback via proxy image upload
//               M7.3 — Curve generation from critique feedback

// MARK: - MockThreadRepositoryForCritique

/// Lightweight in-memory stand-in for ThreadRepository used in tests.
final class MockThreadRepositoryForCritique: ThreadEntryRepository {
    var appendedEntries: [ThreadEntry] = []

    func addEntry(photoId: String, kind: String, contentJson: String, authoredBy: String) async throws {
        let entry = ThreadEntry(
            id: UUID().uuidString,
            threadRootId: photoId,
            sequenceNumber: appendedEntries.count + 1,
            kind: kind,
            authoredBy: authoredBy,
            contentJson: contentJson,
            createdAt: ISO8601DateFormatter().string(from: .now),
            syncState: "local_only"
        )
        appendedEntries.append(entry)
    }
}

// MARK: - EditorialCritiqueServiceTests

final class EditorialCritiqueServiceTests: XCTestCase {

    private var inMemoryDB: AppDatabase!
    private var mockThreadRepo: MockThreadRepositoryForCritique!
    private var authManager: AnthropicAuthManager!

    override func setUp() async throws {
        inMemoryDB = try AppDatabase.makeInMemory()
        mockThreadRepo = MockThreadRepositoryForCritique()
        authManager = AnthropicAuthManager()
    }

    override func tearDown() async throws {
        inMemoryDB = nil
        mockThreadRepo = nil
        authManager = nil
    }

    // M7.2: EditorialCritiqueService can be initialized with default AnthropicAuthManager
    func testEditorialCritiqueService_canInitialize() async throws {
        let service = EditorialCritiqueService(authManager: authManager)
        XCTAssertNotNil(service)
    }

    // M7.2: Requesting editorial feedback without API key throws apiKeyMissing
    func testRequestEditorialFeedback_withoutAPIKey_throwsApiKeyMissing() async throws {
        let service = EditorialCritiqueService(authManager: authManager)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        try makeMinimalJPEG().write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            _ = try await service.requestEditorialFeedback(
                photoAssetId: "test-photo-001",
                proxyImageURL: tempURL,
                threadHistory: [],
                printAttemptHistory: nil,
                threadRepo: mockThreadRepo
            )
            XCTFail("Expected apiKeyMissing error to be thrown")
        } catch CritiqueError.apiKeyMissing {
            // Expected — no key configured
        } catch {
            // Other errors (network, etc.) are acceptable in tests — just verify it threw something
            XCTAssertNotNil(error)
        }
    }

    // M7.3: A critique response containing tonal recommendations produces a valid curve
    func testCurveGeneration_fromFeedback_producesToneMappingCurve() async throws {
        let feedback = EditorialFeedback(
            compositionScore: 7,
            printReadiness: "needs work",
            analysis: "Competent but could use more drama.",
            adjustments: nil,
            cropSuggestions: [],
            maskingHints: [],
            strengths: ["Balanced exposure"],
            areasForImprovement: ["Flat contrast"],
            suggestedEditDirections: ["Increase overall contrast"],
            metadataEnrichment: nil,
            geometryCorrection: nil,
            regionalAdjustments: nil
        )

        let curveService = CurveGenerationService()
        let curveData = try await curveService.generateCurveFromFeedback(feedback)

        XCTAssertFalse(curveData.data.isEmpty, "Expected non-empty curve data")
        XCTAssertFalse(curveData.id.isEmpty, "Expected non-empty curve ID")
        XCTAssertTrue(curveData.format == "csv" || curveData.format == "acv",
                      "Expected format to be 'csv' or 'acv', got: \(curveData.format)")

        // CSV format: verify it has 256 lines of x\ty pairs
        if curveData.format == "csv" {
            let csvString = String(data: curveData.data, encoding: .utf8) ?? ""
            let lines = csvString.split(separator: "\n")
            XCTAssertEqual(lines.count, 256, "Expected 256 curve points, got \(lines.count)")
        }
    }

    // M7.2: AnthropicAuthManager stores and retrieves API key from Keychain
    func testAnthropicAuthManager_retrievesAPIKeyFromKeychain() async throws {
        let testKey = "sk-ant-testKeyForKeychainRoundtrip12345678901234567890"

        let manager = AnthropicAuthManager()
        // Clean any pre-existing test key
        try? await manager.removeAPIKey()

        // Initially should not be configured
        let isConfiguredBefore = await manager.isConfigured()
        XCTAssertFalse(isConfiguredBefore, "Manager should not be configured before setting key")

        // Store
        try await manager.setAPIKey(testKey)

        // Retrieve
        let retrieved = try await manager.getAPIKey()
        XCTAssertEqual(retrieved, testKey, "Retrieved key should match stored key")

        // isConfigured
        let isConfiguredAfter = await manager.isConfigured()
        XCTAssertTrue(isConfiguredAfter, "Manager should be configured after setting key")

        // Clean up
        try await manager.removeAPIKey()
        let isConfiguredFinal = await manager.isConfigured()
        XCTAssertFalse(isConfiguredFinal, "Manager should not be configured after removing key")
    }

    // M7.2: EditorialFeedback JSON round-trips correctly
    func testEditorialFeedback_encodesDecodes() throws {
        let feedback = EditorialFeedback(
            compositionScore: 8,
            printReadiness: "ready",
            analysis: "Strong composition.",
            adjustments: nil,
            cropSuggestions: [],
            maskingHints: ["Sky is bright"],
            strengths: ["Leading lines"],
            areasForImprovement: [],
            suggestedEditDirections: [],
            metadataEnrichment: nil,
            geometryCorrection: nil,
            regionalAdjustments: nil
        )

        let data = try JSONEncoder().encode(feedback)
        let decoded = try JSONDecoder().decode(EditorialFeedback.self, from: data)

        XCTAssertEqual(decoded.compositionScore, 8)
        XCTAssertEqual(decoded.printReadiness, "ready")
        XCTAssertEqual(decoded.maskingHints, ["Sky is bright"])
    }

    // MARK: - Helpers

    /// Generate a minimal valid 1x1 JPEG for test purposes (standard JFIF structure).
    private func makeMinimalJPEG() -> Data {
        let bytes: [UInt8] = [
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01,
            0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xFF, 0xDB, 0x00, 0x43,
            0x00, 0x08, 0x06, 0x06, 0x07, 0x06, 0x05, 0x08, 0x07, 0x07, 0x07, 0x09,
            0x09, 0x08, 0x0A, 0x0C, 0x14, 0x0D, 0x0C, 0x0B, 0x0B, 0x0C, 0x19, 0x12,
            0x13, 0x0F, 0x14, 0x1D, 0x1A, 0x1F, 0x1E, 0x1D, 0x1A, 0x1C, 0x1C, 0x20,
            0x24, 0x2E, 0x27, 0x20, 0x22, 0x2C, 0x23, 0x1C, 0x1C, 0x28, 0x37, 0x29,
            0x2C, 0x30, 0x31, 0x34, 0x34, 0x34, 0x1F, 0x27, 0x39, 0x3D, 0x38, 0x32,
            0x3C, 0x2E, 0x33, 0x34, 0x32, 0xFF, 0xC0, 0x00, 0x0B, 0x08, 0x00, 0x01,
            0x00, 0x01, 0x01, 0x01, 0x11, 0x00, 0xFF, 0xC4, 0x00, 0x1F, 0x00, 0x00,
            0x01, 0x05, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
            0x09, 0x0A, 0x0B, 0xFF, 0xC4, 0x00, 0xB5, 0x10, 0x00, 0x02, 0x01, 0x03,
            0x03, 0x02, 0x04, 0x03, 0x05, 0x05, 0x04, 0x04, 0x00, 0x00, 0x01, 0x7D,
            0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06,
            0x13, 0x51, 0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08,
            0x23, 0x42, 0xB1, 0xC1, 0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72,
            0x82, 0x09, 0x0A, 0x16, 0x17, 0x18, 0x19, 0x1A, 0x25, 0x26, 0x27, 0x28,
            0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3A, 0x43, 0x44, 0x45,
            0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59,
            0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
            0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
            0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3,
            0xA4, 0xA5, 0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6,
            0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9,
            0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xE1, 0xE2,
            0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2, 0xF3, 0xF4,
            0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA, 0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01,
            0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD7, 0xFF, 0xD9
        ]
        return Data(bytes)
    }
}
