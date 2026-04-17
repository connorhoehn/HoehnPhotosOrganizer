import Foundation

// MARK: - StudioChatService

/// Sends Studio chat messages to the Anthropic Messages API with full context
/// about the current medium, parameters, and render state.
///
/// Follows the same URLSession + `AnthropicAuthManager` pattern as `JobChatService`.
actor StudioChatService {

    // MARK: - Wire Types

    private struct APIRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [APIMessage]

        struct APIMessage: Encodable {
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

    private struct APIResponse: Decodable {
        let content: [ContentBlock]
        let usage: Usage?

        struct ContentBlock: Decodable {
            let type: String
            let text: String?
        }

        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    // MARK: - Parameter Suggestion

    /// A parameter change detected in the assistant's response text.
    struct ParameterSuggestion: Sendable {
        let parameterName: String   // e.g. "texture", "detail", "brushSize"
        let value: Double
    }

    // MARK: - Chat Result

    struct ChatResult: Sendable {
        let reply: String
        let suggestions: [ParameterSuggestion]
    }

    // MARK: - Properties

    private let authManager: AnthropicAuthManager
    private let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-sonnet-4-20250514"
    private let anthropicVersion = "2023-06-01"

    init(authManager: AnthropicAuthManager = AnthropicAuthManager()) {
        self.authManager = authManager
    }

    // MARK: - Public API

    /// Send a user message with Studio context and return the assistant reply.
    ///
    /// - Parameters:
    ///   - message: The user's chat input.
    ///   - history: Previous messages in the conversation for context.
    ///   - medium: Currently selected art medium.
    ///   - params: Current rendering parameters.
    ///   - hasImage: Whether a source image is loaded.
    ///   - hasRender: Whether a rendered image exists.
    /// - Returns: A `ChatResult` with the reply text and any detected parameter suggestions.
    func send(
        message: String,
        history: [StudioChatMessage],
        medium: ArtMedium,
        params: MediumParameters,
        hasImage: Bool,
        hasRender: Bool
    ) async throws -> ChatResult {
        let apiKey: String
        do { apiKey = try await authManager.getAPIKey() }
        catch { throw StudioChatError.noAPIKey }

        let system = buildSystemPrompt(
            medium: medium,
            params: params,
            hasImage: hasImage,
            hasRender: hasRender
        )

        var apiMessages: [APIRequest.APIMessage] = history.map {
            .init(role: $0.role.rawValue, content: $0.text)
        }
        apiMessages.append(.init(role: "user", content: message))

        let body = APIRequest(model: model, maxTokens: 600, system: system, messages: apiMessages)
        var request = URLRequest(url: apiEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let start = Date()
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw StudioChatError.networkError }

        guard let http = response as? HTTPURLResponse else { throw StudioChatError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw StudioChatError.httpError(http.statusCode, body)
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let apiResponse: APIResponse
        do { apiResponse = try JSONDecoder().decode(APIResponse.self, from: data) }
        catch { throw StudioChatError.badResponse }

        guard let rawText = apiResponse.content.first(where: { $0.type == "text" })?.text else {
            throw StudioChatError.badResponse
        }

        // Log API usage
        if let usage = apiResponse.usage {
            await APIUsageLogger.shared.log(
                model: model,
                label: "studio_chat",
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                durationMs: durationMs
            )
        }

        let suggestions = parseParameterSuggestions(rawText)
        return ChatResult(reply: rawText, suggestions: suggestions)
    }

    // MARK: - Helpers

    private func buildSystemPrompt(
        medium: ArtMedium,
        params: MediumParameters,
        hasImage: Bool,
        hasRender: Bool
    ) -> String {
        let imageStatus: String
        if hasRender {
            imageStatus = "A rendered image exists (medium: \(medium.rawValue))."
        } else if hasImage {
            imageStatus = "A source photo is loaded but not yet rendered."
        } else {
            imageStatus = "No image is loaded yet."
        }

        return """
        You are a Studio assistant helping an artist choose mediums, adjust rendering \
        parameters, and achieve specific artistic looks. You know about oil painting, \
        watercolor, charcoal, trois crayon, graphite, ink wash, pastel, and pen & ink \
        techniques.

        Current state:
        - Selected medium: \(medium.rawValue)
        - Brush Size: \(String(format: "%.1f", params.brushSize)) (range 1–20)
        - Detail: \(String(format: "%.2f", params.detail)) (0=abstract, 1=photorealistic)
        - Texture: \(String(format: "%.2f", params.texture)) (0=smooth, 1=heavy surface)
        - Saturation: \(String(format: "%.2f", params.colorSaturation)) (0=monochrome, 1=vivid)
        - Contrast: \(String(format: "%.2f", params.contrast)) (0–1)
        - \(imageStatus)

        Guidelines:
        - Keep replies concise (1–3 sentences). This is a creative workflow, not a lecture.
        - When suggesting parameter changes, use the exact format "try <param> at <value>" \
          (e.g. "try texture at 0.8") so the app can detect and offer to apply them.
        - Valid parameter names: brushSize, detail, texture, saturation, contrast.
        - You may suggest switching mediums or combining techniques.
        - For print-related questions, mention that the Print Lab is available for fine art output.
        """
    }

    /// Scan the reply text for parameter suggestions in the format "try <param> at <value>".
    private func parseParameterSuggestions(_ text: String) -> [ParameterSuggestion] {
        let pattern = #"try\s+(brushSize|detail|texture|saturation|contrast)\s+(?:at|to)\s+(\d+(?:\.\d+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        return matches.compactMap { match -> ParameterSuggestion? in
            guard match.numberOfRanges >= 3 else { return nil }
            let name = nsText.substring(with: match.range(at: 1)).lowercased()
            let valueStr = nsText.substring(with: match.range(at: 2))
            guard let value = Double(valueStr) else { return nil }

            // Normalize parameter name to match MediumParameters property names
            let normalized: String
            switch name {
            case "brushsize": normalized = "brushSize"
            case "saturation": normalized = "colorSaturation"
            default: normalized = name
            }
            return ParameterSuggestion(parameterName: normalized, value: value)
        }
    }

    // MARK: - Errors

    enum StudioChatError: Error, LocalizedError {
        case noAPIKey
        case networkError
        case httpError(Int, String)
        case badResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "No Anthropic API key configured. Add it in Settings."
            case .networkError: return "Network error — check your connection."
            case .httpError(let code, _): return "API error (HTTP \(code))."
            case .badResponse: return "Unexpected response from Claude."
            }
        }
    }
}
