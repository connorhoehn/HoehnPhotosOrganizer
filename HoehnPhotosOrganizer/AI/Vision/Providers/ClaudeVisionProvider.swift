import Foundation

// MARK: - Anthropic Messages API wire types

/// Minimal request body for the Anthropic Messages API.
private struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let system: String?
    let messages: [Message]

    struct Message: Encodable {
        let role: String
        let content: [ContentBlock]
    }

    enum ContentBlock: Encodable {
        case image(mediaType: String, data: String)
        case text(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .image(let mediaType, let data):
                try container.encode("image", forKey: .type)
                let source = ImageSource(type: "base64", mediaType: mediaType, data: data)
                try container.encode(source, forKey: .source)
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, source, text
        }

        struct ImageSource: Encodable {
            let type: String
            let mediaType: String
            let data: String

            enum CodingKeys: String, CodingKey {
                case type
                case mediaType = "media_type"
                case data
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system
        case messages
    }
}

/// Minimal response shape from the Anthropic Messages API.
private struct AnthropicMessagesResponse: Decodable {
    let content: [ContentBlock]

    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
}

// MARK: - ClaudeVisionProvider

/// Implements `VisionModelProvider` using the Anthropic Messages API with vision.
///
/// Uses raw URLSession — no Anthropic SDK dependency, consistent with the OpenAI client
/// pattern already established in this codebase.
actor ClaudeVisionProvider: VisionModelProvider {

    // MARK: - Configuration

    struct Configuration: Sendable {
        /// Anthropic model ID to use for vision tasks.
        var model: String = "claude-sonnet-4-5"
        /// Base URL for the Anthropic API.
        var apiBaseURL: URL = URL(string: "https://api.anthropic.com")!
        /// Anthropic API version header value.
        var anthropicVersion: String = "2023-06-01"
        /// URLSession timeout for each request in seconds.
        var timeoutSeconds: Double = 30
    }

    // MARK: - Properties

    private let configuration: Configuration
    private let authManager: AnthropicAuthManager

    // MARK: - VisionModelProvider

    nonisolated var providerName: String { "Claude (\(configuration.model))" }

    // MARK: - Init

    init(
        authManager: AnthropicAuthManager,
        configuration: Configuration = Configuration()
    ) {
        self.authManager = authManager
        self.configuration = configuration
    }

    /// Convenience init using a shared AnthropicAuthManager and default configuration.
    init(authManager: AnthropicAuthManager) {
        self.init(authManager: authManager, configuration: Configuration())
    }

    // MARK: - VisionModelProvider conformance

    /// Send an image + text prompt to the Anthropic Messages API and return the response text.
    ///
    /// - Parameter prompt: Multimodal prompt with image data, text, and optional system message.
    /// - Returns: The text content from the first content block in the response.
    /// - Throws: `VisionModelError` on authentication, network, or parsing failures.
    func analyze(_ prompt: VisionPrompt) async throws -> String {
        // 1. Retrieve API key
        let apiKey: String
        do {
            apiKey = try await authManager.getAPIKey()
        } catch {
            throw VisionModelError.noAPIKey
        }

        // 2. Build request body
        let base64Image = prompt.imageData.base64EncodedString()
        let requestBody = AnthropicMessagesRequest(
            model: configuration.model,
            maxTokens: prompt.maxTokens,
            system: prompt.systemMessage,
            messages: [
                .init(role: "user", content: [
                    .image(mediaType: prompt.imageMediaType, data: base64Image),
                    .text(prompt.userMessage)
                ])
            ]
        )

        let endpoint = configuration.apiBaseURL.appendingPathComponent("/v1/messages")
        var urlRequest = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: configuration.timeoutSeconds
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(configuration.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        do {
            urlRequest.httpBody = try encoder.encode(requestBody)
        } catch {
            throw VisionModelError.malformedResponse(detail: "Could not encode request: \(error)")
        }

        // 3. Send request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw VisionModelError.timeout
        } catch {
            throw VisionModelError.providerUnavailable(reason: error.localizedDescription)
        }

        // 4. Check HTTP status
        guard let http = response as? HTTPURLResponse else {
            throw VisionModelError.providerUnavailable(reason: "Non-HTTP response from Anthropic API")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw VisionModelError.httpError(statusCode: http.statusCode, body: body)
        }

        // 5. Parse response
        let decoder = JSONDecoder()
        let apiResponse: AnthropicMessagesResponse
        do {
            apiResponse = try decoder.decode(AnthropicMessagesResponse.self, from: data)
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            throw VisionModelError.malformedResponse(detail: "Could not decode API response: \(error). Raw: \(raw.prefix(300))")
        }

        // 6. Extract text from first content block
        guard let textBlock = apiResponse.content.first(where: { $0.type == "text" }),
              let text = textBlock.text, !text.isEmpty else {
            throw VisionModelError.malformedResponse(detail: "No text content block in Anthropic response")
        }

        return text
    }
}
