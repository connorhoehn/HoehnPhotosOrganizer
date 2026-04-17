import Foundation

// MARK: - Metadata Extraction Errors

enum OllamaError: Error {
    case httpError(statusCode: Int)
    case parsingFailed(String)
    case ollamaUnavailable
    case invalidJSON(String)
    case networkError(Error)
}

// MARK: - MetadataExtractor

@MainActor
final class MetadataExtractor: Sendable {
    private let ollamaBaseURL: URL
    private let session = URLSession.shared

    init(ollamaURL: URL = URL(string: "http://localhost:11434")!) {
        self.ollamaBaseURL = ollamaURL
    }

    /// Extract structured metadata from note text and optional proxy image.
    /// Returns MetadataExtractionResult with Phase 3 fields only.
    func extractMetadata(
        from noteText: String,
        imageURL: URL? = nil
    ) async throws -> MetadataExtractionResult {
        // Build system prompt requesting Phase 3 fields only
        // (location, people, occasion, mood, keywords)
        let systemPrompt = """
        Extract structured metadata from a user's photo note. Return ONLY valid JSON with no additional text.
        Extract the following fields:
        - location: string or null (geographic location mentioned)
        - people: array of strings (names or descriptions of people mentioned)
        - occasion: string or null (event or context mentioned)
        - mood: string or null (emotional tone or mood)
        - keywords: array of strings (additional tags or descriptive terms)
        Do not include scene_type or people_detected in the response.
        """

        let userMessage = "Photo note: \(noteText)"

        // Build Ollama request
        let requestBody: [String: Any] = [
            "model": "llama3.2",
            "prompt": userMessage,
            "system": systemPrompt,
            "stream": false,
            "format": "json",
            "temperature": 0
        ]

        var request = URLRequest(url: ollamaBaseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        } catch {
            throw OllamaError.invalidJSON("Failed to serialize request body: \(error.localizedDescription)")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OllamaError.networkError(NSError(domain: "MetadataExtractor", code: -1, userInfo: nil))
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw OllamaError.httpError(statusCode: httpResponse.statusCode)
        }

        // Parse Ollama response format: { "response": "{...json...}" }
        do {
            guard let jsonResponse = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = jsonResponse["response"] as? String else {
                throw OllamaError.parsingFailed("Invalid response structure from Ollama")
            }

            // The response text contains the JSON
            guard let jsonData = responseText.data(using: .utf8) else {
                throw OllamaError.parsingFailed("Could not encode response text as UTF-8")
            }

            let result = try JSONDecoder().decode(MetadataExtractionResult.self, from: jsonData)
            return result
        } catch let error as DecodingError {
            throw OllamaError.parsingFailed("Failed to decode metadata: \(error.localizedDescription)")
        } catch let error as OllamaError {
            throw error
        } catch {
            throw OllamaError.parsingFailed("Unexpected error: \(error.localizedDescription)")
        }
    }
}
