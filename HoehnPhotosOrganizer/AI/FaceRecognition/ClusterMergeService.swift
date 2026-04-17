import AppKit
import Foundation

// MARK: - ClusterMergeService

/// Uses Claude Vision to cross-check face clusters and suggest merges.
///
/// After initial auto-clustering, this service:
///   1. Generates a composite sprite image for each cluster (grid of top face crops).
///   2. Generates reference sprites for each named (known) person.
///   3. Sends all sprites in one Claude Vision call, asking for high-confidence matches.
///   4. Parses the response into merge suggestions for user confirmation.
///
/// No auto-merge — always requires user confirmation via `ClusterMergeReviewSheet`.
actor ClusterMergeService {

    // MARK: - Types

    struct MergeSuggestion: Identifiable, Sendable {
        let id: String
        /// The source — either a cluster personId (like "Person 3") or a named person.
        let sourceLabel: String
        let sourcePersonId: String
        /// The target — either another cluster personId or a named person.
        let targetLabel: String
        let targetPersonId: String
        /// Claude's reasoning for the match.
        let reasoning: String
        /// Sprite images for display in the review sheet.
        let sourceSprite: Data  // JPEG
        let targetSprite: Data  // JPEG
    }

    struct MergeResult: Sendable {
        let suggestions: [MergeSuggestion]
        let clustersAnalyzed: Int
        let knownPeopleAnalyzed: Int
    }

    // MARK: - Init

    private let authManager: AnthropicAuthManager
    private let model = "claude-haiku-4-5-20251001"
    private let apiBase = URL(string: "https://api.anthropic.com/v1/messages")!

    init(authManager: AnthropicAuthManager) {
        self.authManager = authManager
    }

    // MARK: - Public

    /// Analyze all clusters and known people, returning merge suggestions.
    func analyzeClusters(
        faceRepo: FaceEmbeddingRepository,
        personRepo: PersonRepository
    ) async throws -> MergeResult {
        let allPeople = try await personRepo.fetchAll()

        // Separate into clusters (auto-generated "Person N") and known (user-named)
        let clusterPeople = allPeople.filter { $0.name.hasPrefix("Person ") }
        let knownPeople = allPeople.filter { !$0.name.hasPrefix("Person ") && $0.name != "Stranger" }

        // Need at least 2 groups total to suggest merges
        let totalGroups = clusterPeople.count + knownPeople.count
        guard totalGroups >= 2 else {
            return MergeResult(suggestions: [], clustersAnalyzed: clusterPeople.count, knownPeopleAnalyzed: knownPeople.count)
        }

        // Generate sprites for each group
        var labeledSprites: [(label: String, personId: String, sprite: Data)] = []

        // Cluster sprites: labeled A, B, C, ...
        for (i, person) in clusterPeople.enumerated() {
            let galleryRecords = try await faceRepo.fetchConfirmedGalleryRecords(for: person.id)
            let records = galleryRecords.isEmpty
                ? try await fetchGalleryRecordsForPerson(person.id, faceRepo: faceRepo)
                : galleryRecords

            guard !records.isEmpty else { continue }

            if let sprite = generateSprite(from: records, maxCrops: 6) {
                // A..Z, then AA, AB, ... to avoid duplicate labels beyond 26 clusters
                let letter: String = {
                    if i < 26 {
                        return String(UnicodeScalar(65 + i)!)
                    } else {
                        return String(UnicodeScalar(65 + (i / 26) - 1)!) + String(UnicodeScalar(65 + (i % 26))!)
                    }
                }()
                let label = "Cluster \(letter) (\(person.name))"
                labeledSprites.append((label: label, personId: person.id, sprite: sprite))
            }
        }

        // Known-person reference sprites
        for person in knownPeople {
            let records = try await faceRepo.fetchConfirmedGalleryRecords(for: person.id)
            guard !records.isEmpty else { continue }

            if let sprite = generateSprite(from: records, maxCrops: 3) {
                labeledSprites.append((label: "Known: \(person.name)", personId: person.id, sprite: sprite))
            }
        }

        guard labeledSprites.count >= 2 else {
            return MergeResult(suggestions: [], clustersAnalyzed: clusterPeople.count, knownPeopleAnalyzed: knownPeople.count)
        }

        // Call Claude Vision with all sprites
        let rawMatches = try await callClaudeVision(sprites: labeledSprites)

        // Build MergeSuggestions with sprite data for the review sheet
        var suggestions: [MergeSuggestion] = []
        for match in rawMatches {
            guard let source = labeledSprites.first(where: { $0.label == match.labelA }),
                  let target = labeledSprites.first(where: { $0.label == match.labelB }) else { continue }

            suggestions.append(MergeSuggestion(
                id: UUID().uuidString,
                sourceLabel: source.label,
                sourcePersonId: source.personId,
                targetLabel: target.label,
                targetPersonId: target.personId,
                reasoning: match.reasoning,
                sourceSprite: source.sprite,
                targetSprite: target.sprite
            ))
        }

        print("[ClusterMergeService] Found \(suggestions.count) merge suggestion(s) from \(labeledSprites.count) groups")
        return MergeResult(
            suggestions: suggestions,
            clustersAnalyzed: clusterPeople.count,
            knownPeopleAnalyzed: knownPeople.count
        )
    }

    // MARK: - Sprite generation

    /// Generates a composite sprite image: a grid of top face crops.
    /// Returns JPEG data, or nil if no crops could be produced.
    private func generateSprite(from records: [FaceGalleryRecord], maxCrops: Int) -> Data? {
        let crops: [CGImage] = records.prefix(maxCrops).compactMap { record in
            ClaudeFaceReviewService.cropJPEG(from: record.proxyURL, bbox: record.bbox)
                .flatMap { jpegData in
                    guard let provider = CGDataProvider(data: jpegData as CFData),
                          let img = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                        return nil
                    }
                    return img
                }
        }

        guard !crops.isEmpty else { return nil }

        let cellSize = 120  // pixels per cell
        let cols = min(crops.count, 3)
        let rows = (crops.count + cols - 1) / cols
        let width = cols * cellSize
        let height = rows * cellSize

        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Fill background
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        for (i, crop) in crops.enumerated() {
            let col = i % cols
            let row = i / cols
            // CGContext has origin at bottom-left, draw rows bottom-up
            let flippedRow = rows - 1 - row
            let rect = CGRect(x: col * cellSize, y: flippedRow * cellSize, width: cellSize, height: cellSize)
            ctx.draw(crop, in: rect)
        }

        guard let compositeImage = ctx.makeImage() else { return nil }
        let nsImage = NSImage(cgImage: compositeImage, size: NSSize(width: width, height: height))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.80])
    }

    // MARK: - Claude Vision call

    private struct RawMatch {
        let labelA: String
        let labelB: String
        let reasoning: String
    }

    private func callClaudeVision(sprites: [(label: String, personId: String, sprite: Data)]) async throws -> [RawMatch] {
        let apiKey = try await authManager.getAPIKey()

        // Build content blocks: one image + label per group
        var contentBlocks: [[String: Any]] = []

        for entry in sprites {
            contentBlocks.append([
                "type": "text",
                "text": "Group \"\(entry.label)\":"
            ])
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": entry.sprite.base64EncodedString()
                ]
            ])
        }

        // Final instruction
        contentBlocks.append([
            "type": "text",
            "text": """
            Each group above is either a face cluster or a known person from a photo library. \
            Groups labeled "Cluster X" are auto-detected clusters. Groups labeled "Known: Name" are confirmed people.

            Do any clusters appear to be the same person as each other, or match a known person? \
            List only HIGH-CONFIDENCE matches where you are very sure the faces are the same person.

            Respond with valid JSON only, no other text:
            {"matches": [{"group_a": "exact label A", "group_b": "exact label B", "reasoning": "one sentence"}]}

            If no confident matches exist, respond: {"matches": []}
            """
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": "You are a face matching assistant for a photo library. Compare face groups carefully. Only report matches where you are highly confident the faces belong to the same person. Be conservative — false positives waste the user's time.",
            "messages": [["role": "user", "content": contentBlocks]]
        ]

        var request = URLRequest(url: apiBase, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let responseBody = String(data: data, encoding: .utf8) ?? "<binary>"
            throw VisionModelError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: responseBody)
        }

        // Extract text from Anthropic response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String else {
            throw VisionModelError.malformedResponse(detail: "Could not extract text from Anthropic response")
        }

        return parseMatches(text: text)
    }

    // MARK: - Response parsing

    private func parseMatches(text: String) -> [RawMatch] {
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]] else {
            print("[ClusterMergeService] Could not parse response JSON: \(text.prefix(300))")
            return []
        }

        return matches.compactMap { match in
            guard let labelA = match["group_a"] as? String,
                  let labelB = match["group_b"] as? String else { return nil }
            let reasoning = match["reasoning"] as? String ?? ""
            return RawMatch(labelA: labelA, labelB: labelB, reasoning: reasoning)
        }
    }

    // MARK: - Helpers

    /// Fetch gallery records for a person when fetchConfirmedGalleryRecords returns empty
    /// (e.g., because the LIMIT in that query didn't match).
    private func fetchGalleryRecordsForPerson(_ personId: String, faceRepo: FaceEmbeddingRepository) async throws -> [FaceGalleryRecord] {
        // Fetch all faces for this person and convert to gallery records using the main gallery query
        let allRecords = try await faceRepo.fetchGalleryRecords()
        return allRecords.filter { $0.embedding.personId == personId }.prefix(6).map { $0 }
    }
}
