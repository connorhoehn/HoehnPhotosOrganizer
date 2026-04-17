import Foundation

// MARK: - PhotoCluster

/// A group of photos clustered by temporal proximity and GPS location.
struct PhotoCluster: Identifiable, Sendable {
    let id: String
    var photoIds: [String]
    var earliestDate: Date?
    var latestDate: Date?
    var centroidLatitude: Double?
    var centroidLongitude: Double?
    var suggestedTitle: String    // AI-generated or heuristic fallback

    var photoCount: Int { photoIds.count }

    var dateRange: DateInterval? {
        guard let start = earliestDate, let end = latestDate else { return nil }
        return DateInterval(start: start, end: max(start, end))
    }

    /// First 5 photo IDs for thumbnail preview.
    var representativePhotoIds: [String] {
        Array(photoIds.prefix(5))
    }
}

// MARK: - PhotoTimestamp

/// Lightweight struct pairing a photo ID with its capture metadata for clustering.
struct PhotoTimestamp: Sendable {
    let photoId: String
    let captureDate: Date?
    let latitude: Double?
    let longitude: Double?
}

// MARK: - JobBucketingService

/// Actor that analyses `PhotoAsset` arrays and proposes named sub-job buckets.
///
/// The clustering pipeline:
///   1. **Temporal gap clustering** — primary signal. Gaps > 4 hours split into separate clusters.
///   2. **GPS cluster reinforcement** — within a temporal cluster, large location jumps create sub-splits.
///   3. **AI naming** — EXIF date ranges + GPS coordinates sent to Claude for descriptive titles.
///   4. Falls back to heuristic naming (date-based) when Claude is unavailable.
///
/// This service works with `PhotoAsset` records (post-import) and is used by:
///   - "Split Job" action in JobDetailView (split an existing large job)
///   - Direct import flow in LibraryViewModel (auto-bucket imports > 50 photos)
actor JobBucketingService {

    private let authManager = AnthropicAuthManager()

    /// Gap threshold in seconds (4 hours).
    private let temporalGapThreshold: TimeInterval = 4 * 3600

    /// GPS distance threshold in degrees (~11km at equator) for reinforcement splits.
    private let gpsDistanceThreshold: Double = 0.1

    // MARK: - Public API

    /// Analyse photos and return proposed clusters. Returns empty if < 2 photos.
    /// Set `enableAINaming` to false to skip the Claude API call.
    func proposeCluster(
        photos: [PhotoTimestamp],
        enableAINaming: Bool = true
    ) async -> [PhotoCluster] {
        guard photos.count >= 2 else {
            // Single photo or empty — no splitting needed
            if let photo = photos.first {
                return [PhotoCluster(
                    id: UUID().uuidString,
                    photoIds: [photo.photoId],
                    earliestDate: photo.captureDate,
                    latestDate: photo.captureDate,
                    centroidLatitude: photo.latitude,
                    centroidLongitude: photo.longitude,
                    suggestedTitle: "Single Photo"
                )]
            }
            return []
        }

        // Log input stats
        let datedPhotos = photos.filter { $0.captureDate != nil }
        let undatedPhotos = photos.count - datedPhotos.count
        let dates = datedPhotos.compactMap(\.captureDate).sorted()
        if let earliest = dates.first, let latest = dates.last {
            let iso = ISO8601DateFormatter()
            print("[JobBucketing] proposeCluster: \(photos.count) photos (\(datedPhotos.count) dated, \(undatedPhotos) undated), range: \(iso.string(from: earliest)) to \(iso.string(from: latest))")
        } else {
            print("[JobBucketing] proposeCluster: \(photos.count) photos, all undated")
        }

        // Step 1: Temporal gap clustering
        var clusters = temporalCluster(photos)

        // Step 2: GPS reinforcement — sub-split clusters with large location jumps
        clusters = gpsReinforce(clusters, photos: photos)

        // Step 3: Merge tiny clusters (< 5 photos) into nearest neighbor
        clusters = mergeTinyClusters(clusters)

        // Step 4: AI naming (or heuristic fallback)
        if enableAINaming {
            clusters = await aiNameClusters(clusters)
        } else {
            clusters = heuristicNameClusters(clusters)
        }

        print("[JobBucketing] proposeCluster: proposed \(clusters.count) cluster(s)")
        for (i, c) in clusters.enumerated() {
            let iso = ISO8601DateFormatter()
            let startStr = c.earliestDate.map { iso.string(from: $0) } ?? "nil"
            let endStr = c.latestDate.map { iso.string(from: $0) } ?? "nil"
            print("[JobBucketing]   cluster \(i+1): \(c.photoCount) photos, \(startStr) – \(endStr), title: \(c.suggestedTitle)")
        }

        return clusters
    }

    /// Convenience: extract `PhotoTimestamp` data from `PhotoAsset` EXIF JSON.
    nonisolated static func extractTimestamps(from photos: [(id: String, rawExifJson: String?)]) -> [PhotoTimestamp] {
        let iso = ISO8601DateFormatter()
        let decoder = JSONDecoder()

        var nilExifCount = 0
        var parseFailCount = 0
        var dateParseFailCount = 0

        let results = photos.map { photo -> PhotoTimestamp in
            guard let jsonStr = photo.rawExifJson else {
                nilExifCount += 1
                return PhotoTimestamp(photoId: photo.id, captureDate: nil, latitude: nil, longitude: nil)
            }
            guard let data = jsonStr.data(using: .utf8),
                  let exif = try? decoder.decode(EXIFSnapshot.CodableSnapshot.self, from: data)
            else {
                parseFailCount += 1
                return PhotoTimestamp(photoId: photo.id, captureDate: nil, latitude: nil, longitude: nil)
            }

            let date = exif.captureDate.flatMap { iso.date(from: $0) }
            if exif.captureDate != nil && date == nil {
                dateParseFailCount += 1
            }
            return PhotoTimestamp(
                photoId: photo.id,
                captureDate: date,
                latitude: exif.latitude,
                longitude: exif.longitude
            )
        }

        let withDate = results.filter { $0.captureDate != nil }.count
        let withGPS = results.filter { $0.latitude != nil }.count
        print("[JobBucketing] extractTimestamps: \(photos.count) photos — \(withDate) with date, \(withGPS) with GPS, \(nilExifCount) nil EXIF, \(parseFailCount) parse failures, \(dateParseFailCount) date format mismatches")

        return results
    }

    // MARK: - Step 1: Temporal Clustering

    private func temporalCluster(_ photos: [PhotoTimestamp]) -> [PhotoCluster] {
        // Separate dated from undated
        let dated = photos
            .filter { $0.captureDate != nil }
            .sorted { $0.captureDate! < $1.captureDate! }
        let undated = photos.filter { $0.captureDate == nil }

        guard !dated.isEmpty else {
            // All undated — single cluster
            return [PhotoCluster(
                id: UUID().uuidString,
                photoIds: undated.map(\.photoId),
                earliestDate: nil,
                latestDate: nil,
                centroidLatitude: nil,
                centroidLongitude: nil,
                suggestedTitle: "Undated Photos"
            )]
        }

        var clusters: [PhotoCluster] = []
        var currentIds: [String] = [dated[0].photoId]
        var currentStart = dated[0].captureDate!
        var currentEnd = dated[0].captureDate!

        for i in 1..<dated.count {
            let prev = dated[i - 1].captureDate!
            let curr = dated[i].captureDate!
            let gap = curr.timeIntervalSince(prev)

            if gap > temporalGapThreshold {
                // Finalize current cluster
                clusters.append(makeCluster(ids: currentIds, start: currentStart, end: currentEnd, photos: dated))
                currentIds = []
                currentStart = curr
            }
            currentIds.append(dated[i].photoId)
            currentEnd = curr
        }
        // Finalize last cluster
        clusters.append(makeCluster(ids: currentIds, start: currentStart, end: currentEnd, photos: dated))

        // Add undated as a separate cluster if present
        if !undated.isEmpty {
            clusters.append(PhotoCluster(
                id: UUID().uuidString,
                photoIds: undated.map(\.photoId),
                earliestDate: nil,
                latestDate: nil,
                centroidLatitude: nil,
                centroidLongitude: nil,
                suggestedTitle: "Undated Photos"
            ))
        }

        return clusters
    }

    private func makeCluster(ids: [String], start: Date, end: Date, photos: [PhotoTimestamp]) -> PhotoCluster {
        let clusterPhotos = photos.filter { ids.contains($0.photoId) }
        let lats = clusterPhotos.compactMap(\.latitude)
        let lons = clusterPhotos.compactMap(\.longitude)
        let avgLat = lats.isEmpty ? nil : lats.reduce(0, +) / Double(lats.count)
        let avgLon = lons.isEmpty ? nil : lons.reduce(0, +) / Double(lons.count)

        return PhotoCluster(
            id: UUID().uuidString,
            photoIds: ids,
            earliestDate: start,
            latestDate: end,
            centroidLatitude: avgLat,
            centroidLongitude: avgLon,
            suggestedTitle: ""  // Set later by naming step
        )
    }

    // MARK: - Step 2: GPS Reinforcement

    private func gpsReinforce(_ clusters: [PhotoCluster], photos: [PhotoTimestamp]) -> [PhotoCluster] {
        var result: [PhotoCluster] = []

        for cluster in clusters {
            // Only split clusters that have GPS data and > 10 photos
            let clusterPhotos = photos.filter { cluster.photoIds.contains($0.photoId) }
            let withGPS = clusterPhotos.filter { $0.latitude != nil && $0.longitude != nil }

            guard withGPS.count >= 5, cluster.photoCount > 10 else {
                result.append(cluster)
                continue
            }

            // Walk through photos in order and split when GPS jumps significantly
            let ordered = clusterPhotos
                .filter { $0.captureDate != nil }
                .sorted { $0.captureDate! < $1.captureDate! }

            var subClusters: [[String]] = []
            var currentSub: [String] = [ordered[0].photoId]
            var lastLat = ordered[0].latitude
            var lastLon = ordered[0].longitude

            for i in 1..<ordered.count {
                let photo = ordered[i]
                if let lat = photo.latitude, let lon = photo.longitude,
                   let prevLat = lastLat, let prevLon = lastLon {
                    let dist = abs(lat - prevLat) + abs(lon - prevLon)
                    if dist > gpsDistanceThreshold {
                        subClusters.append(currentSub)
                        currentSub = []
                    }
                    lastLat = lat
                    lastLon = lon
                }
                currentSub.append(photo.photoId)
            }
            subClusters.append(currentSub)

            // Only accept GPS split if it produced > 1 meaningful cluster
            if subClusters.count > 1 && subClusters.allSatisfy({ $0.count >= 3 }) {
                for sub in subClusters {
                    let subPhotos = photos.filter { sub.contains($0.photoId) }
                    let dates = subPhotos.compactMap(\.captureDate).sorted()
                    let lats = subPhotos.compactMap(\.latitude)
                    let lons = subPhotos.compactMap(\.longitude)
                    result.append(PhotoCluster(
                        id: UUID().uuidString,
                        photoIds: sub,
                        earliestDate: dates.first,
                        latestDate: dates.last,
                        centroidLatitude: lats.isEmpty ? nil : lats.reduce(0, +) / Double(lats.count),
                        centroidLongitude: lons.isEmpty ? nil : lons.reduce(0, +) / Double(lons.count),
                        suggestedTitle: ""
                    ))
                }
            } else {
                result.append(cluster)
            }
        }

        return result
    }

    // MARK: - Step 3: Merge Tiny Clusters

    private func mergeTinyClusters(_ clusters: [PhotoCluster]) -> [PhotoCluster] {
        guard clusters.count > 1 else { return clusters }

        var result: [PhotoCluster] = []
        var pending: PhotoCluster? = nil

        for cluster in clusters {
            if cluster.photoCount < 5 {
                // Merge into pending or previous
                if var p = pending {
                    p.photoIds.append(contentsOf: cluster.photoIds)
                    if let cd = cluster.earliestDate {
                        if let pe = p.earliestDate {
                            if cd < pe { p = PhotoCluster(id: p.id, photoIds: p.photoIds, earliestDate: cd, latestDate: p.latestDate, centroidLatitude: p.centroidLatitude, centroidLongitude: p.centroidLongitude, suggestedTitle: p.suggestedTitle) }
                        }
                    }
                    if let cd = cluster.latestDate {
                        if let pe = p.latestDate {
                            if cd > pe { p = PhotoCluster(id: p.id, photoIds: p.photoIds, earliestDate: p.earliestDate, latestDate: cd, centroidLatitude: p.centroidLatitude, centroidLongitude: p.centroidLongitude, suggestedTitle: p.suggestedTitle) }
                        }
                    }
                    pending = p
                } else if let last = result.last {
                    var merged = last
                    merged.photoIds.append(contentsOf: cluster.photoIds)
                    result[result.count - 1] = merged
                } else {
                    pending = cluster
                }
            } else {
                if let p = pending {
                    // Merge pending tiny cluster into this one
                    var merged = cluster
                    merged.photoIds.insert(contentsOf: p.photoIds, at: 0)
                    if let pe = p.earliestDate, let ce = merged.earliestDate, pe < ce {
                        merged = PhotoCluster(id: merged.id, photoIds: merged.photoIds, earliestDate: pe, latestDate: merged.latestDate, centroidLatitude: merged.centroidLatitude, centroidLongitude: merged.centroidLongitude, suggestedTitle: merged.suggestedTitle)
                    }
                    result.append(merged)
                    pending = nil
                } else {
                    result.append(cluster)
                }
            }
        }

        // If everything was tiny, collapse into one
        if let p = pending {
            if result.isEmpty {
                result.append(p)
            } else {
                var last = result[result.count - 1]
                last.photoIds.append(contentsOf: p.photoIds)
                result[result.count - 1] = last
            }
        }

        return result
    }

    // MARK: - Step 4a: AI Naming

    private func aiNameClusters(_ clusters: [PhotoCluster]) async -> [PhotoCluster] {
        guard let apiKey = try? await authManager.getAPIKey() else {
            return heuristicNameClusters(clusters)
        }

        let prompt = buildNamingPrompt(clusters)
        let startTime = Date()

        do {
            let names = try await callClaudeForNames(prompt: prompt, clusterCount: clusters.count, apiKey: apiKey)
            let durationMs = Int(-startTime.timeIntervalSinceNow * 1000)

            // Log API usage
            await APIUsageLogger.shared.log(
                model: "claude-haiku-4-5",
                label: "job-bucketing-naming",
                inputTokens: prompt.count / 4,   // rough estimate
                outputTokens: names.joined().count / 4,
                durationMs: durationMs
            )

            var result = clusters
            for i in 0..<result.count {
                if i < names.count && !names[i].isEmpty {
                    result[i].suggestedTitle = names[i]
                } else {
                    result[i].suggestedTitle = heuristicName(for: result[i])
                }
            }
            return result
        } catch {
            print("[JobBucketing] Claude naming failed: \(error) — using heuristic fallback")
            return heuristicNameClusters(clusters)
        }
    }

    private func buildNamingPrompt(_ clusters: [PhotoCluster]) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []

        lines.append("You are naming photo session groups for a photographer's triage workflow.")
        lines.append("For each cluster below, suggest a short descriptive title (max 50 chars).")
        lines.append("Format: place name + date if possible, e.g. 'Beach Trip — Malibu, March 15'")
        lines.append("If GPS is available, infer the location. If not, use the date range.")
        lines.append("Return exactly one title per line, in order. No numbering, no quotes.")
        lines.append("")

        for (i, cluster) in clusters.enumerated() {
            var desc = "Cluster \(i + 1): \(cluster.photoCount) photos"
            if let start = cluster.earliestDate {
                desc += ", from \(iso.string(from: start))"
            }
            if let end = cluster.latestDate {
                desc += " to \(iso.string(from: end))"
            }
            if let lat = cluster.centroidLatitude, let lon = cluster.centroidLongitude {
                desc += ", GPS: \(String(format: "%.4f", lat)), \(String(format: "%.4f", lon))"
            }
            lines.append(desc)
        }

        return lines.joined(separator: "\n")
    }

    private func callClaudeForNames(prompt: String, clusterCount: Int, apiKey: String) async throws -> [String] {
        let requestBody: [String: Any] = [
            "model": "claude-haiku-4-5",
            "max_tokens": 512,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw JobBucketingError.apiError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let textBlock = content.first(where: { $0["type"] as? String == "text" }),
              let text = textBlock["text"] as? String
        else {
            throw JobBucketingError.parseError("Unexpected Claude response shape")
        }

        let names = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return names
    }

    // MARK: - Step 4b: Heuristic Naming Fallback

    private func heuristicNameClusters(_ clusters: [PhotoCluster]) -> [PhotoCluster] {
        var result = clusters
        for i in 0..<result.count {
            result[i].suggestedTitle = heuristicName(for: result[i])
        }
        return result
    }

    private func heuristicName(for cluster: PhotoCluster) -> String {
        guard let start = cluster.earliestDate else {
            return "Undated Photos — \(cluster.photoCount) photos"
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .none

        if let end = cluster.latestDate, !Calendar.current.isDate(start, inSameDayAs: end) {
            return "Session — \(df.string(from: start)) to \(df.string(from: end))"
        }
        return "Session — \(df.string(from: start))"
    }
}

// MARK: - JobBucketingError

enum JobBucketingError: LocalizedError {
    case apiError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let msg): return "Claude API error: \(msg)"
        case .parseError(let msg): return "Response parse error: \(msg)"
        }
    }
}
