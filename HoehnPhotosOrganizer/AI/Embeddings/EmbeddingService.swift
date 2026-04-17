import Foundation

// MARK: - EmbeddingServiceError

/// Errors produced by EmbeddingService when communicating with the Ollama API.
/// Named EmbeddingServiceError to avoid conflict with OllamaError in MetadataExtractor.swift.
enum EmbeddingServiceError: Error, LocalizedError {
    case connectionFailed(underlying: Error)
    case modelNotFound(model: String)
    case invalidResponse(detail: String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let err):
            return "Ollama connection failed: \(err.localizedDescription)"
        case .modelNotFound(let model):
            return "Ollama model not found: \(model)"
        case .invalidResponse(let detail):
            return "Ollama invalid response: \(detail)"
        }
    }
}

// MARK: - EmbeddingService

/// Lightweight Ollama HTTP client wrapper for generating 768-dim text embeddings.
///
/// Uses `nomic-embed-text` model via the Ollama API at http://localhost:11434.
/// All methods are nonisolated — the service is stateless and safe to call from any context.
///
/// Requirement: M7.1 (local embedding generation, zero API cost, privacy-preserving).
struct EmbeddingService: Sendable {

    // MARK: - Configuration

    nonisolated let ollamaURL: URL
    nonisolated let modelName: String

    static let defaultOllamaURL = URL(string: "http://localhost:11434")!
    static let defaultModelName = "nomic-embed-text"
    /// Expected number of dimensions for nomic-embed-text model.
    static let embeddingDimensions = 768

    init(
        ollamaURL: URL = EmbeddingService.defaultOllamaURL,
        modelName: String = EmbeddingService.defaultModelName
    ) {
        self.ollamaURL = ollamaURL
        self.modelName = modelName
    }

    // MARK: - Public API

    /// Generate a 768-dimensional embedding vector for the given text prompt.
    ///
    /// POSTs to `/api/embeddings` on the Ollama server. Throws `OllamaError` on failure.
    /// On connection failure, callers should log a warning and allow graceful degradation.
    func generateEmbedding(for text: String) async throws -> [Float] {
        let endpoint = ollamaURL.appendingPathComponent("api/embeddings")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: String] = ["model": modelName, "prompt": text]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw EmbeddingServiceError.connectionFailed(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbeddingServiceError.invalidResponse(detail: "Non-HTTP response")
        }

        switch httpResponse.statusCode {
        case 200:
            break
        case 404:
            throw EmbeddingServiceError.modelNotFound(model: modelName)
        default:
            let body = String(data: data, encoding: .utf8) ?? "<empty>"
            throw EmbeddingServiceError.invalidResponse(detail: "HTTP \(httpResponse.statusCode): \(body)")
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rawEmbedding = json["embedding"] as? [NSNumber]
        else {
            throw EmbeddingServiceError.invalidResponse(detail: "Missing or malformed 'embedding' field in response")
        }

        let vector = rawEmbedding.map { $0.floatValue }
        guard !vector.isEmpty else {
            throw EmbeddingServiceError.invalidResponse(detail: "Empty embedding vector returned")
        }

        return vector
    }

    /// Check if Ollama is running and responsive.
    ///
    /// GETs `/api/tags`. Returns true if responsive, false otherwise (no throw — allows graceful degradation).
    func healthCheck() async throws -> Bool {
        let endpoint = ollamaURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            // Log warning but don't throw — Ollama may simply not be running
            print("[EmbeddingService] Ollama health check failed (graceful): \(error.localizedDescription)")
            return false
        }
    }
}
