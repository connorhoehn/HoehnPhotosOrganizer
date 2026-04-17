import Foundation

// MARK: - SearchSuggestion

struct SearchSuggestion: Identifiable, Codable {
    let id: String
    let query: String
    let label: String

    init(query: String, label: String) {
        self.id = UUID().uuidString
        self.query = query
        self.label = label
    }

    // MARK: - Codable (id is not in the API response)

    enum CodingKeys: String, CodingKey { case query, label }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.query = try c.decode(String.self, forKey: .query)
        self.label = try c.decode(String.self, forKey: .label)
        self.id = UUID().uuidString
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(query, forKey: .query)
        try c.encode(label, forKey: .label)
    }
}

// MARK: - SearchSuggestionService

/// Calls Claude Haiku to generate contextual search suggestions based on
/// recent search history and library stats. Results are cached by a context
/// hash so the API is only called when something meaningful changes.
struct SearchSuggestionService {

    private let authManager = AnthropicAuthManager()

    private struct SuggestionsResponse: Decodable {
        let suggestions: [SearchSuggestion]
    }

    // MARK: - Public

    func fetchSuggestions(
        recentSearches: [String],
        libraryStats: LibraryContext
    ) async throws -> [SearchSuggestion] {
        let apiKey: String
        do {
            apiKey = try await authManager.getAPIKey()
        } catch {
            throw SearchSuggestionError.noAPIKey
        }

        let systemPrompt = """
        You are a photo library search assistant. The user has a personal photo archive app.
        Based on their recent search history and library context, suggest 5 natural-language search queries they are likely to want next.

        Rules:
        - Suggestions should be specific and actionable, not generic
        - Reference actual people, locations, or timeframes from their history when relevant
        - Mix different intents: finding specific photos, workflow tasks (undeveloped keepers), and exploration
        - Keep each query under 8 words
        - Vary the suggestion types (don't repeat the same pattern)

        Respond with ONLY valid JSON matching this exact schema:
        {
          "suggestions": [
            { "query": "string", "label": "string" }
          ]
        }
        The "label" is a short 1-2 word category like "People", "Location", "Workflow", "Date", "Scene".
        """

        let contextJSON = buildContextJSON(recentSearches: recentSearches, stats: libraryStats)
        let userMessage = "Library context and search history:\n\(contextJSON)\n\nSuggest 5 searches."

        let body: [String: Any] = [
            "model": "claude-haiku-4-5-20251001",
            "max_tokens": 400,
            "system": systemPrompt,
            "messages": [["role": "user", "content": userMessage]]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 12
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw SearchSuggestionError.apiError
        }

        // Parse Anthropic envelope → extract text block → parse suggestions JSON
        struct Envelope: Decodable {
            struct Block: Decodable { let type: String; let text: String? }
            let content: [Block]
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard let text = envelope.content.first(where: { $0.type == "text" })?.text,
              let jsonData = text.data(using: .utf8) else {
            throw SearchSuggestionError.malformedResponse
        }

        let parsed = try JSONDecoder().decode(SuggestionsResponse.self, from: jsonData)
        return parsed.suggestions
    }

    // MARK: - Context builder

    struct LibraryContext {
        let totalPhotos: Int
        let dateRange: (earliest: String, latest: String)?
        let topScenes: [(scene: String, count: Int)]
        let knownPeople: [String]
        let needsReviewCount: Int
        let keeperCount: Int
    }

    private func buildContextJSON(recentSearches: [String], stats: LibraryContext) -> String {
        var obj: [String: Any] = [
            "totalPhotos": stats.totalPhotos,
            "recentSearches": Array(recentSearches.prefix(10)),
            "needsReview": stats.needsReviewCount,
            "keepers": stats.keeperCount
        ]
        if let dr = stats.dateRange {
            obj["dateRange"] = "\(dr.earliest)–\(dr.latest)"
        }
        if !stats.topScenes.isEmpty {
            obj["topSceneTypes"] = stats.topScenes.prefix(5).map { $0.scene }
        }
        if !stats.knownPeople.isEmpty {
            obj["knownPeople"] = Array(stats.knownPeople.prefix(15))
        }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: .prettyPrinted)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

enum SearchSuggestionError: Error {
    case noAPIKey
    case apiError
    case malformedResponse
}
