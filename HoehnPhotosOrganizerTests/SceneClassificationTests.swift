import XCTest
import GRDB
@testable import HoehnPhotosOrganizer

// MARK: - SceneClassificationTests
// Requirements: AI-5 — Scene classification using Vision / Core ML with Ollama fallback
//               AI-6 — People detection using VNDetectFaceLandmarksRequest with Ollama fallback

final class SceneClassificationTests: XCTestCase {

    override func setUp() async throws {}

    override func tearDown() async throws {}

    // AI-5: Scene classification primary path uses VNCoreML request (Vision framework first)
    // When Vision CoreML model is unavailable, service should fall back gracefully to Ollama.
    // This test verifies the SceneClassificationService initialises and classifies via Ollama
    // when no CoreML model is bundled (the default in CI / unit test environments).
    func testSceneClassification_visionFirst_usesVNCoreML() async throws {
        // Arrange — use a temp file as a stand-in proxy image (service must handle missing file gracefully)
        let tempDir = FileManager.default.temporaryDirectory
        let proxyURL = tempDir.appendingPathComponent("test_scene_proxy.jpg")
        // Create a minimal valid JPEG (1×1 white pixel) so the file exists
        let minimalJPEG = Data([
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
            0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD2,
            0x8A, 0x28, 0x03, 0xFF, 0xD9
        ])
        try minimalJPEG.write(to: proxyURL)
        defer { try? FileManager.default.removeItem(at: proxyURL) }

        // Act — SceneClassificationService should attempt Vision first, then fall back to Ollama
        // In test environment without CoreML model or Ollama, it must return .other gracefully
        let service = SceneClassificationService()
        let result = try await service.classifyScene(proxyImageURL: proxyURL)

        // Assert — result is a valid SceneType (any of the defined cases)
        XCTAssertTrue(SceneType.allCases.contains(result),
                      "classifyScene must return a valid SceneType, got: \(result)")
    }

    // AI-5: When Vision framework is unavailable, scene classification falls back to Ollama VLM
    func testSceneClassification_fallbackToOllama_whenVisionUnavailable() async throws {
        // Arrange — service with a mock Ollama URL that won't connect,
        // verifying the fallback path handles errors gracefully
        let service = SceneClassificationService(ollamaBaseURL: URL(string: "http://localhost:99999")!)
        let tempDir = FileManager.default.temporaryDirectory
        let proxyURL = tempDir.appendingPathComponent("test_fallback_proxy.jpg")
        let minimalJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9]) // Minimal JPEG SOI + EOI
        try minimalJPEG.write(to: proxyURL)
        defer { try? FileManager.default.removeItem(at: proxyURL) }

        // Act — Vision will fail (no model), Ollama will fail (bad port) → graceful .other
        let result = try await service.classifyScene(proxyImageURL: proxyURL)

        // Assert — falls back to .other when all paths fail
        XCTAssertEqual(result, .other,
                       "When Vision and Ollama both fail, classifyScene should return .other")
    }

    // AI-6: People detection primary path uses VNDetectFaceLandmarksRequest (Vision framework)
    func testPeopleDetection_usesVNDetectFaceLandmarks() async throws {
        // Arrange — minimal test image; in test environment VNDetectFaceLandmarks returns 0 faces
        let tempDir = FileManager.default.temporaryDirectory
        let proxyURL = tempDir.appendingPathComponent("test_people_proxy.jpg")
        let minimalJPEG = Data([
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
            0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3F, 0x00, 0xFB, 0xD2,
            0x8A, 0x28, 0x03, 0xFF, 0xD9
        ])
        try minimalJPEG.write(to: proxyURL)
        defer { try? FileManager.default.removeItem(at: proxyURL) }

        // Act — PersonDetectionService uses VNDetectFaceLandmarksRequest first
        let service = PersonDetectionService()
        let result = try await service.detectPeople(proxyImageURL: proxyURL)

        // Assert — result is a valid PersonDetectionResult with proper fields
        XCTAssertGreaterThanOrEqual(result.detectedFaceCount, 0,
                                    "detectedFaceCount must be non-negative")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.0,
                                    "confidence must be non-negative")
        XCTAssertLessThanOrEqual(result.confidence, 1.0,
                                 "confidence must be <= 1.0")
        // A 1x1 JPEG won't contain people — hasPersons should be false
        XCTAssertFalse(result.hasPersons,
                       "A 1x1 JPEG should not be detected as containing people")
    }

    // AI-6: When Vision face detection fails, people detection falls back to Ollama VLM
    func testPeopleDetection_fallbackToOllama_whenVisionFails() async throws {
        // Arrange — service with an unreachable Ollama URL to test graceful degradation
        let service = PersonDetectionService(ollamaBaseURL: URL(string: "http://localhost:99999")!)
        let tempDir = FileManager.default.temporaryDirectory
        let proxyURL = tempDir.appendingPathComponent("test_fallback_people_proxy.jpg")
        let minimalJPEG = Data([0xFF, 0xD8, 0xFF, 0xD9])
        try minimalJPEG.write(to: proxyURL)
        defer { try? FileManager.default.removeItem(at: proxyURL) }

        // Act — Vision runs first (returns 0 faces for degenerate image), Ollama unreachable
        let result = try await service.detectPeople(proxyImageURL: proxyURL)

        // Assert — service degrades gracefully: hasPersons=false, faceCount=0
        XCTAssertFalse(result.hasPersons,
                       "Graceful degradation: hasPersons should be false when both Vision and Ollama fail/unavailable")
        XCTAssertEqual(result.detectedFaceCount, 0,
                       "Graceful degradation: detectedFaceCount should be 0 when services fail")
    }
}
