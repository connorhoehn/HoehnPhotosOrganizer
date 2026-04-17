import Foundation

// MARK: - CalibrationWinnerResult

struct CalibrationWinnerResult {
    /// 0-based tile index the user selected as the winner.
    let winnerTileIndex: Int
    /// Brightness offset of the winning tile (e.g. +0.14).
    let brightnessOffset: Double
    /// Saturation offset of the winning tile.
    let saturationOffset: Double
    /// Whether Claude suggests generating a refined calibration grid centred on the winner.
    let suggestRefinedGrid: Bool
    /// Suggested brightness centre for the refined grid (only valid if suggestRefinedGrid).
    let refinedBrightnessCenter: Double
    /// Short human-readable notes from the model (e.g. "Tile 7 at +14% brightness was the winner").
    let notes: String
}

// MARK: - TileParameter

struct TileParameter: Encodable {
    let index: Int          // 0-based
    let brightness: Double
    let saturation: Double
    let label: String       // e.g. "B +14%"
}

// MARK: - PrintCalibrationWinnerService

/// Sends a natural-language winner description plus tile parameters to Claude Haiku.
/// Returns the resolved winner tile index, its adjustments, and optional follow-up suggestions.
actor PrintCalibrationWinnerService {

    // MARK: - Error

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

    // MARK: - Wire types (private)

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

    /// Resolve a winner from natural-language input.
    /// - Parameters:
    ///   - userInput: Free text from the user, e.g. "7 looked great, slightly warm"
    ///   - tiles: All tile parameters from the calibration print job (0-based).
    ///   - printer: Printer name for context.
    ///   - profileName: ICC profile display name for context.
    func resolveWinner(
        userInput: String,
        tiles: [TileParameter],
        printer: String,
        profileName: String
    ) async throws -> CalibrationWinnerResult {

        let apiKey = try await authManager.getAPIKey()

        // Build tile summary
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let tilesJSON = (try? String(data: encoder.encode(tiles), encoding: .utf8)) ?? "[]"

        let systemPrompt = """
        You are a print calibration assistant for a fine-art photography print lab.
        The user ran a multi-tile calibration print using an ICC profile on an inkjet printer.
        Each tile has a brightness and saturation offset applied on top of the ICC-profiled image.
        The user has examined the physical prints and described which tile(s) looked best.

        Your task:
        1. Identify the winning tile index (0-based) from the user's description.
           Users may say "number 7", "tile 7", "the seventh one", "the one in position 7", etc.
           Tile numbers in user speech are typically 1-based; convert to 0-based for the result.
        2. Decide whether a refined calibration grid (narrower increments centred on the winner) would help.
        3. Respond ONLY with valid JSON matching this exact schema — no prose, no markdown:
        {
          "winner_tile_index": <integer, 0-based>,
          "brightness_offset": <double>,
          "saturation_offset": <double>,
          "suggest_refined_grid": <boolean>,
          "refined_brightness_center": <double>,
          "notes": "<one concise sentence summary>"
        }
        """

        let userMessage = """
        Printer: \(printer)
        ICC Profile: \(profileName)

        Tile parameters (0-based index):
        \(tilesJSON)

        User's description: "\(userInput)"
        """

        let request = MessagesRequest(
            model: "claude-haiku-4-5-20251001",
            maxTokens: 256,
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

        return try parseResult(from: text, tiles: tiles)
    }

    // MARK: - Parsing

    private func parseResult(from text: String, tiles: [TileParameter]) throws -> CalibrationWinnerResult {
        // Strip possible markdown fences
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let jsonData = cleaned.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw ServiceError.parseError("Response is not valid JSON: \(text.prefix(200))")
        }

        guard let idx = obj["winner_tile_index"] as? Int else {
            throw ServiceError.parseError("Missing winner_tile_index")
        }

        let brightness        = (obj["brightness_offset"]       as? Double) ?? tiles[safe: idx]?.brightness ?? 0
        let saturation        = (obj["saturation_offset"]       as? Double) ?? tiles[safe: idx]?.saturation ?? 0
        let suggestRefined    = (obj["suggest_refined_grid"]    as? Bool)   ?? false
        let refinedCenter     = (obj["refined_brightness_center"] as? Double) ?? brightness
        let notes             = (obj["notes"]                   as? String)  ?? ""

        return CalibrationWinnerResult(
            winnerTileIndex:      idx,
            brightnessOffset:     brightness,
            saturationOffset:     saturation,
            suggestRefinedGrid:   suggestRefined,
            refinedBrightnessCenter: refinedCenter,
            notes:                notes
        )
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
