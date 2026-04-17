import Foundation

// MARK: - MetadataWorkflowService

/// Lightweight Claude Haiku service for metadata-only workflow calls.
/// No image is sent — pure text extraction from the photographer's free-form input.
actor MetadataWorkflowService {

    // MARK: - Errors

    enum ServiceError: Error, LocalizedError {
        case noAPIKey
        case httpError(Int, String)
        case malformedResponse(String)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .noAPIKey:                   return "No Anthropic API key — add one in Settings."
            case .httpError(let c, _):        return "API error (HTTP \(c)). Check your API key."
            case .malformedResponse(let d):   return "Unexpected response: \(d)"
            case .networkError(let e):        return e.localizedDescription
            }
        }
    }

    // MARK: - Wire types

    private struct Req: Encodable {
        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Msg]
        struct Msg: Encodable { let role, content: String }
        enum CodingKeys: String, CodingKey {
            case model, system, messages
            case maxTokens = "max_tokens"
        }
    }

    private struct Resp: Decodable {
        let content: [Block]
        let usage: Usage?
        struct Block: Decodable { let type: String; let text: String? }
        struct Usage: Decodable {
            let inputTokens: Int
            let outputTokens: Int
            enum CodingKeys: String, CodingKey {
                case inputTokens  = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    // MARK: - Properties

    private let authManager: AnthropicAuthManager
    private let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let anthropicVersion = "2023-06-01"
    private let model = "claude-haiku-4-5-20251001"

    init(authManager: AnthropicAuthManager = AnthropicAuthManager()) {
        self.authManager = authManager
    }

    // MARK: - Public

    /// Run a metadata workflow. Returns `UserMetadata` with only the relevant fields populated.
    /// Callers should merge this with the photo's existing `UserMetadata` before writing.
    func run(kind: MetadataWorkflowKind, input: String) async throws -> UserMetadata {
        let apiKey: String
        do { apiKey = try await authManager.getAPIKey() }
        catch { throw ServiceError.noAPIKey }

        let (system, maxTokens) = promptConfig(for: kind)
        let rawJSON = try await callAPI(system: system, user: input, maxTokens: maxTokens, apiKey: apiKey)
        return try parse(rawJSON: rawJSON, kind: kind)
    }

    // MARK: - Prompts

    private func promptConfig(for kind: MetadataWorkflowKind) -> (system: String, maxTokens: Int) {
        switch kind {

        case .location:
            return ("""
                You are a photography metadata assistant. Extract the location from the photographer's text.
                Return a single JSON object — no markdown, no explanation, raw JSON only:
                {"location": "city/place name or null", "latitude": number or null, "longitude": number or null, "keywords": ["1-3 location keywords"]}
                Include latitude/longitude decimal coordinates when you are confident about the location (well-known cities, landmarks, streets).
                If no clear location is mentioned, return {"location": null, "latitude": null, "longitude": null, "keywords": []}.
                """, 200)

        case .gear:
            return ("""
                You are a photography metadata assistant. Extract technical shooting details from the photographer's notes.
                Return a single JSON object — no markdown, no code fences, raw JSON only:
                {
                  "camera": "body name or null",
                  "lens": "lens name/focal length or null",
                  "aperture": "f/stop value or null",
                  "shutter_speed": "exposure time or null",
                  "iso": integer ISO or null,
                  "film_stock": "film name or null",
                  "location": "place name or null",
                  "latitude": decimal latitude or null,
                  "longitude": decimal longitude or null,
                  "keywords": ["2-5 keywords"],
                  "user_notes": "remaining context not captured above, or null"
                }
                Include latitude/longitude when you are confident about the location (well-known cities, landmarks).
                Base everything strictly on what the note says. Do not invent details.
                """, 512)

        case .date:
            return ("""
                You are a photography metadata assistant. Extract date and time information from the photographer's text.
                Return a single JSON object — no markdown, raw JSON only:
                {"date": "YYYY-MM-DD or descriptive date or null", "time": "HH:MM or time of day or null", "season": "spring|summer|autumn|winter or null"}
                """, 120)

        case .filmStock:
            return ("""
                You are a photography metadata assistant. Extract film stock information from the photographer's text.
                Return a single JSON object — no markdown, raw JSON only:
                {"film_stock": "full film name or null", "iso": integer ISO or null, "color_process": "color|black_and_white|slide or null"}
                """, 120)

        case .lighting:
            return ("""
                You are a photography metadata assistant. Identify lighting conditions from the photographer's text.
                Return a single JSON object — no markdown, raw JSON only:
                {
                  "lighting": "short description e.g. golden hour, overcast, studio strobe, window light",
                  "color_temp": "daylight|tungsten|fluorescent|mixed|unknown",
                  "indoor_outdoor": "indoor|outdoor|mixed or null"
                }
                """, 150)

        case .editorial:
            return ("""
                You are a photo-archiving assistant. Given a photographer's raw note about a photo,
                extract and structure the metadata. Return a single JSON object — no markdown, raw JSON only:
                {
                  "location": "city/place or null",
                  "latitude": decimal latitude or null,
                  "longitude": decimal longitude or null,
                  "people": ["names or roles, or empty array"],
                  "occasion": "event or context or null",
                  "mood": "one-word mood or null",
                  "keywords": ["3-8 searchable keywords"],
                  "notes": "any remaining context not captured above, or null"
                }
                Include latitude/longitude when you are confident about the location (well-known cities, landmarks).
                Base everything strictly on what the note says. Do not invent details.
                """, 400)
        }
    }

    // MARK: - HTTP

    private func callAPI(system: String, user: String, maxTokens: Int, apiKey: String) async throws -> String {
        let body = Req(model: model, maxTokens: maxTokens, system: system,
                       messages: [.init(role: "user", content: user)])
        var req = URLRequest(url: apiEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do { req.httpBody = try JSONEncoder().encode(body) }
        catch { throw ServiceError.malformedResponse("encode: \(error)") }

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: req) }
        catch { throw ServiceError.networkError(error) }

        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.malformedResponse("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.httpError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let raw = resp.content.first(where: { $0.type == "text" })?.text, !raw.isEmpty else {
            throw ServiceError.malformedResponse("no text block in response")
        }

        // Log token usage and estimated cost
        if let usage = resp.usage {
            let inputCost  = Double(usage.inputTokens)  / 1_000_000 * 0.80
            let outputCost = Double(usage.outputTokens) / 1_000_000 * 4.00
            let totalCost  = inputCost + outputCost
            print(String(format: "[MetadataWorkflow] ✓ 1 API call — %d in + %d out tokens — est. $%.6f",
                         usage.inputTokens, usage.outputTokens, totalCost))
            await APIUsageLogger.shared.log(
                model: "claude-haiku-4-5-20251001", label: "metadata extraction",
                inputTokens: usage.inputTokens, outputTokens: usage.outputTokens, durationMs: 0
            )
        }

        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Parse

    private func parse(rawJSON: String, kind: MetadataWorkflowKind) throws -> UserMetadata {
        guard let data = rawJSON.data(using: .utf8) else {
            throw ServiceError.malformedResponse("utf8 encode failed")
        }
        let dec = JSONDecoder()

        switch kind {

        case .location:
            struct R: Decodable { var location: String?; var latitude: Double?; var longitude: Double?; var keywords: [String]? }
            if let r = try? dec.decode(R.self, from: data) {
                return UserMetadata(location: r.location, latitude: r.latitude, longitude: r.longitude, keywords: r.keywords ?? [])
            }

        case .gear:
            struct R: Decodable {
                var camera, lens, aperture, location, userNotes, filmStock: String?
                var shutterSpeed: String?
                var iso: Int?
                var latitude, longitude: Double?
                var keywords: [String]?
                enum CodingKeys: String, CodingKey {
                    case camera, lens, aperture, location, keywords, iso, latitude, longitude
                    case shutterSpeed = "shutter_speed"
                    case filmStock    = "film_stock"
                    case userNotes    = "user_notes"
                }
            }
            if let r = try? dec.decode(R.self, from: data) {
                return UserMetadata(camera: r.camera, lens: r.lens, aperture: r.aperture,
                                    shutterSpeed: r.shutterSpeed, iso: r.iso, filmStock: r.filmStock,
                                    location: r.location, latitude: r.latitude, longitude: r.longitude,
                                    keywords: r.keywords ?? [], notes: r.userNotes)
            }

        case .date:
            struct R: Decodable { var date, time, season: String? }
            if let r = try? dec.decode(R.self, from: data) {
                let combined = [r.date, r.time].compactMap { $0 }.joined(separator: " ")
                return UserMetadata(date: combined.isEmpty ? nil : combined, season: r.season)
            }

        case .filmStock:
            struct R: Decodable {
                var filmStock: String?; var iso: Int?; var colorProcess: String?
                enum CodingKeys: String, CodingKey {
                    case iso; case filmStock = "film_stock"; case colorProcess = "color_process"
                }
            }
            if let r = try? dec.decode(R.self, from: data) {
                let notesStr = r.colorProcess.map { "Process: \($0)" }
                return UserMetadata(iso: r.iso, filmStock: r.filmStock, notes: notesStr)
            }

        case .lighting:
            struct R: Decodable {
                var lighting, colorTemp, indoorOutdoor: String?
                enum CodingKeys: String, CodingKey {
                    case lighting; case colorTemp = "color_temp"; case indoorOutdoor = "indoor_outdoor"
                }
            }
            if let r = try? dec.decode(R.self, from: data) {
                return UserMetadata(lighting: r.lighting, colorTemp: r.colorTemp)
            }

        case .editorial:
            struct R: Decodable {
                var location: String?; var latitude, longitude: Double?; var people: [String]?
                var occasion, mood, notes: String?; var keywords: [String]?
            }
            if let r = try? dec.decode(R.self, from: data) {
                return UserMetadata(location: r.location, latitude: r.latitude, longitude: r.longitude,
                                    keywords: r.keywords ?? [], people: r.people ?? [],
                                    occasion: r.occasion, mood: r.mood, notes: r.notes)
            }
        }

        // Fallback — store raw text as notes so nothing is lost
        return UserMetadata(notes: rawJSON)
    }
}

// MARK: - MetadataWorkflowKind

enum MetadataWorkflowKind: String, CaseIterable {
    case location
    case gear
    case date
    case filmStock  = "film_stock"
    case lighting
    case editorial
}
