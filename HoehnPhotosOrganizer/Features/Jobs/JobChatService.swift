import Foundation
import GRDB

// MARK: - JobChatService

/// Sends job-context messages to Claude Haiku and returns structured updates
/// to enrich the job's inherited metadata (location, camera, people, keywords).
actor JobChatService {

    // MARK: - Public Types

    struct ChatMessage {
        var id: UUID = UUID()
        var role: Role
        var text: String

        enum Role: String { case user, assistant }
    }

    struct ChatResponse {
        let reply: String
        let completeness: Int          // 0–100
        let nextQuestion: String?
        let updatedMetadata: Bool      // true if any new fields were extracted
    }

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

    private struct ClaudePayload: Decodable {
        let reply: String
        let completeness: Int?
        let nextQuestion: String?
        let updates: Updates?

        struct Updates: Decodable {
            var location: String?
            var camera: String?
            var keywords: [String]?
            var people: [String]?
            var occasion: String?
        }
    }

    // MARK: - Properties

    private let authManager: AnthropicAuthManager
    private let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private let model = "claude-haiku-4-5-20251001"
    private let anthropicVersion = "2023-06-01"

    init(authManager: AnthropicAuthManager = AnthropicAuthManager()) {
        self.authManager = authManager
    }

    // MARK: - Public API

    func send(
        message: String,
        history: [ChatMessage],
        jobTitle: String,
        photoCount: Int,
        existingMetadata: String?,
        sampleExif: String,
        faceCount: Int,
        identifiedCount: Int,
        db: AppDatabase,
        jobId: String
    ) async throws -> ChatResponse {
        let apiKey: String
        do { apiKey = try await authManager.getAPIKey() }
        catch { throw JobChatError.noAPIKey }

        let system = buildSystemPrompt(
            jobTitle: jobTitle,
            photoCount: photoCount,
            existingMetadata: existingMetadata,
            sampleExif: sampleExif,
            faceCount: faceCount,
            identifiedCount: identifiedCount
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
        catch { throw JobChatError.networkError }

        guard let http = response as? HTTPURLResponse else { throw JobChatError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw JobChatError.httpError(http.statusCode, body)
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)

        let apiResponse: APIResponse
        do { apiResponse = try JSONDecoder().decode(APIResponse.self, from: data) }
        catch { throw JobChatError.badResponse }

        guard let rawText = apiResponse.content.first(where: { $0.type == "text" })?.text else {
            throw JobChatError.badResponse
        }

        // Log API usage
        if let usage = apiResponse.usage {
            await APIUsageLogger.shared.log(
                model: model,
                label: "job_chat:\(jobId)",
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                durationMs: durationMs
            )
        }

        // Strip markdown code fences if Claude wrapped the JSON (```json ... ```)
        let stripped: String = {
            var s = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasPrefix("```") {
                s = s.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                if s.hasSuffix("```") { s = String(s.dropLast(3)) }
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return s
        }()

        // Parse Claude's JSON payload
        let payload: ClaudePayload
        do {
            let jsonData = stripped.data(using: .utf8) ?? Data()
            payload = try JSONDecoder().decode(ClaudePayload.self, from: jsonData)
        } catch {
            // Fallback: return plain text with no metadata updates
            await persistMessages(userText: message, assistantText: rawText, jobId: jobId, db: db)
            return ChatResponse(reply: rawText, completeness: 0, nextQuestion: nil, updatedMetadata: false)
        }

        // Persist both turns to thread_entries
        await persistMessages(userText: message, assistantText: payload.reply, jobId: jobId, db: db)

        // Merge extracted metadata into job.inheritedMetadata
        var updatedMetadata = false
        if let updates = payload.updates {
            updatedMetadata = await mergeMetadata(updates: updates, jobId: jobId, db: db)
        }

        return ChatResponse(
            reply: payload.reply,
            completeness: payload.completeness ?? 0,
            nextQuestion: payload.nextQuestion,
            updatedMetadata: updatedMetadata
        )
    }

    // MARK: - Helpers

    private func buildSystemPrompt(
        jobTitle: String,
        photoCount: Int,
        existingMetadata: String?,
        sampleExif: String,
        faceCount: Int,
        identifiedCount: Int
    ) -> String {
        let metaNote: String
        if let m = existingMetadata, !m.isEmpty, m != "{}" {
            metaNote = "Already documented: \(m)"
        } else {
            metaNote = "Nothing documented yet."
        }
        let faceNote = faceCount > 0
            ? "\(faceCount) faces detected in these photos, \(identifiedCount) already identified by name."
            : "No faces detected in these photos."

        return """
        You are a warm, efficient photo archiving assistant helping a photographer document \
        a batch of photos before they are archived.
        Job: "\(jobTitle)" — \(photoCount) photo\(photoCount == 1 ? "" : "s")
        \(metaNote)
        \(faceNote)
        Sample EXIF: \(sampleExif.isEmpty ? "Not available" : sampleExif)

        Your goal is to collect: where photos were taken (location), who is in them (people names), \
        what equipment was used (camera + lens), the occasion or event, and relevant archive keywords.

        IMPORTANT: Respond ONLY with a single valid JSON object — no markdown, no code fences. Schema:
        {
          "reply": "Your warm, conversational response (1–3 sentences)",
          "completeness": 45,
          "updates": {
            "location": "city or place name (omit key if not learned this turn)",
            "camera": "camera body + lens (omit key if not learned this turn)",
            "people": ["Full Name"],
            "occasion": "event or context description",
            "keywords": ["keyword1", "keyword2"]
          },
          "nextQuestion": "The single most useful follow-up question"
        }

        Rules:
        - Only include fields under "updates" that the user has just provided new information about.
        - Set "completeness" 0–100 based on how complete the documentation now is overall.
        - When completeness ≥ 80, acknowledge it and suggest wrapping up.
        - Keep replies brief and friendly — this is a quick triage workflow, not a deep interview.
        """
    }

    private func persistMessages(userText: String, assistantText: String, jobId: String, db: AppDatabase) async {
        do {
            let repo = ThreadRepository(db: db)
            let userPayload = try JSONEncoder().encode(["role": "user", "text": userText])
            if let json = String(data: userPayload, encoding: .utf8) {
                try await repo.addEntry(photoId: jobId, kind: "job_chat", contentJson: json, authoredBy: "user")
            }
            let assistantPayload = try JSONEncoder().encode(["role": "assistant", "text": assistantText])
            if let json = String(data: assistantPayload, encoding: .utf8) {
                try await repo.addEntry(photoId: jobId, kind: "job_chat", contentJson: json, authoredBy: "ai")
            }
        } catch {
            print("[JobChatService] Failed to persist messages: \(error)")
        }
    }

    /// Merges extracted fields into triage_jobs.inherited_metadata. Returns true if any field changed.
    @discardableResult
    private func mergeMetadata(updates: ClaudePayload.Updates, jobId: String, db: AppDatabase) async -> Bool {
        do {
            let repo = TriageJobRepository(db: db)
            guard var job = try await repo.fetchById(jobId) else { return false }

            var merged: [String: Any] = [:]
            if let existing = job.inheritedMetadata,
               !existing.isEmpty,
               let data = existing.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                merged = dict
            }

            var changed = false
            if let loc = updates.location { merged["location"] = loc; changed = true }
            if let cam = updates.camera { merged["camera"] = cam; changed = true }
            if let occ = updates.occasion { merged["occasion"] = occ; changed = true }
            if let kw = updates.keywords, !kw.isEmpty { merged["keywords"] = kw; changed = true }
            if let people = updates.people, !people.isEmpty {
                var existing = merged["people"] as? [String] ?? []
                let newPeople = people.filter { !existing.contains($0) }
                if !newPeople.isEmpty {
                    existing.append(contentsOf: newPeople)
                    merged["people"] = existing
                    changed = true
                }
            }

            guard changed else { return false }

            if let data = try? JSONSerialization.data(withJSONObject: merged),
               let str = String(data: data, encoding: .utf8) {
                job.inheritedMetadata = str
                job.updatedAt = Date()
                try await repo.update(job)
            }
            return true
        } catch {
            print("[JobChatService] mergeMetadata failed: \(error)")
            return false
        }
    }

    // MARK: - Errors

    enum JobChatError: Error, LocalizedError {
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
