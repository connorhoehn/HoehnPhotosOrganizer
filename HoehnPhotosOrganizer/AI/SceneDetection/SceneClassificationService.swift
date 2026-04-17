import Foundation
import Vision

// MARK: - SceneType

/// The set of scene categories that SceneClassificationService can assign to a photograph.
///
/// Raw values are the exact strings stored in `photo_assets.scene_type`.
enum SceneType: String, Codable, CaseIterable {
    case landscape
    case portrait
    case architecture
    case stillLife = "stillLife"
    case street
    case documentary
    case other
}

// MARK: - SceneClassificationError

enum SceneClassificationError: Error, LocalizedError {
    case visionNotAvailable
    case ollamaFailed(underlying: Error)
    case invalidResponse(detail: String)
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .visionNotAvailable:
            return "Vision framework is not available on this platform"
        case .ollamaFailed(let err):
            return "Ollama scene classification failed: \(err.localizedDescription)"
        case .invalidResponse(let detail):
            return "Invalid scene classification response: \(detail)"
        case .invalidImage:
            return "Could not load image for scene classification"
        }
    }
}

// MARK: - SceneClassificationService

/// Classifies the scene type of a photograph using Vision (VNCoreMLRequest) first,
/// falling back to Ollama llava:13b when Vision/CoreML is unavailable.
///
/// - Primary path (macOS 14+): VNCoreMLRequest with bundled SceneClassifier.mlmodel
/// - Fallback: Ollama llava:13b HTTP API with a structured classification prompt
/// - Graceful degradation: returns `.other` if both paths fail
///
/// Requirements: AI-5, M7.6
actor SceneClassificationService {

    // MARK: - Configuration

    let ollamaBaseURL: URL
    let ollamaModelName: String
    private static let defaultOllamaBaseURL = URL(string: "http://localhost:11434")!
    private static let defaultModelName = "llava:13b"

    init(
        ollamaBaseURL: URL = SceneClassificationService.defaultOllamaBaseURL,
        ollamaModelName: String = SceneClassificationService.defaultModelName
    ) {
        self.ollamaBaseURL = ollamaBaseURL
        self.ollamaModelName = ollamaModelName
    }

    // MARK: - Public API

    /// Classify the scene type of a proxy image.
    ///
    /// Attempts Vision CoreML first (if SceneClassifier.mlmodel is bundled).
    /// Falls back to Ollama on Vision failure. Returns `.other` on total failure.
    func classifyScene(proxyImageURL: URL) async throws -> SceneType {
        // Attempt Vision CoreML path first
        if let sceneType = await classifyViaVision(imageURL: proxyImageURL) {
            return sceneType
        }

        // Fall back to Ollama llava:13b
        if let sceneType = await classifyViaOllama(imageURL: proxyImageURL) {
            return sceneType
        }

        // Graceful degradation — both paths failed
        print("[SceneClassificationService] Both Vision and Ollama failed, returning .other")
        return .other
    }

    /// Detect if Vision framework and a bundled CoreML model are available.
    func healthCheckVision() async -> Bool {
        // Check if SceneClassifier.mlmodel is bundled in the main bundle
        guard Bundle.main.url(forResource: "SceneClassifier", withExtension: "mlmodelc") != nil ||
              Bundle.main.url(forResource: "SceneClassifier", withExtension: "mlmodel") != nil else {
            print("[SceneClassificationService] SceneClassifier.mlmodel not found in bundle — Vision path unavailable")
            return false
        }
        return true
    }

    // MARK: - Private — Vision Path

    @available(macOS 14.0, *)
    private func classifyViaVisionAvailable(imageURL: URL) async -> SceneType? {
        // Check for bundled CoreML model
        guard Bundle.main.url(forResource: "SceneClassifier", withExtension: "mlmodelc") != nil ||
              Bundle.main.url(forResource: "SceneClassifier", withExtension: "mlmodel") != nil else {
            print("[SceneClassificationService] No bundled SceneClassifier.mlmodel — skipping Vision path")
            return nil
        }

        return await Task.detached(priority: .userInitiated) {
            let handler = VNImageRequestHandler(url: imageURL, options: [:])
            let request = VNClassifyImageRequest()
            do {
                try handler.perform([request])
                guard let observations = request.results else { return nil }
                // Find top classification observation with confidence > 0.3
                let topObservation = observations
                    .filter { $0.confidence > 0.3 }
                    .sorted { $0.confidence > $1.confidence }
                    .first
                guard let top = topObservation else { return nil }
                return Self.mapVisionLabelToSceneType(top.identifier)
            } catch {
                print("[SceneClassificationService] Vision classification error: \(error.localizedDescription)")
                return nil
            }
        }.value
    }

    private func classifyViaVision(imageURL: URL) async -> SceneType? {
        if #available(macOS 14.0, *) {
            return await classifyViaVisionAvailable(imageURL: imageURL)
        }
        return nil
    }

    // MARK: - Private — Ollama Path

    private func classifyViaOllama(imageURL: URL) async -> SceneType? {
        guard let imageData = try? Data(contentsOf: imageURL) else {
            print("[SceneClassificationService] Could not load image data for Ollama")
            return nil
        }

        let base64Image = imageData.base64EncodedString()
        let endpoint = ollamaBaseURL.appendingPathComponent("api/generate")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let prompt = "Classify the scene in this photograph into one of these categories: landscape, portrait, architecture, still life, street, documentary. Respond with exactly one word: the category name."

        let body: [String: Any] = [
            "model": ollamaModelName,
            "prompt": prompt,
            "images": [base64Image],
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                print("[SceneClassificationService] Ollama HTTP error")
                return nil
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let responseText = json["response"] as? String else {
                print("[SceneClassificationService] Invalid Ollama response format")
                return nil
            }

            return parseOllamaResponse(responseText)
        } catch {
            print("[SceneClassificationService] Ollama request failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Private — Helpers

    private func parseOllamaResponse(_ text: String) -> SceneType? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cleaned {
        case "landscape":               return .landscape
        case "portrait":                return .portrait
        case "architecture":            return .architecture
        case "still life", "stilllife", "still_life": return .stillLife
        case "street":                  return .street
        case "documentary":             return .documentary
        default:
            print("[SceneClassificationService] Unrecognised Ollama response: '\(cleaned)'")
            return nil
        }
    }

    private static func mapVisionLabelToSceneType(_ identifier: String) -> SceneType? {
        let lower = identifier.lowercased()
        if lower.contains("landscape") || lower.contains("nature") || lower.contains("outdoor") || lower.contains("mountain") || lower.contains("beach") || lower.contains("field") {
            return .landscape
        }
        if lower.contains("portrait") || lower.contains("face") || lower.contains("person") {
            return .portrait
        }
        if lower.contains("architecture") || lower.contains("building") || lower.contains("structure") || lower.contains("interior") {
            return .architecture
        }
        if lower.contains("still") || lower.contains("food") || lower.contains("object") || lower.contains("product") {
            return .stillLife
        }
        if lower.contains("street") || lower.contains("urban") || lower.contains("city") {
            return .street
        }
        if lower.contains("document") || lower.contains("event") || lower.contains("journa") {
            return .documentary
        }
        return .other
    }
}
