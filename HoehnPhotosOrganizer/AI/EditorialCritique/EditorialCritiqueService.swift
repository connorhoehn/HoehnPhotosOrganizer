import AppKit
import Foundation

// MARK: - CritiqueError

enum CritiqueError: LocalizedError {
    case apiKeyMissing
    case apiRequestFailed(statusCode: Int, body: String)
    case invalidResponse(details: String)
    case imageLoadFailed(path: String)

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "Anthropic API key not configured. Go to Settings > Cloud AI to add your key."
        case .apiRequestFailed(let code, let body):
            return "Anthropic API request failed (HTTP \(code)): \(body.prefix(200))"
        case .invalidResponse(let details):
            return "Could not parse Anthropic response: \(details)"
        case .imageLoadFailed(let path):
            return "Could not load proxy image at path: \(path)"
        }
    }
}

// MARK: - EditorialFeedback

struct EditorialFeedback: Codable, Equatable {
    let compositionScore: Int        // 1–10
    let printReadiness: String       // "ready" | "needs work"
    let analysis: String
    let adjustments: SuggestedAdjustments?
    let cropSuggestions: [CropSuggestion]
    let maskingHints: [String]
    let strengths: [String]
    let areasForImprovement: [String]
    let suggestedEditDirections: [String]
    let metadataEnrichment: MetadataEnrichment?
    let geometryCorrection: GeometryCorrection?
    let regionalAdjustments: [RegionalAdjustment]?

    enum CodingKeys: String, CodingKey {
        case compositionScore = "composition_score"
        case printReadiness = "print_readiness"
        case analysis
        case adjustments
        case cropSuggestions = "crop_suggestions"
        case maskingHints = "masking_hints"
        case strengths
        case areasForImprovement = "areas_for_improvement"
        case suggestedEditDirections = "suggested_edit_directions"
        case metadataEnrichment = "metadata_enrichment"
        case geometryCorrection = "geometry_correction"
        case regionalAdjustments = "regional_adjustments"
    }

    init(compositionScore: Int, printReadiness: String, analysis: String,
         adjustments: SuggestedAdjustments?, cropSuggestions: [CropSuggestion],
         maskingHints: [String], strengths: [String], areasForImprovement: [String],
         suggestedEditDirections: [String], metadataEnrichment: MetadataEnrichment?,
         geometryCorrection: GeometryCorrection?, regionalAdjustments: [RegionalAdjustment]?) {
        self.compositionScore = compositionScore
        self.printReadiness = printReadiness
        self.analysis = analysis
        self.adjustments = adjustments
        self.cropSuggestions = cropSuggestions
        self.maskingHints = maskingHints
        self.strengths = strengths
        self.areasForImprovement = areasForImprovement
        self.suggestedEditDirections = suggestedEditDirections
        self.metadataEnrichment = metadataEnrichment
        self.geometryCorrection = geometryCorrection
        self.regionalAdjustments = regionalAdjustments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compositionScore = (try? c.decode(Int.self, forKey: .compositionScore)) ?? 5
        printReadiness = (try? c.decode(String.self, forKey: .printReadiness)) ?? "needs work"
        analysis = (try? c.decode(String.self, forKey: .analysis)) ?? ""
        adjustments = try? c.decode(SuggestedAdjustments.self, forKey: .adjustments)
        cropSuggestions = (try? c.decode([CropSuggestion].self, forKey: .cropSuggestions)) ?? []
        maskingHints = (try? c.decode([String].self, forKey: .maskingHints)) ?? []
        strengths = (try? c.decode([String].self, forKey: .strengths)) ?? []
        areasForImprovement = (try? c.decode([String].self, forKey: .areasForImprovement)) ?? []
        suggestedEditDirections = (try? c.decode([String].self, forKey: .suggestedEditDirections)) ?? []
        metadataEnrichment = try? c.decode(MetadataEnrichment.self, forKey: .metadataEnrichment)
        geometryCorrection = try? c.decode(GeometryCorrection.self, forKey: .geometryCorrection)
        regionalAdjustments = try? c.decode([RegionalAdjustment].self, forKey: .regionalAdjustments)
    }
}

struct SuggestedAdjustments: Codable, Equatable {
    let exposure: Double?      // -5.0 … +5.0 stops
    let contrast: Int?         // -100 … +100
    let highlights: Int?       // -100 … +100
    let shadows: Int?          // -100 … +100
    let whites: Int?           // -100 … +100
    let blacks: Int?           // -100 … +100
    let saturation: Int?       // -100 … +100
    let vibrance: Int?         // -100 … +100
    let rationale: String?
}

struct CropSuggestion: Codable, Identifiable, Equatable {
    var id: String { label }
    let label: String
    let description: String
    let leftPct: Double    // 0.0 – 1.0
    let topPct: Double
    let rightPct: Double   // right edge, not width
    let bottomPct: Double

    enum CodingKeys: String, CodingKey {
        case label, description
        case leftPct = "left_pct"
        case topPct = "top_pct"
        case rightPct = "right_pct"
        case bottomPct = "bottom_pct"
    }

    // Extra keys Claude sometimes uses instead of "label"
    private enum AltKeys: String, CodingKey { case name, title }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let alt = try? decoder.container(keyedBy: AltKeys.self)
        label = (try? c.decode(String.self, forKey: .label))
             ?? (try? alt?.decode(String.self, forKey: .name))
             ?? (try? alt?.decode(String.self, forKey: .title))
             ?? "Crop"
        description = (try? c.decode(String.self, forKey: .description)) ?? ""
        leftPct = (try? c.decode(Double.self, forKey: .leftPct)) ?? 0
        topPct = (try? c.decode(Double.self, forKey: .topPct)) ?? 0
        rightPct = (try? c.decode(Double.self, forKey: .rightPct)) ?? 1
        bottomPct = (try? c.decode(Double.self, forKey: .bottomPct)) ?? 1
    }
}

struct MetadataEnrichment: Codable, Equatable {
    let locationName: String?
    let venue: String?
    let coordinates: Coordinates?
    let subjects: [String]?
    let mood: String?
    let decadeStyle: String?

    enum CodingKeys: String, CodingKey {
        case locationName = "location_name"
        case venue
        case coordinates
        case subjects
        case mood
        case decadeStyle = "decade_style"
    }

    struct Coordinates: Codable, Equatable {
        let lat: Double
        let lon: Double
    }
}

/// Geometry correction suggested by Claude — rotation and perspective.
struct GeometryCorrection: Codable, Equatable {
    let rotationDegrees: Double?        // CCW negative, CW positive. Maps to CIStraightenFilter.
    let verticalPerspective: Double?    // -100 to +100 (Lightroom Vertical equivalent)
    let horizontalPerspective: Double?  // -100 to +100 (Lightroom Horizontal equivalent)
    let rationale: String?

    enum CodingKeys: String, CodingKey {
        case rotationDegrees = "rotation_degrees"
        case verticalPerspective = "vertical_perspective"
        case horizontalPerspective = "horizontal_perspective"
        case rationale
    }
}

/// Token usage and estimated cost for a single editorial critique request.
struct EditorialTokenUsage {
    let inputTokens: Int
    let outputTokens: Int
    // claude-sonnet-4-6 pricing: ~$3/M input, $15/M output
    var estimatedCostUSD: Double {
        Double(inputTokens) / 1_000_000 * 3.0 +
        Double(outputTokens) / 1_000_000 * 15.0
    }
}

// MARK: - Anthropic Wire Types

private struct AnthropicResponse: Codable {
    let content: [ContentBlock]
    let usage: Usage?

    struct ContentBlock: Codable {
        let type: String
        let text: String?
    }

    struct Usage: Codable {
        let inputTokens: Int
        let outputTokens: Int

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}

// MARK: - ThreadEntryRepository (protocol for testability)

/// Protocol abstracting the thread persistence layer used by EditorialCritiqueService.
protocol ThreadEntryRepository: AnyObject {
    func addEntry(photoId: String, kind: String, contentJson: String, authoredBy: String) async throws
}

// MARK: - EditorialCritiqueService

/// Actor that calls Claude (Anthropic) with a proxy image and thread context to produce editorial feedback.
actor EditorialCritiqueService {

    // MARK: - Constants

    private static let apiEndpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let model = "claude-sonnet-4-6"
    private static let batchModel = "claude-haiku-4-5-20251001"
    private static let anthropicVersion = "2023-06-01"

    // MARK: - Dependencies

    private let authManager: AnthropicAuthManager

    // MARK: - Init

    init(authManager: AnthropicAuthManager = AnthropicAuthManager()) {
        self.authManager = authManager
    }

    // MARK: - Public API

    func requestEditorialFeedback(
        photoAssetId: String,
        proxyImageURL: URL,
        threadHistory: [ThreadEntry],
        photoMetadata: String? = nil,
        printAttemptHistory: [PrintAttempt]? = nil,
        threadRepo: any ThreadEntryRepository,
        scope: ReviewScope = .full
    ) async throws -> (feedback: EditorialFeedback, tokenUsage: EditorialTokenUsage) {

        // 1. Auth check
        let apiKey: String
        do {
            apiKey = try await authManager.getAPIKey()
        } catch {
            throw CritiqueError.apiKeyMissing
        }

        // 2. Load, resize, and base64-encode proxy image (max 1024px, JPEG 0.65)
        guard let (imageData, imgW, imgH) = Self.prepareImageDataWithDimensions(from: proxyImageURL), !imageData.isEmpty else {
            throw CritiqueError.imageLoadFailed(path: proxyImageURL.path)
        }
        let base64Image = imageData.base64EncodedString()

        // 3. Build prompt
        let userPrompt = buildUserPrompt(
            threadHistory: threadHistory,
            photoMetadata: photoMetadata,
            printAttemptHistory: printAttemptHistory,
            scope: scope,
            imageWidth: imgW,
            imageHeight: imgH
        )
        let systemPrompt = buildSystemPrompt()

        // 4. Build Anthropic request body
        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4096,
            "system": systemPrompt,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": base64Image
                            ]
                        ],
                        [
                            "type": "text",
                            "text": userPrompt
                        ]
                    ]
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw CritiqueError.invalidResponse(details: "Failed to serialize request body")
        }

        var request = URLRequest(url: Self.apiEndpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        // 5. Send request
        let (responseData, httpResponse) = try await URLSession.shared.data(for: request)
        if let http = httpResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw CritiqueError.apiRequestFailed(statusCode: http.statusCode, body: body)
        }

        // 6. Parse response
        let (feedback, usage) = try parseResponse(responseData)

        // 7. Log token usage
        let tokenUsage = EditorialTokenUsage(
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0
        )
        print("[Editorial] tokens: \(tokenUsage.inputTokens) in / \(tokenUsage.outputTokens) out — est. $\(String(format: "%.4f", tokenUsage.estimatedCostUSD))")
        await APIUsageLogger.shared.log(
            model: Self.model, label: "editorial critique",
            inputTokens: tokenUsage.inputTokens, outputTokens: tokenUsage.outputTokens, durationMs: 0
        )

        // 8. Store in thread
        try await storeInThread(feedback: feedback, photoAssetId: photoAssetId, threadRepo: threadRepo)

        return (feedback, tokenUsage)
    }

    /// Fast batch-oriented review using Haiku. Skips thread history for speed.
    /// Returns the feedback and token usage, or throws on failure.
    func requestBatchFeedback(
        photoAssetId: String,
        proxyImageURL: URL,
        threadRepo: any ThreadEntryRepository
    ) async throws -> (feedback: EditorialFeedback, tokenUsage: EditorialTokenUsage) {
        let apiKey = try await authManager.getAPIKey()

        guard let imageData = Self.prepareImageData(from: proxyImageURL), !imageData.isEmpty else {
            throw CritiqueError.imageLoadFailed(path: proxyImageURL.path)
        }

        let body: [String: Any] = [
            "model": Self.model,
            "max_tokens": 4096,
            "system": buildSystemPrompt(),
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageData.base64EncodedString()
                            ]
                        ],
                        [
                            "type": "text",
                            "text": buildUserPrompt(threadHistory: [], photoMetadata: nil, printAttemptHistory: nil)
                        ]
                    ]
                ]
            ]
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
            throw CritiqueError.invalidResponse(details: "Failed to serialize request body")
        }

        var request = URLRequest(url: Self.apiEndpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData

        let (responseData, httpResponse) = try await URLSession.shared.data(for: request)
        if let http = httpResponse as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: responseData, encoding: .utf8) ?? "<binary>"
            throw CritiqueError.apiRequestFailed(statusCode: http.statusCode, body: body)
        }

        let (feedback, usage) = try parseResponse(responseData)
        let tokenUsage = EditorialTokenUsage(
            inputTokens: usage?.inputTokens ?? 0,
            outputTokens: usage?.outputTokens ?? 0
        )
        await APIUsageLogger.shared.log(
            model: Self.batchModel, label: "editorial batch",
            inputTokens: tokenUsage.inputTokens, outputTokens: tokenUsage.outputTokens, durationMs: 0
        )
        try await storeInThread(feedback: feedback, photoAssetId: photoAssetId, threadRepo: threadRepo)
        return (feedback, tokenUsage)
    }

    // MARK: - Private helpers

    private func buildSystemPrompt() -> String {
        """
        You are an expert photography critic and composition analyst specializing in fine art and darkroom printing. \
        Review this image and provide constructive editorial feedback for a photographer who prints in \
        platinum-palladium, cyanotype, silver gelatin, and inkjet processes. Focus on tonal values appropriate \
        for analog printing. Respond ONLY with raw JSON — no markdown fences, no code blocks, no preamble. \
        The JSON schema is specified in the user message. Return null for any field where you have no recommendation.
        """
    }

    private func buildUserPrompt(
        threadHistory: [ThreadEntry],
        photoMetadata: String?,
        printAttemptHistory: [PrintAttempt]?,
        scope: ReviewScope = .full,
        imageWidth: Int? = nil,
        imageHeight: Int? = nil
    ) -> String {
        var prompt = "Please critique this photograph and return ONLY raw JSON matching this exact schema:\n\n"

        if let w = imageWidth, let h = imageHeight {
            prompt += "The image you are viewing is \(w)×\(h) pixels. All crop_suggestions percentages (left_pct, top_pct, right_pct, bottom_pct) are relative to these dimensions (0.0 = left/top edge, 1.0 = right/bottom edge). Ensure your crop rectangles are geometrically valid and visually match what you see in the image.\n\n"
        }

        // Always include the base fields
        prompt += "{\n"
        prompt += "  \"composition_score\": <1-10 integer>,\n"
        prompt += "  \"print_readiness\": \"<ready|needs work>\",\n"
        prompt += "  \"analysis\": \"<one paragraph critique>\",\n"

        // Adjustments — included for .full and .adjustments
        if scope == .full || scope == .adjustments {
            prompt += """
              "adjustments": {
                "exposure": <-5.0 to +5.0 stops as decimal, or null>,
                "contrast": <-100 to +100 integer, or null>,
                "highlights": <-100 to +100 integer, or null>,
                "shadows": <-100 to +100 integer, or null>,
                "whites": <-100 to +100 integer, or null>,
                "blacks": <-100 to +100 integer, or null>,
                "saturation": <-100 to +100 integer, or null>,
                "vibrance": <-100 to +100 integer, or null>,
                "rationale": "<why these specific values>"
              },
            """
        } else {
            prompt += "  \"adjustments\": null,\n"
        }

        // Crops — included for .full and .cropsOnly
        if scope == .full || scope == .cropsOnly {
            prompt += """
              "crop_suggestions": [
                {
                  "label": "<short descriptive name>",
                  "description": "<why this crop improves the image>",
                  "left_pct": <0.0-1.0 left edge>,
                  "top_pct": <0.0-1.0 top edge>,
                  "right_pct": <0.0-1.0 right edge>,
                  "bottom_pct": <0.0-1.0 bottom edge>
                }
              ],
            """
        } else {
            prompt += "  \"crop_suggestions\": [],\n"
        }

        // Masking — included for .full and .adjustments
        if scope == .full || scope == .adjustments {
            prompt += "  \"masking_hints\": [\"<burn/dodge instructions with stops>\"],\n"
            prompt += """
              "regional_adjustments": [
                {
                  "region_label": "<sky|foreground|face|shadow|highlight zone>",
                  "region_description": "<what region and why it needs different treatment>",
                  "geometry_hint": "<upper third|lower half|center|left side|right side>",
                  "adjustments": {
                    "exposure": <-5.0 to +5.0 or null>,
                    "contrast": <-100 to +100 integer or null>,
                    "highlights": <-100 to +100 integer or null>,
                    "shadows": <-100 to +100 integer or null>,
                    "whites": <-100 to +100 integer or null>,
                    "blacks": <-100 to +100 integer or null>,
                    "saturation": <-100 to +100 integer or null>,
                    "vibrance": <-100 to +100 integer or null>,
                    "rationale": "<reason for regional treatment>"
                  }
                }
              ],
            """
        } else {
            prompt += "  \"masking_hints\": [],\n"
            prompt += "  \"regional_adjustments\": null,\n"
        }

        // Always include strengths/areas/directions
        prompt += "  \"strengths\": [\"<strength>\"],\n"
        prompt += "  \"areas_for_improvement\": [\"<area>\"],\n"
        prompt += "  \"suggested_edit_directions\": [\"<direction>\"],\n"

        // Metadata — included for .full and .metadataOnly
        if scope == .full || scope == .metadataOnly {
            prompt += """
              "metadata_enrichment": {
                "location_name": "<city, country or null>",
                "venue": "<specific venue name or null>",
                "coordinates": {"lat": <number>, "lon": <number>},
                "subjects": ["<subject tags>"],
                "mood": "<mood word or null>",
                "decade_style": "<visual era style or null>"
              },
            """
        } else {
            prompt += "  \"metadata_enrichment\": null,\n"
        }

        // Geometry — included for .full and .geometryOnly
        if scope == .full || scope == .geometryOnly {
            prompt += """
              "geometry_correction": {
                "rotation_degrees": <degrees to straighten horizon, CCW negative / CW positive, or null>,
                "vertical_perspective": <-100 to +100, correct converging verticals e.g. buildings leaning back, or null>,
                "horizontal_perspective": <-100 to +100, or null>,
                "rationale": "<what you detected e.g. 'horizon tilts 1.5° left, buildings show keystoning'>"
              }
            """
        } else {
            prompt += "  \"geometry_correction\": null\n"
        }

        prompt += "}"

        // Scope-specific instructions
        switch scope {
        case .full:
            prompt += "\n\nReturn 0–2 crop_suggestions. CRITICAL: Never crop through a person's head, face, or neck — always include the full head with headroom. For geometry_correction, look for tilted horizons, converging verticals (tall buildings), or lens tilt artifacts. Return null if the geometry looks correct."
            prompt += "\nFor metadata_enrichment, use any location or date clues in the provided metadata to infer GPS coordinates and venue."
        case .adjustments:
            prompt += "\n\nFocus your analysis on tonal adjustments. Provide detailed exposure, contrast, highlights, shadows, whites, blacks, saturation, and vibrance values. Include specific burn/dodge masking hints with stops."
        case .cropsOnly:
            prompt += "\n\nFocus your analysis on composition and cropping. Return 1–3 crop_suggestions with precise percentages. Analyze leading lines, rule of thirds, negative space, and subject placement."
            prompt += "\n\nCRITICAL: Never crop through a person's head, face, or neck. If a person is in the frame, the crop MUST include their entire head with comfortable headroom above. Cropping at the forehead, eyes, or neck is never acceptable."
        case .geometryOnly:
            prompt += "\n\nFocus your analysis on geometry correction. Look carefully for tilted horizons, converging verticals (tall buildings), barrel/pincushion distortion, and lens tilt artifacts. Provide precise rotation degrees and perspective values."
        case .metadataOnly:
            prompt += "\n\nFocus your analysis on identifying metadata from visual cues. Infer location, venue, subjects, mood, and era/style. Use any EXIF clues in the provided metadata to estimate GPS coordinates."
        }

        if let metadata = photoMetadata {
            prompt += "\n\nPhoto metadata:\n\(metadata)"
        }

        let relevantEntries = threadHistory
            .filter { ["text_note", "aiConversation", "print_attempt"].contains($0.kind) }
            .suffix(5)

        if !relevantEntries.isEmpty {
            prompt += "\n\nPhotographer's notes:\n"
            for entry in relevantEntries {
                if let data = entry.contentJson.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let text = json["text"] as? String ?? json["content"] as? String ?? entry.contentJson
                    prompt += "- \(text)\n"
                } else {
                    prompt += "- \(entry.contentJson)\n"
                }
            }
        }

        if let printHistory = printAttemptHistory, !printHistory.isEmpty {
            prompt += "\n\nPrint attempt history:\n"
            for attempt in printHistory.prefix(3) {
                prompt += "- \(attempt.printType.rawValue) on \(attempt.paper): \(attempt.outcome.rawValue)\n"
            }
        }

        return prompt
    }

    private nonisolated func parseResponse(_ data: Data) throws -> (EditorialFeedback, AnthropicResponse.Usage?) {
        let decoder = JSONDecoder()

        let anthropicResponse: AnthropicResponse
        do {
            anthropicResponse = try decoder.decode(AnthropicResponse.self, from: data)
        } catch {
            throw CritiqueError.invalidResponse(details: "Could not decode Anthropic response: \(error)")
        }

        guard let text = anthropicResponse.content.first(where: { $0.type == "text" })?.text else {
            throw CritiqueError.invalidResponse(details: "Empty or missing text content")
        }

        // Strip any markdown code fences Claude might include despite instructions
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let cleanedData = cleaned.data(using: .utf8) else {
            throw CritiqueError.invalidResponse(details: "Could not re-encode cleaned response")
        }

        do {
            let feedback = try decoder.decode(EditorialFeedback.self, from: cleanedData)
            return (feedback, anthropicResponse.usage)
        } catch {
            throw CritiqueError.invalidResponse(details: "Could not decode EditorialFeedback: \(error)")
        }
    }

    /// Loads a proxy JPEG, resizes to max 1024px longest edge, and re-compresses at 0.65 quality.
    /// Keeps the payload small (~80-130 KB) without sacrificing enough detail for critique.
    /// Returns (jpegData, widthPx, heightPx) for the resized image sent to the API.
    private static nonisolated func prepareImageDataWithDimensions(from url: URL) -> (Data, Int, Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let maxEdge: CGFloat = 1024
        let origW = CGFloat(cgImage.width)
        let origH = CGFloat(cgImage.height)
        let scale = min(1.0, maxEdge / max(origW, origH))
        let newW = Int(origW * scale)
        let newH = Int(origH * scale)

        guard let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx.makeImage() else { return nil }

        let nsImage = NSImage(cgImage: resized, size: NSSize(width: newW, height: newH))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65]) else { return nil }
        return (data, newW, newH)
    }

    private static nonisolated func prepareImageData(from url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        let maxEdge: CGFloat = 1024
        let origW = CGFloat(cgImage.width)
        let origH = CGFloat(cgImage.height)
        let scale = min(1.0, maxEdge / max(origW, origH))
        let newW = Int(origW * scale)
        let newH = Int(origH * scale)

        guard let ctx = CGContext(
            data: nil,
            width: newW, height: newH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .high
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let resized = ctx.makeImage() else { return nil }

        let nsImage = NSImage(cgImage: resized, size: NSSize(width: newW, height: newH))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.65])
    }

    private func storeInThread(
        feedback: EditorialFeedback,
        photoAssetId: String,
        threadRepo: any ThreadEntryRepository
    ) async throws {
        var contentDict: [String: Any] = [
            "isCloudGenerated": true,
            "model": Self.model,
            "compositionScore": feedback.compositionScore,
            "printReadiness": feedback.printReadiness,
            "analysis": feedback.analysis,
            "strengths": feedback.strengths,
            "areasForImprovement": feedback.areasForImprovement,
            "suggestedEditDirections": feedback.suggestedEditDirections,
            "maskingHints": feedback.maskingHints
        ]
        if let rationale = feedback.adjustments?.rationale {
            contentDict["adjustmentsRationale"] = rationale
        }

        let contentData = try JSONSerialization.data(withJSONObject: contentDict)
        let contentJson = String(data: contentData, encoding: .utf8) ?? "{}"

        try await threadRepo.addEntry(
            photoId: photoAssetId,
            kind: "aiConversation",
            contentJson: contentJson,
            authoredBy: "ai"
        )
    }
}
