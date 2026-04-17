import Foundation

/// Lightweight summary of library contents for injecting into search prompts.
/// Keeps the token budget small (~150 tokens) while giving Claude enough context
/// to make useful suggestions.
struct LibraryContext {
    let totalPhotos: Int
    let curationBreakdown: [String: Int]  // e.g. ["keeper": 2104, "needs_review": 1892]
    let dateRange: (earliest: String, latest: String)?  // e.g. ("2019", "2025")
    let sceneDistribution: [(scene: String, count: Int)]
    let peopleWithCounts: [(name: String, count: Int)]
    let printJobCount: Int

    /// Format as a concise prompt snippet for the system prompt.
    func promptSnippet() -> String {
        var lines: [String] = []

        // Total + curation breakdown
        let curationParts = curationBreakdown
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
        if curationParts.isEmpty {
            lines.append("Library: \(totalPhotos) photos.")
        } else {
            lines.append("Library: \(totalPhotos) photos (\(curationParts.joined(separator: ", "))).")
        }

        // Date range
        if let range = dateRange {
            lines.append("Date range: \(range.earliest)–\(range.latest).")
        }

        // People
        if !peopleWithCounts.isEmpty {
            let peopleParts = peopleWithCounts
                .prefix(10)
                .map { "\($0.name) (\($0.count))" }
            lines.append("People: \(peopleParts.joined(separator: ", ")).")
        }

        // Scene types
        if !sceneDistribution.isEmpty {
            let sceneParts = sceneDistribution
                .prefix(6)
                .map { "\($0.scene) (\($0.count))" }
            lines.append("Scenes: \(sceneParts.joined(separator: ", ")).")
        }

        // Print jobs
        if printJobCount > 0 {
            lines.append("\(printJobCount) photos have print jobs.")
        }

        return lines.joined(separator: "\n")
    }
}
