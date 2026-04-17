import Foundation

// MARK: - AnthropicNoteService

/// Sends a user's note text to Claude Haiku.
/// Returns a description plus structured metadata (location, people, keywords, etc.)
/// in a single API call — no image data required.
actor AnthropicNoteService {

    // MARK: - Types

    enum NoteServiceError: Error, LocalizedError {
        case noAPIKey
        case httpError(statusCode: Int, body: String)
        case malformedResponse(detail: String)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "No Anthropic API key configured. Add your key in Settings."
            case .httpError(let code, _):
                return "API error (HTTP \(code)). Check your API key and try again."
            case .malformedResponse(let detail):
                return "Unexpected response from Claude: \(detail)"
            case .networkError(let error):
                return "Network error: \(error.localizedDescription)"
            }
        }
    }

    /// Combined result: a short description plus extracted structured fields.
    struct NoteAnalysis {
        let description: String
        let metadata: MetadataExtractionResult
    }

    // MARK: - Wire types

    private struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        struct Message: Encodable {
            let role: String
            let content: String
        }

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }
    }

    /// Shape of Claude's JSON output.
    private struct AnalysisPayload: Decodable {
        let description: String
        let location: String?
        let people: [String]?
        let occasion: String?
        let mood: String?
        let keywords: [String]?
    }

    // MARK: - Properties

    private let authManager: AnthropicAuthManager
    private let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5-20251001"
    private let anthropicVersion = "2023-06-01"

    // MARK: - Init

    init(authManager: AnthropicAuthManager = AnthropicAuthManager()) {
        self.authManager = authManager
    }

    // MARK: - Public

    /// Analyse a note: generate a description and extract searchable metadata in one call.
    ///
    /// - Parameter note: Raw note or voice-memo transcription about the photo.
    /// - Returns: `NoteAnalysis` with description + structured metadata.
    func analyse(note: String) async throws -> NoteAnalysis {
        let apiKey: String
        do {
            apiKey = try await authManager.getAPIKey()
        } catch {
            throw NoteServiceError.noAPIKey
        }

        let system = """
            You are a photo-archiving assistant. Given a photographer's raw note about a photo, \
            respond with a single JSON object — no markdown, no code fences, just JSON. \
            Schema:
            {
              "description": "1–2 sentence description of the photo",
              "location": "city/place or null",
              "people": ["person/role descriptions or empty array"],
              "occasion": "event or context or null",
              "mood": "one-word mood or null",
              "keywords": ["3–8 searchable keywords"]
            }
            Base everything strictly on what the note says. Do not invent details.
            """

        let body = MessagesRequest(
            model: model,
            maxTokens: 400,
            system: system,
            messages: [.init(role: "user", content: note)]
        )

        var request = URLRequest(url: apiEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw NoteServiceError.malformedResponse(detail: "Could not encode request: \(error)")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw NoteServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NoteServiceError.malformedResponse(detail: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw NoteServiceError.httpError(statusCode: http.statusCode, body: body)
        }

        let apiResponse: MessagesResponse
        do {
            apiResponse = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw NoteServiceError.malformedResponse(detail: "Decode failed: \(error)")
        }

        guard let rawText = apiResponse.content.first(where: { $0.type == "text" })?.text,
              !rawText.isEmpty else {
            throw NoteServiceError.malformedResponse(detail: "No text block in response")
        }

        // Parse the JSON payload Claude returned
        let jsonData = rawText.data(using: .utf8) ?? Data()
        let payload: AnalysisPayload
        do {
            payload = try JSONDecoder().decode(AnalysisPayload.self, from: jsonData)
        } catch {
            // Fallback: treat the whole response as a plain description with no metadata
            let fallbackMeta = MetadataExtractionResult(
                location: nil, people: [], occasion: nil, mood: nil,
                keywords: [], sceneType: nil, peopleDetected: nil
            )
            return NoteAnalysis(description: rawText, metadata: fallbackMeta)
        }

        let metadata = MetadataExtractionResult(
            location: payload.location,
            people: payload.people ?? [],
            occasion: payload.occasion,
            mood: payload.mood,
            keywords: payload.keywords ?? [],
            sceneType: nil,
            peopleDetected: nil
        )

        return NoteAnalysis(description: payload.description, metadata: metadata)
    }
}
