import Foundation

enum SearchClientError: Error {
    case noAPIKey
    case unavailable
    case malformedResponse
    case httpError(statusCode: Int, body: String?)
}

struct SearchClient {
    private let authManager = AnthropicAuthManager()
    private let model: String
    private let apiBaseURL: URL
    private let anthropicVersion: String

    init(
        model: String = "claude-haiku-4-5-20251001",
        apiBaseURL: URL = URL(string: "https://api.anthropic.com")!,
        anthropicVersion: String = "2023-06-01"
    ) {
        self.model = model
        self.apiBaseURL = apiBaseURL
        self.anthropicVersion = anthropicVersion
    }

    // MARK: - Shared API call helper

    private struct APIMessage: Encodable {
        let role: String
        let content: String
    }

    private struct APIRequestBody: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [APIMessage]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    private struct APIContentBlock: Decodable {
        let type: String
        let text: String?
    }

    private struct APIUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens  = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    private struct APIResponse: Decodable {
        let content: [APIContentBlock]
        let usage: APIUsage?
        let model: String?
    }

    /// Shared low-level call to the Anthropic Messages API.
    /// Returns the text response and token usage.
    private func callAPI(
        systemPrompt: String,
        messages: [APIMessage],
        maxTokens: Int,
        label: String
    ) async throws -> (text: String, inputTokens: Int, outputTokens: Int) {
        let apiKey: String
        do {
            apiKey = try await authManager.getAPIKey()
        } catch {
            print("[Search] \(label): no API key available")
            throw SearchClientError.noAPIKey
        }

        let body = APIRequestBody(
            model: model,
            maxTokens: maxTokens,
            system: systemPrompt,
            messages: messages
        )

        let endpoint = apiBaseURL.appendingPathComponent("v1/messages")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let bodyData = try JSONEncoder().encode(body)
        request.httpBody = bodyData

        let messageCount = messages.count
        let systemLen = systemPrompt.count
        print("[Search] \(label): calling \(model) — \(messageCount) message(s), system prompt \(systemLen) chars, max_tokens=\(maxTokens)")

        let start = CFAbsoluteTimeGetCurrent()

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
            print("[Search] \(label): network error after \(elapsed)ms — \(error.localizedDescription)")
            throw SearchClientError.unavailable
        }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        guard let http = response as? HTTPURLResponse else {
            print("[Search] \(label): non-HTTP response after \(elapsed)ms")
            throw SearchClientError.unavailable
        }

        guard (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8)
            print("[Search] \(label): HTTP \(http.statusCode) after \(elapsed)ms — \(bodyStr ?? "empty")")
            throw SearchClientError.httpError(statusCode: http.statusCode, body: bodyStr)
        }

        guard let apiResponse = try? JSONDecoder().decode(APIResponse.self, from: data),
              let textBlock = apiResponse.content.first(where: { $0.type == "text" }),
              let rawText = textBlock.text
        else {
            print("[Search] \(label): malformed response after \(elapsed)ms — could not decode")
            throw SearchClientError.malformedResponse
        }

        let inputTokens  = apiResponse.usage?.inputTokens ?? 0
        let outputTokens = apiResponse.usage?.outputTokens ?? 0
        let costEstimate = Self.estimateCost(input: inputTokens, output: outputTokens)

        print("[Search] \(label): \(elapsed)ms — \(inputTokens) in / \(outputTokens) out — est. \(String(format: "$%.4f", costEstimate))")

        // Log to persistent cost tracker
        await APIUsageLogger.shared.log(
            model: model,
            label: label,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            durationMs: elapsed
        )

        // Strip markdown code fences if the model wrapped its JSON response
        let text = rawText
            .replacingOccurrences(of: #"^```(?:json)?\s*\n?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\n?```\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (text, inputTokens, outputTokens)
    }

    /// Estimate USD cost for Haiku 4.5 (as of 2025 pricing).
    private static func estimateCost(input: Int, output: Int) -> Double {
        // Haiku 4.5: $1.00/MTok input, $5.00/MTok output
        (Double(input) / 1_000_000 * 1.0) + (Double(output) / 1_000_000 * 5.0)
    }

    // MARK: - One-shot parse (existing search flow)

    func parse(query: String, knownPeople: [String] = []) async throws -> SearchIntentRaw {
        let peopleList = knownPeople.isEmpty ? "None known yet." : knownPeople.joined(separator: ", ")
        let systemPrompt = """
        You are a photo search assistant. Parse the user's query into JSON.

        ## Photo filter fields
        location, yearFrom, yearTo, cameraModel, fileType (dng/jpg/tiff/etc),
        curationState (keeper/archive/rejected/needs_review), processingState,
        keywords (array of strings), timeOfDay (golden_hour/blue_hour/midday/night),
        sceneType (landscape/portrait/architecture/stillLife/street/documentary/other),
        peopleDetected (bool), printAttempted (bool)

        ## Gear & film stock
        cameraModel matches camera/lens names in both EXIF and user gear notes (e.g. "Leica Z2X", "Hasselblad 500CM").
        For film stock (e.g. TMax 400, Portra 400, HP5), put the film name in keywords — it matches against gear notes metadata.

        ## People identification
        personNames: array of name strings mentioned in the query.
        Known people: [\(peopleList)]
        Use the closest matching name from the known list when possible.

        ## Print filter guidance
        When the user asks about prints, printed photos, or print jobs, set printAttempted to true.

        ## View hints
        preferMapView: true if the query is primarily about a location or place.

        Return ONLY valid JSON — no extra text:
        { "filter": { ...only non-null fields... }, "personNames": [...], "preferMapView": bool }
        """

        let (text, _, _) = try await callAPI(
            systemPrompt: systemPrompt,
            messages: [APIMessage(role: "user", content: query)],
            maxTokens: 256,
            label: "parse(\(query.prefix(40)))"
        )

        guard let jsonData = text.data(using: .utf8) else {
            print("[Search] parse: response is not valid UTF-8")
            throw SearchClientError.malformedResponse
        }

        if let intent = try? JSONDecoder().decode(SearchIntentRaw.self, from: jsonData) {
            print("[Search] parse: decoded SearchIntentRaw — filter.isEmpty=\(intent.filter.isEmpty), people=\(intent.personNames ?? [])")
            return intent
        }

        if let filter = try? JSONDecoder().decode(SearchFilter.self, from: jsonData) {
            print("[Search] parse: decoded flat SearchFilter (backward compat)")
            return SearchIntentRaw(filter: filter, personNames: nil, preferMapView: nil)
        }

        print("[Search] parse: could not decode response as SearchIntentRaw or SearchFilter:\n\(text.prefix(200))")
        throw SearchClientError.malformedResponse
    }

    // MARK: - Conversational refine (multi-turn)

    func refine(
        messages: [(role: String, content: String)],
        currentFilter: SearchFilter,
        knownPeople: [String] = [],
        photoCount: Int? = nil,
        libraryContext: String? = nil
    ) async throws -> ConversationResponse {
        let peopleList = knownPeople.isEmpty ? "None known yet." : knownPeople.joined(separator: ", ")
        let filterJSON: String = {
            guard let data = try? JSONEncoder().encode(currentFilter),
                  let str = String(data: data, encoding: .utf8) else { return "{}" }
            return str
        }()
        let countNote = photoCount.map { "The current filter matches approximately \($0) photos." } ?? ""
        let librarySection = libraryContext.map { "\n## Your library\n\($0)\n" } ?? ""

        let systemPrompt = """
        You are a conversational photo search assistant. Help the user build a search query \
        through dialogue. Each message refines the search.

        ## Your behavior
        1. Acknowledge what you understood from the user's message in 1-2 natural sentences.
        2. If the query is ambiguous, ask a clarifying question.
        3. Suggest 2-4 useful refinements the user might want (as short phrases).
        4. Return your response as JSON with these fields:
           - "reply": your natural language response (1-3 sentences)
           - "filter": updated SearchFilter object with ONLY the fields that should change
           - "personNames": array of person names mentioned (use closest match from known list)
           - "suggestions": array of 2-4 short refinement phrases the user could type next
           - "preferMapView": true if the query is primarily about a location

        ## Available filter fields
        location, yearFrom, yearTo, cameraModel, fileType (dng/jpg/tiff/etc),
        curationState (keeper/archive/rejected/needs_review), processingState,
        keywords (array), timeOfDay (golden_hour/blue_hour/midday/night),
        sceneType (landscape/portrait/architecture/stillLife/street/documentary/other),
        peopleDetected (bool), printAttempted (bool)

        ## Gear & film stock
        cameraModel matches camera/lens names in both EXIF and user gear notes (e.g. "Leica Z2X", "Hasselblad 500CM").
        For film stock (e.g. TMax 400, Portra 400, HP5), put the film name in keywords — it matches against gear notes metadata.

        ## Print filter guidance
        When the user asks about prints, printed photos, or print jobs, set printAttempted to true.

        ## Known people in the library
        [\(peopleList)]
        \(librarySection)
        ## Current accumulated filter
        \(filterJSON)
        \(countNote)

        Return ONLY valid JSON — no markdown, no code fences, no extra text.
        """

        let turnCount = messages.filter { $0.role == "user" }.count
        let label = "refine(turn \(turnCount))"

        let (text, _, _) = try await callAPI(
            systemPrompt: systemPrompt,
            messages: messages.map { APIMessage(role: $0.role, content: $0.content) },
            maxTokens: 512,
            label: label
        )

        guard let jsonData = text.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(ConversationResponse.self, from: jsonData)
        else {
            print("[Search] \(label): could not decode ConversationResponse:\n\(text.prefix(300))")
            throw SearchClientError.malformedResponse
        }

        print("[Search] \(label): reply=\"\(parsed.reply.prefix(60))...\" filter=\(parsed.filter != nil) people=\(parsed.personNames ?? []) suggestions=\(parsed.suggestions ?? [])")
        return parsed
    }

    /// Conversational refine with deterministic fallback.
    func refineChain(
        messages: [(role: String, content: String)],
        currentFilter: SearchFilter,
        knownPeople: [String] = [],
        photoCount: Int? = nil,
        libraryContext: String? = nil
    ) async -> ConversationResponse {
        do {
            return try await refine(
                messages: messages,
                currentFilter: currentFilter,
                knownPeople: knownPeople,
                photoCount: photoCount,
                libraryContext: libraryContext
            )
        } catch {
            let lastUserMsg = messages.last(where: { $0.role == "user" })?.content ?? ""
            print("[Search] refineChain: falling back to deterministic parser for \"\(lastUserMsg.prefix(40))\" — error: \(error)")
            let raw = SearchParser.parse(query: lastUserMsg, knownPeople: knownPeople)
            let reply = Self.humanFallbackReply(for: lastUserMsg, raw: raw)
            return ConversationResponse(
                reply: reply,
                filter: raw.filter,
                personNames: raw.personNames,
                suggestions: ["keepers only", "add date range", "with people"],
                preferMapView: raw.preferMapView
            )
        }
    }

    /// Generate a natural-sounding reply when the API is unavailable.
    private static func humanFallbackReply(for query: String, raw: SearchIntentRaw) -> String {
        let people = raw.personNames ?? []
        let hasLocation = raw.filter.location != nil
        let hasYear = raw.filter.yearFrom != nil
        let hasScene = raw.filter.sceneType != nil

        if !people.isEmpty && hasLocation {
            return "Looking for \(people.joined(separator: " and ")) in \(raw.filter.location!)."
        } else if !people.isEmpty {
            return "Let me find photos of \(people.joined(separator: " and "))."
        } else if hasLocation {
            return "Pulling up photos from \(raw.filter.location!)."
        } else if hasScene {
            return "Finding your \(raw.filter.sceneType!) shots."
        } else if hasYear {
            return "Looking through your \(raw.filter.yearFrom!) photos."
        } else {
            return "On it — searching for \(query)."
        }
    }
}

// MARK: - Search chain (tries Anthropic, falls back to deterministic)
extension SearchClient {
    func searchChain(query: String, knownPeople: [String] = []) async -> SearchIntentRaw {
        do {
            return try await parse(query: query, knownPeople: knownPeople)
        } catch {
            print("[Search] searchChain: falling back to deterministic parser — error: \(error)")
            return SearchParser.parse(query: query, knownPeople: knownPeople)
        }
    }
}
