import Foundation

// MARK: - ProposedJob

struct ProposedJob: Identifiable, Codable {
    var id: String = UUID().uuidString
    var title: String           // Claude-generated name e.g. "Scotland Trip — Day 1"
    var rationale: String       // Brief explanation: "23 photos from same GPS cluster, March 15"
    var photoCount: Int
    var representativePhotoIds: [String]  // first 3-5 photo IDs for thumbnail preview
    var dateRange: DateInterval?          // earliest to latest capture date
    var jobKind: JobKind

    enum JobKind: String, Codable, CaseIterable {
        case timeCluster     = "timeCluster"     // photos from same session/day
        case locationCluster = "locationCluster" // photos from same GPS area
        case filmScan        = "filmScan"        // no camera EXIF / film scan type
        case catchAll        = "catchAll"        // mixed or unclassifiable
    }

    // MARK: - Codable (manual, because DateInterval is not Codable by default)

    enum CodingKeys: String, CodingKey {
        case id, title, rationale, photoCount, representativePhotoIds, jobKind
        case dateRangeStart = "date_range_start"
        case dateRangeEnd   = "date_range_end"
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        rationale: String,
        photoCount: Int,
        representativePhotoIds: [String],
        dateRange: DateInterval?,
        jobKind: JobKind
    ) {
        self.id = id
        self.title = title
        self.rationale = rationale
        self.photoCount = photoCount
        self.representativePhotoIds = representativePhotoIds
        self.dateRange = dateRange
        self.jobKind = jobKind
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                     = try c.decodeIfPresent(String.self,  forKey: .id) ?? UUID().uuidString
        title                  = try c.decode(String.self,           forKey: .title)
        rationale              = try c.decode(String.self,           forKey: .rationale)
        photoCount             = try c.decode(Int.self,              forKey: .photoCount)
        representativePhotoIds = try c.decode([String].self,         forKey: .representativePhotoIds)
        jobKind                = try c.decode(JobKind.self,          forKey: .jobKind)
        if let start = try c.decodeIfPresent(Date.self, forKey: .dateRangeStart),
           let end   = try c.decodeIfPresent(Date.self, forKey: .dateRangeEnd) {
            dateRange = DateInterval(start: start, end: end)
        } else {
            dateRange = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,                     forKey: .id)
        try c.encode(title,                  forKey: .title)
        try c.encode(rationale,              forKey: .rationale)
        try c.encode(photoCount,             forKey: .photoCount)
        try c.encode(representativePhotoIds, forKey: .representativePhotoIds)
        try c.encode(jobKind,                forKey: .jobKind)
        try c.encodeIfPresent(dateRange?.start, forKey: .dateRangeStart)
        try c.encodeIfPresent(dateRange?.end,   forKey: .dateRangeEnd)
    }
}

// MARK: - JobProposalService

/// Actor that analyses `DrivePhotoRecord` arrays and proposes named triage job buckets.
/// Calls Claude via the Anthropic Messages API; falls back to heuristic bucketing on error.
actor JobProposalService {

    private let authManager = AnthropicAuthManager()

    // MARK: - Public

    /// Analyse `photos` and return 1-8 proposed job buckets.
    func proposeJobs(for photos: [DrivePhotoRecord]) async throws -> [ProposedJob] {
        guard !photos.isEmpty else { return [] }

        let summary = buildSummary(for: photos)

        // Try Claude first; fall through to heuristics on failure
        if let apiKey = try? await authManager.getAPIKey(),
           let proposals = try? await callClaude(summary: summary, photos: photos, apiKey: apiKey),
           !proposals.isEmpty {
            return proposals
        }

        return heuristicProposals(for: photos)
    }

    // MARK: - Summary builder

    private struct PhotoSummary {
        var totalCount: Int
        var rawCount: Int
        var jpegCount: Int
        var noExifCount: Int
        var earliestDate: Date?
        var latestDate: Date?
        var gpsClusterCount: Int
        var timeGaps: [TimeGap]       // gaps > 4 hours between consecutive photos
        var photosByDate: [[DrivePhotoRecord]] // sorted clusters
    }

    private struct TimeGap {
        var afterDate: Date
        var beforeDate: Date
        var durationHours: Double
    }

    private func buildSummary(for photos: [DrivePhotoRecord]) -> PhotoSummary {
        let iso = ISO8601DateFormatter()

        // Sort by capture date, unknown dates go last
        let dated   = photos.compactMap { r -> (record: DrivePhotoRecord, date: Date)? in
            guard let ds = r.captureDate, let d = iso.date(from: ds) else { return nil }
            return (r, d)
        }.sorted { $0.date < $1.date }

        let undated = photos.filter { $0.captureDate == nil }

        let rawCount  = photos.filter { $0.isRawFile }.count
        let jpegCount = photos.filter { r in
            let ext = (r.filename as NSString).pathExtension.lowercased()
            return ["jpg","jpeg","heic","heif","png"].contains(ext)
        }.count
        let noExifCount = undated.count

        // GPS clusters: bucket by 0.1-degree lat/lon grid
        var gpsBuckets = Set<String>()
        for r in photos {
            if let lat = r.gpsLatitude, let lon = r.gpsLongitude {
                let key = "\(Int(lat * 10))_\(Int(lon * 10))"
                gpsBuckets.insert(key)
            }
        }

        // Time gaps > 4 hours
        var gaps: [TimeGap] = []
        let gapThreshold: TimeInterval = 4 * 3600
        for i in 1..<dated.count {
            let gap = dated[i].date.timeIntervalSince(dated[i-1].date)
            if gap > gapThreshold {
                gaps.append(TimeGap(
                    afterDate: dated[i-1].date,
                    beforeDate: dated[i].date,
                    durationHours: gap / 3600
                ))
            }
        }

        // Time clusters (split on each gap)
        var clusters: [[DrivePhotoRecord]] = []
        if !dated.isEmpty {
            var current: [DrivePhotoRecord] = [dated[0].record]
            for i in 1..<dated.count {
                let gap = dated[i].date.timeIntervalSince(dated[i-1].date)
                if gap > gapThreshold {
                    clusters.append(current)
                    current = []
                }
                current.append(dated[i].record)
            }
            clusters.append(current)
        }
        if !undated.isEmpty { clusters.append(undated) }

        return PhotoSummary(
            totalCount: photos.count,
            rawCount: rawCount,
            jpegCount: jpegCount,
            noExifCount: noExifCount,
            earliestDate: dated.first?.date,
            latestDate: dated.last?.date,
            gpsClusterCount: gpsBuckets.count,
            timeGaps: gaps,
            photosByDate: clusters
        )
    }

    // MARK: - Claude API call

    private func callClaude(
        summary: PhotoSummary,
        photos: [DrivePhotoRecord],
        apiKey: String
    ) async throws -> [ProposedJob] {

        let promptText = buildPrompt(summary: summary, photos: photos)

        let tool: [String: Any] = [
            "name": "propose_jobs",
            "description": "Propose named triage job buckets for a set of scanned drive photos.",
            "input_schema": [
                "type": "object",
                "properties": [
                    "jobs": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "required": ["title", "rationale", "photoCount", "representativePhotoIds", "jobKind"],
                            "properties": [
                                "title":                  ["type": "string"],
                                "rationale":              ["type": "string"],
                                "photoCount":             ["type": "integer"],
                                "representativePhotoIds": ["type": "array", "items": ["type": "string"]],
                                "jobKind":                ["type": "string",
                                                          "enum": ["timeCluster","locationCluster","filmScan","catchAll"]],
                                "date_range_start":       ["type": "string", "format": "date-time"],
                                "date_range_end":         ["type": "string", "format": "date-time"]
                            ]
                        ]
                    ]
                ],
                "required": ["jobs"]
            ]
        ]

        let requestBody: [String: Any] = [
            "model": "claude-sonnet-4-6",
            "max_tokens": 1024,
            "tools": [tool],
            "tool_choice": ["type": "tool", "name": "propose_jobs"],
            "messages": [
                ["role": "user", "content": promptText]
            ]
        ]

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.setValue("application/json",      forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey,                  forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01",            forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw JobProposalError.apiError("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        return try parseClaudeResponse(data: data, photos: [])
    }

    private func buildPrompt(summary: PhotoSummary, photos: [DrivePhotoRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []

        lines.append("You are helping organize a batch of scanned drive photos into named triage jobs.")
        lines.append("")
        lines.append("SCAN SUMMARY:")
        lines.append("- Total photos: \(summary.totalCount)")
        lines.append("- RAW files: \(summary.rawCount)")
        lines.append("- JPEG/HEIC: \(summary.jpegCount)")
        lines.append("- No EXIF date: \(summary.noExifCount)")
        lines.append("- GPS cluster count: \(summary.gpsClusterCount) (0.1-degree grid)")

        if let start = summary.earliestDate, let end = summary.latestDate {
            lines.append("- Date range: \(iso.string(from: start)) to \(iso.string(from: end))")
        }

        if !summary.timeGaps.isEmpty {
            lines.append("- Time gaps > 4 hours: \(summary.timeGaps.count)")
            for gap in summary.timeGaps.prefix(5) {
                lines.append("  • \(String(format: "%.1f", gap.durationHours))h gap at \(iso.string(from: gap.beforeDate))")
            }
        }

        lines.append("")
        lines.append("TIME CLUSTERS (photos within 4h of each other):")
        for (i, cluster) in summary.photosByDate.enumerated() {
            let dates = cluster.compactMap { r -> Date? in
                guard let ds = r.captureDate else { return nil }
                return iso.date(from: ds)
            }
            let start = dates.min().map { iso.string(from: $0) } ?? "unknown"
            let end   = dates.max().map { iso.string(from: $0) } ?? "unknown"
            let hasGPS = cluster.filter { $0.gpsLatitude != nil }.count
            let repIds = cluster.prefix(5).map(\.id)
            lines.append("Cluster \(i+1): \(cluster.count) photos, \(start) – \(end), GPS on \(hasGPS), IDs: \(repIds.joined(separator: ","))")
        }

        lines.append("")
        lines.append("Propose 1-8 job buckets. Each must have a descriptive title (place + date if possible), rationale, photoCount, representativePhotoIds (up to 5 from that cluster), and jobKind.")
        lines.append("Use jobKind=filmScan for clusters with no EXIF. Merge very small clusters (< 5 photos) into adjacent ones or a catchAll.")

        return lines.joined(separator: "\n")
    }

    private func parseClaudeResponse(data: Data, photos: [DrivePhotoRecord]) throws -> [ProposedJob] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]],
              let toolUse = content.first(where: { $0["type"] as? String == "tool_use" }),
              let input = toolUse["input"] as? [String: Any],
              let jobsArray = input["jobs"] as? [[String: Any]]
        else {
            throw JobProposalError.parseError("Unexpected Claude response shape")
        }

        let iso = ISO8601DateFormatter()
        var results: [ProposedJob] = []

        for job in jobsArray {
            guard
                let title   = job["title"]      as? String,
                let reason  = job["rationale"]   as? String,
                let count   = job["photoCount"]  as? Int,
                let kindStr = job["jobKind"]     as? String,
                let kind    = ProposedJob.JobKind(rawValue: kindStr),
                let repIds  = job["representativePhotoIds"] as? [String]
            else { continue }

            var dateInterval: DateInterval? = nil
            if let startStr = job["date_range_start"] as? String,
               let endStr   = job["date_range_end"]   as? String,
               let start    = iso.date(from: startStr),
               let end      = iso.date(from: endStr) {
                dateInterval = DateInterval(start: start, end: max(start, end))
            }

            results.append(ProposedJob(
                title: title,
                rationale: reason,
                photoCount: count,
                representativePhotoIds: repIds,
                dateRange: dateInterval,
                jobKind: kind
            ))
        }

        return results
    }

    // MARK: - Heuristic fallback

    private func heuristicProposals(for photos: [DrivePhotoRecord]) -> [ProposedJob] {
        let iso = ISO8601DateFormatter()

        // No EXIF at all → single film scan job
        let dated = photos.filter { $0.captureDate != nil }
        if dated.isEmpty {
            return [ProposedJob(
                title: "Film Scan Roll",
                rationale: "\(photos.count) photos with no EXIF date — likely film scans",
                photoCount: photos.count,
                representativePhotoIds: photos.prefix(5).map(\.id),
                dateRange: nil,
                jobKind: .filmScan
            )]
        }

        // Sort by captureDate and split on 4-hour gaps
        let sorted = dated.sorted {
            guard let a = $0.captureDate, let b = $1.captureDate else { return false }
            return a < b
        }

        let gapThreshold: TimeInterval = 4 * 3600
        var clusters: [[DrivePhotoRecord]] = []
        var current: [DrivePhotoRecord] = [sorted[0]]

        for i in 1..<sorted.count {
            let prev = iso.date(from: sorted[i-1].captureDate ?? "") ?? .distantPast
            let next = iso.date(from: sorted[i].captureDate   ?? "") ?? .distantPast
            if next.timeIntervalSince(prev) > gapThreshold {
                clusters.append(current)
                current = []
            }
            current.append(sorted[i])
        }
        clusters.append(current)

        // Append undated as film scan if any
        let undated = photos.filter { $0.captureDate == nil }
        if !undated.isEmpty {
            clusters.append(undated)
        }

        let df = DateFormatter()
        df.dateStyle = .medium; df.timeStyle = .none

        return clusters.enumerated().map { idx, cluster in
            let isUndated = cluster.allSatisfy { $0.captureDate == nil }
            if isUndated {
                return ProposedJob(
                    title: "Film Scan Roll",
                    rationale: "\(cluster.count) photos with no EXIF date",
                    photoCount: cluster.count,
                    representativePhotoIds: cluster.prefix(5).map(\.id),
                    dateRange: nil,
                    jobKind: .filmScan
                )
            }
            let dates = cluster.compactMap { r -> Date? in
                guard let ds = r.captureDate else { return nil }
                return iso.date(from: ds)
            }
            let start = dates.min()
            let end   = dates.max()
            let label = start.map { df.string(from: $0) } ?? "Unknown Date"
            let interval = start.flatMap { s in end.map { e in DateInterval(start: s, end: max(s, e)) } }

            return ProposedJob(
                title: "Session \(idx + 1) — \(label)",
                rationale: "\(cluster.count) photos from \(label)",
                photoCount: cluster.count,
                representativePhotoIds: cluster.prefix(5).map(\.id),
                dateRange: interval,
                jobKind: .timeCluster
            )
        }
    }
}

// MARK: - JobProposalError

enum JobProposalError: LocalizedError {
    case apiError(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .apiError(let msg):   return "Claude API error: \(msg)"
        case .parseError(let msg): return "Response parse error: \(msg)"
        }
    }
}
