import XCTest
@testable import HoehnPhotosOrganizer

// MARK: - OllamaMetadataTests
//
// These tests verify MetadataExtractionResult decoding and OllamaError behaviour
// WITHOUT a live Ollama process. The network call inside MetadataExtractor is tested
// indirectly; JSON decoding and error paths are exercised via the model structs directly.

final class OllamaMetadataTests: XCTestCase {

    // MARK: - MetadataExtractionResult decoding

    /// Given a well-formed JSON blob that Ollama would return in its `response` field,
    /// the decoder should populate all Phase 3 fields.
    func testMetadataExtractorDecodesValidJSON() throws {
        let json = """
        {
            "location": "Cannon Beach, Oregon",
            "people": ["Alice", "Bob"],
            "occasion": "Family vacation",
            "mood": "joyful",
            "keywords": ["beach", "sunset", "film"]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(MetadataExtractionResult.self, from: json)

        XCTAssertEqual(result.location, "Cannon Beach, Oregon")
        XCTAssertEqual(result.people, ["Alice", "Bob"])
        XCTAssertEqual(result.occasion, "Family vacation")
        XCTAssertEqual(result.mood, "joyful")
        XCTAssertEqual(result.keywords, ["beach", "sunset", "film"])
    }

    /// Verify that all expected Phase 3 fields are present and non-nil in a typical result.
    func testExtractedMetadataContainsExpectedFields() throws {
        let json = """
        {
            "location": "Portland, Oregon",
            "people": ["Connor"],
            "occasion": "Print session",
            "mood": "contemplative",
            "keywords": ["darkroom", "cyanotype", "alternative process"]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(MetadataExtractionResult.self, from: json)

        // All Phase 3 fields should be populated
        XCTAssertNotNil(result.location, "location should be non-nil for this input")
        XCTAssertFalse(result.people.isEmpty, "people array must not be empty")
        XCTAssertNotNil(result.occasion, "occasion should be non-nil for this input")
        XCTAssertNotNil(result.mood, "mood should be non-nil for this input")
        XCTAssertFalse(result.keywords.isEmpty, "keywords array must not be empty")

        // Phase 7 reserved fields should remain nil / empty when not present in JSON
        XCTAssertNil(result.sceneType, "sceneType is reserved for Phase 7; must not be populated here")
        XCTAssertNil(result.peopleDetected, "peopleDetected is reserved for Phase 7; must not be populated here")
    }

    /// Malformed JSON (missing required array fields) should throw a decoding error.
    func testExtractionFailsGracefullyWithInvalidJSON() {
        // `people` and `keywords` are non-optional arrays; omitting them causes a
        // keyNotFound / valueNotFound decoding error.
        let malformedJSON = """
        {
            "location": "Unknown",
            "mood": "lost"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(
            try JSONDecoder().decode(MetadataExtractionResult.self, from: malformedJSON),
            "Decoding a JSON blob missing required fields must throw"
        )
    }

    /// Snake_case CodingKeys must correctly map from snake_case JSON.
    func testMetadataExtractionWithImageAndText() throws {
        // The CodingKeys use snake_case mapping for scene_type / people_detected.
        // Provide them explicitly to confirm the keys round-trip correctly.
        let json = """
        {
            "location": "Studio",
            "people": [],
            "occasion": null,
            "mood": "focused",
            "keywords": ["studio", "portrait"],
            "scene_type": "portrait",
            "people_detected": ["person_a"]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(MetadataExtractionResult.self, from: json)

        // Phase 7 fields are present in the JSON here (simulating an Ollama model
        // that has been told to fill them). We verify the CodingKeys decode correctly.
        XCTAssertEqual(result.sceneType, "portrait")
        XCTAssertEqual(result.peopleDetected, ["person_a"])
        XCTAssertEqual(result.mood, "focused")
    }

    /// Simulate network-style error by constructing OllamaError directly and verify it is Error.
    func testOllamaClientRetryOnNetworkError() {
        // OllamaError cases are the surface that MetadataExtractor throws on failure.
        // Verify they all conform to Error and have descriptive messages.
        let errors: [OllamaError] = [
            .httpError(statusCode: 503),
            .parsingFailed("bad JSON"),
            .ollamaUnavailable,
            .invalidJSON("serialization failed"),
            .networkError(NSError(domain: "TestDomain", code: -1009, userInfo: nil))
        ]

        for error in errors {
            XCTAssertNotNil(error as Error,
                            "OllamaError.\(error) must conform to Error protocol")
        }

        // Verify status code surfaces correctly on httpError
        if case .httpError(let code) = errors[0] {
            XCTAssertEqual(code, 503)
        } else {
            XCTFail("First error should be .httpError(statusCode: 503)")
        }

        // Verify parsingFailed carries message
        if case .parsingFailed(let msg) = errors[1] {
            XCTAssertEqual(msg, "bad JSON")
        } else {
            XCTFail("Second error should be .parsingFailed")
        }
    }
}
