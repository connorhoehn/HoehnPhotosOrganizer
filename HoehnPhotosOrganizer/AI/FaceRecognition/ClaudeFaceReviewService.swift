import AppKit
import Foundation

// MARK: - ClaudeFaceReviewService

/// Sends borderline face matches to Claude Vision for verification.
///
/// Workflow:
///   1. Fetch all `needs_review = true` face embeddings (have a tentative personId).
///   2. For each, fetch 1–2 confirmed crops for that candidate person.
///   3. POST to Anthropic Messages API with reference image(s) + candidate image.
///   4. Parse structured JSON response { match, confidence, reasoning }.
///   5. Confirm (labeledBy="claude") or reject (clear personId) each face.
actor ClaudeFaceReviewService {

    // MARK: - Result types

    struct ReviewDecision: Sendable {
        let faceId: String
        let confirmed: Bool
        let confidence: Int
        let reasoning: String
    }

    struct BatchResult: Sendable {
        let confirmed: Int
        let rejected: Int
        let skipped: Int  // no reference crops available
    }

    // MARK: - Init

    private let authManager: AnthropicAuthManager
    private let model = "claude-sonnet-4-20250514"
    private let apiBase = URL(string: "https://api.anthropic.com/v1/messages")!

    init(authManager: AnthropicAuthManager) {
        self.authManager = authManager
    }

    // MARK: - Public

    func processReviewQueue(
        faceRepo: FaceEmbeddingRepository,
        personRepo: PersonRepository
    ) async throws -> BatchResult {
        let pending = try await faceRepo.fetchNeedsReviewGalleryRecords()
        guard !pending.isEmpty else { return BatchResult(confirmed: 0, rejected: 0, skipped: 0) }

        let people = try await personRepo.fetchAll()
        var confirmed = 0, rejected = 0, skipped = 0

        for face in pending {
            guard let personId = face.embedding.personId else { skipped += 1; continue }
            let personName = people.first(where: { $0.id == personId })?.name ?? "this person"

            let refs = try await faceRepo.fetchConfirmedGalleryRecords(for: personId)
            let refJPEGs = refs.prefix(2).compactMap { Self.cropJPEG(from: $0.proxyURL, bbox: $0.bbox) }
            guard !refJPEGs.isEmpty else { skipped += 1; continue }
            guard let candidateJPEG = Self.cropJPEG(from: face.proxyURL, bbox: face.bbox) else {
                skipped += 1; continue
            }

            do {
                let decision = try await reviewFace(
                    faceId: face.id,
                    personName: personName,
                    referenceJPEGs: Array(refJPEGs),
                    candidateJPEG: candidateJPEG
                )
                if decision.confirmed {
                    try await faceRepo.assignPerson(faceIds: [face.id], personId: personId, labeledBy: "claude")
                    confirmed += 1
                } else {
                    try await faceRepo.clearPerson(faceId: face.id)
                    rejected += 1
                }
                print("[ClaudeFaceReview] \(face.id): confirmed=\(decision.confirmed) confidence=\(decision.confidence) — \(decision.reasoning)")
            } catch {
                print("[ClaudeFaceReview] Error reviewing \(face.id): \(error.localizedDescription)")
                skipped += 1
            }
        }

        return BatchResult(confirmed: confirmed, rejected: rejected, skipped: skipped)
    }

    // MARK: - Single face review

    private func reviewFace(
        faceId: String,
        personName: String,
        referenceJPEGs: [Data],
        candidateJPEG: Data
    ) async throws -> ReviewDecision {
        let apiKey = try await authManager.getAPIKey()

        // Build content blocks: reference images, then candidate
        var contentBlocks: [[String: Any]] = []

        for (i, refData) in referenceJPEGs.enumerated() {
            contentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": refData.base64EncodedString()
                ]
            ])
            contentBlocks.append([
                "type": "text",
                "text": i == 0 ? "Reference photo of \(personName):" : "Another reference photo of \(personName):"
            ])
        }

        contentBlocks.append([
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": "image/jpeg",
                "data": candidateJPEG.base64EncodedString()
            ]
        ])
        contentBlocks.append([
            "type": "text",
            "text": """
            Candidate photo: Is this the same person as \(personName)?

            Respond with valid JSON only, no other text:
            {"match": true or false, "confidence": 0-100, "reasoning": "one sentence explanation"}
            """
        ])

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "system": "You are a face verification assistant. Compare faces carefully and respond only with the requested JSON.",
            "messages": [["role": "user", "content": contentBlocks]]
        ]

        var request = URLRequest(url: apiBase, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<binary>"
            throw VisionModelError.httpError(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, body: body)
        }

        // Extract text from Anthropic response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String else {
            throw VisionModelError.malformedResponse(detail: "Could not extract text from Anthropic response")
        }

        return try parseDecision(faceId: faceId, text: text)
    }

    // MARK: - Response parsing

    private func parseDecision(faceId: String, text: String) throws -> ReviewDecision {
        // Strip markdown code fences if present
        let cleaned = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let match = json["match"] as? Bool else {
            throw VisionModelError.malformedResponse(detail: "Could not parse review JSON: \(text.prefix(200))")
        }

        let confidence = json["confidence"] as? Int ?? 50
        let reasoning = json["reasoning"] as? String ?? ""
        return ReviewDecision(faceId: faceId, confirmed: match, confidence: confidence, reasoning: reasoning)
    }

    // MARK: - Static crop helper (used by gallery view too)

    static func cropJPEG(from proxyURL: URL, bbox: CGRect) -> Data? {
        guard let cgImage = loadCGImage(from: proxyURL),
              let cropped = FaceEmbeddingService.cropFace(from: cgImage, bbox: bbox) else {
            return nil
        }
        let nsImage = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        guard let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }

    private static func loadCGImage(from url: URL) -> CGImage? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
