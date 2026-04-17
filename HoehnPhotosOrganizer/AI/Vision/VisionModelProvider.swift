import Foundation

// MARK: - VisionPrompt

/// The message sent to any vision model provider.
/// Encapsulates both the image and text halves of a multimodal request.
struct VisionPrompt: Sendable {
    /// Optional system-level instruction for models that support it.
    let systemMessage: String?
    /// The user-facing text prompt.
    let userMessage: String
    /// JPEG bytes of the image to analyze.
    let imageData: Data
    /// MIME type of the image (e.g., "image/jpeg").
    let imageMediaType: String
    /// Maximum tokens the model may generate.
    let maxTokens: Int

    init(
        systemMessage: String? = nil,
        userMessage: String,
        imageData: Data,
        imageMediaType: String = "image/jpeg",
        maxTokens: Int = 1024
    ) {
        self.systemMessage = systemMessage
        self.userMessage = userMessage
        self.imageData = imageData
        self.imageMediaType = imageMediaType
        self.maxTokens = maxTokens
    }
}

// MARK: - VisionModelError

/// Errors that any VisionModelProvider can throw.
enum VisionModelError: Error, LocalizedError {
    case noAPIKey
    case providerUnavailable(reason: String)
    case httpError(statusCode: Int, body: String)
    case malformedResponse(detail: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured for this vision model provider."
        case .providerUnavailable(let reason):
            return "Vision model provider unavailable: \(reason)"
        case .httpError(let code, let body):
            return "Vision API HTTP error \(code): \(body.prefix(200))"
        case .malformedResponse(let detail):
            return "Vision model returned a malformed response: \(detail)"
        case .timeout:
            return "Vision model API request timed out."
        }
    }
}

// MARK: - VisionModelProvider

/// Protocol that separates *how* to call a vision model from *what* to ask.
///
/// Conforming types implement a specific API backend (Anthropic, OpenAI, Ollama, etc.).
/// Adding a new provider requires only a single conforming type — no other code changes.
protocol VisionModelProvider: Sendable {
    /// Human-readable name for logging and UI display (e.g., "Claude Sonnet 4", "GPT-4o").
    var providerName: String { get }

    /// Send an image + text prompt to the vision model and receive a raw text response.
    ///
    /// - Parameter prompt: The multimodal prompt containing image data and text instructions.
    /// - Returns: The model's raw text output (may contain JSON, prose, etc.).
    /// - Throws: `VisionModelError` on authentication failure, HTTP errors, or timeouts.
    func analyze(_ prompt: VisionPrompt) async throws -> String
}

// MARK: - VisionAnalysisTask

/// Protocol that separates *what* to ask from *how* to call the model.
///
/// Inspired by BAML (Build A Machine Learning function): each task is a self-contained
/// function definition — prompt template + response parser. Adding a new task (e.g., scene
/// classification) requires only a single conforming type.
protocol VisionAnalysisTask: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable

    /// Build a provider-agnostic VisionPrompt for this task given the task-specific input.
    func buildPrompt(for input: Input) -> VisionPrompt

    /// Parse the model's raw text response into the task's structured output type.
    ///
    /// - Parameter text: The raw text returned by `VisionModelProvider.analyze(_:)`.
    /// - Returns: Structured output for this task.
    /// - Throws: `VisionModelError.malformedResponse` if the text cannot be parsed.
    func parseResponse(_ text: String) throws -> Output
}
