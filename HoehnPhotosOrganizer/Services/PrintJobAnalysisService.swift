import Foundation

// MARK: - PrintJobAnalysisResult

struct PrintJobAnalysisResult {
    let summary: String
    let suggestedAction: String?
    let refinedBrightnessCenter: Double?
    let refinedRange: Double?
}

// MARK: - PrintJobAnalysisService

/// Analyzes a print job thread — summarizes notes, scans, and outcomes, then suggests next steps.
/// Uses Claude Haiku via the same API pattern as PrintCalibrationWinnerService.
actor PrintJobAnalysisService {

    enum ServiceError: Error, LocalizedError {
        case noAPIKey
        case httpError(Int, String)
        case parseError(String)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:           return "No Anthropic API key. Add your key in Settings."
            case .httpError(let c, _): return "API error HTTP \(c). Check your key."
            case .parseError(let d):  return "Could not parse Claude response: \(d)"
            case .networkError(let e): return "Network error: \(e.localizedDescription)"
            }
        }
    }

    // MARK: - Wire types

    private struct MessagesRequest: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]
        struct Message: Encodable { let role: String; let content: String }
        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct MessagesResponse: Decodable {
        let content: [ContentBlock]
        struct ContentBlock: Decodable { let type: String; let text: String? }
    }

    // MARK: - Public

    private let authManager = AnthropicAuthManager()

    /// Analyze a print job thread and return a structured result.
    func analyze(
        snapshot: PrintJobSnapshot,
        children: [ActivityEvent]
    ) async throws -> PrintJobAnalysisResult {
        let apiKey = try await authManager.getAPIKey()

        let systemPrompt = """
        You are an expert fine-art print lab assistant. The user has a print job thread containing \
        configuration, notes, scan attachments, and print attempt outcomes.

        Analyze the thread and provide:
        1. A concise summary of what was printed, the outcome, and any observations from notes.
        2. A suggested next action (reprint with different settings, accept the result, run a curve revision, etc.)
        3. If the notes mention a winning calibration tile or brightness preference, suggest a refined \
           brightness center and narrower range for a follow-up calibration grid.

        Respond ONLY with valid JSON matching this schema — no prose, no markdown:
        {
          "summary": "<2-4 sentence summary>",
          "suggested_action": "<one sentence or null>",
          "refined_brightness_center": <double or null>,
          "refined_range": <double or null>
        }
        """

        // Build thread context
        var threadLines: [String] = []
        threadLines.append("Print Configuration:")
        threadLines.append("  Paper: \(snapshot.paperWidth)×\(snapshot.paperHeight)\" \(snapshot.isPortrait ? "Portrait" : "Landscape")")
        threadLines.append("  Color Mgmt: \(snapshot.colorMgmt)")
        if let icc = snapshot.iccProfileName { threadLines.append("  ICC: \(icc)") }
        if let intent = snapshot.renderingIntent { threadLines.append("  Rendering: \(intent)\(snapshot.blackPointCompensation ? " + BPC" : "")") }
        if let printer = snapshot.printerName { threadLines.append("  Printer: \(printer)") }
        threadLines.append("  Mode: \(snapshot.isNegative ? "Digital Negative" : "Positive")")
        if let template = snapshot.templateName { threadLines.append("  Template: \(template)") }
        threadLines.append("  Images: \(snapshot.images.count)")

        for (i, img) in snapshot.images.enumerated() {
            var parts = ["    Image \(i + 1)"]
            if let name = img.canonicalName { parts.append(name) }
            if let b = img.brightnessOffset { parts.append("B \(b > 0 ? "+" : "")\(String(format: "%.0f", b * 100))%") }
            if let label = img.tileLabel { parts.append("[\(label)]") }
            threadLines.append(parts.joined(separator: " "))
        }

        threadLines.append("\nThread Timeline:")
        for child in children {
            let kindStr: String
            switch child.kind {
            case .note:           kindStr = "Note"
            case .printAttempt:   kindStr = "Print Attempt"
            case .scanAttachment: kindStr = "Scan Attachment"
            case .aiSummary:      kindStr = "AI Summary"
            default:              kindStr = child.kind.rawValue
            }
            threadLines.append("  [\(kindStr)] \(child.title)")
            if let detail = child.detail { threadLines.append("    \(detail)") }
        }

        let userMessage = threadLines.joined(separator: "\n")

        let request = MessagesRequest(
            model: "claude-haiku-4-5-20251001",
            maxTokens: 512,
            system: systemPrompt,
            messages: [.init(role: "user", content: userMessage)]
        )

        var urlRequest = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        urlRequest.httpBody = try JSONEncoder().encode(request)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: urlRequest)
        } catch {
            throw ServiceError.networkError(error)
        }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ServiceError.httpError(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(MessagesResponse.self, from: data)
        guard let text = decoded.content.first(where: { $0.type == "text" })?.text else {
            throw ServiceError.parseError("No text block in response")
        }

        return try parseResult(from: text)
    }

    // MARK: - Parse

    private func parseResult(from text: String) throws -> PrintJobAnalysisResult {
        // Extract JSON from potential markdown fences
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let summary = json["summary"] as? String else {
            throw ServiceError.parseError(String(text.prefix(200)))
        }

        return PrintJobAnalysisResult(
            summary: summary,
            suggestedAction: json["suggested_action"] as? String,
            refinedBrightnessCenter: json["refined_brightness_center"] as? Double,
            refinedRange: json["refined_range"] as? Double
        )
    }
}
