import Foundation

// MARK: - GearNotesService

/// Sends a photographer's free-form gear/context note to Claude Haiku.
/// Returns structured technical metadata (camera, lens, settings, film, location, keywords)
/// without requiring an image — pure text extraction.
actor GearNotesService {

    // MARK: - Types

    enum GearServiceError: Error, LocalizedError {
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

    /// Structured technical metadata extracted from the user's note.
    struct GearExtraction: Codable {
        var camera: String?
        var lens: String?
        var aperture: String?
        var shutterSpeed: String?
        var iso: Int?
        var filmStock: String?
        var location: String?
        var keywords: [String]
        var userNotes: String?

        enum CodingKeys: String, CodingKey {
            case camera, lens, aperture, location, keywords
            case shutterSpeed = "shutter_speed"
            case iso
            case filmStock = "film_stock"
            case userNotes = "user_notes"
        }

        init(
            camera: String? = nil, lens: String? = nil,
            aperture: String? = nil, shutterSpeed: String? = nil,
            iso: Int? = nil, filmStock: String? = nil,
            location: String? = nil, keywords: [String] = [],
            userNotes: String? = nil
        ) {
            self.camera = camera; self.lens = lens
            self.aperture = aperture; self.shutterSpeed = shutterSpeed
            self.iso = iso; self.filmStock = filmStock
            self.location = location; self.keywords = keywords
            self.userNotes = userNotes
        }
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

    /// Parse a photographer's free-form note into structured gear/technical metadata.
    ///
    /// - Parameter note: Raw text describing camera, lens, settings, film stock, location, context.
    /// - Returns: `GearExtraction` with structured fields, all optional — only populated when found.
    func extract(from note: String) async throws -> GearExtraction {
        let apiKey: String
        do {
            apiKey = try await authManager.getAPIKey()
        } catch {
            throw GearServiceError.noAPIKey
        }

        let system = """
            You are a photography metadata assistant. Given a photographer's free-form notes, \
            extract technical shooting details and return a single JSON object — no markdown, \
            no code fences, just raw JSON. Use null for any field not mentioned.
            Schema:
            {
              "camera": "camera body name or null",
              "lens": "lens name/focal length or null",
              "aperture": "f/stop value or null",
              "shutter_speed": "exposure time (e.g. 1/125, 1s) or null",
              "iso": integer ISO value or null,
              "film_stock": "film name or null (for analog)",
              "location": "place name or null",
              "keywords": ["2–6 searchable keywords derived from context"],
              "user_notes": "any remaining context not captured above, or null"
            }
            Base everything strictly on what the note says. Do not invent details.
            """

        let body = MessagesRequest(
            model: model,
            maxTokens: 512,
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
            throw GearServiceError.malformedResponse(detail: "Could not encode request: \(error)")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GearServiceError.networkError(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GearServiceError.malformedResponse(detail: "Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw GearServiceError.httpError(statusCode: http.statusCode, body: body)
        }

        let apiResponse: MessagesResponse
        do {
            apiResponse = try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw GearServiceError.malformedResponse(detail: "Decode failed: \(error)")
        }

        guard let rawText = apiResponse.content.first(where: { $0.type == "text" })?.text,
              !rawText.isEmpty else {
            throw GearServiceError.malformedResponse(detail: "No text block in response")
        }

        // Strip any accidental markdown fences Claude might emit despite the prompt
        let cleaned = rawText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8) else {
            throw GearServiceError.malformedResponse(detail: "Could not convert response to Data")
        }

        do {
            return try JSONDecoder().decode(GearExtraction.self, from: jsonData)
        } catch {
            // Fallback: return empty extraction rather than crashing
            return GearExtraction(userNotes: rawText)
        }
    }
}
