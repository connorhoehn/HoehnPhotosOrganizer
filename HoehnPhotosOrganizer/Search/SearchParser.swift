import Foundation

enum SearchParser {
    /// Deterministic parse of a plain-English query into a SearchIntentRaw.
    /// No network required. Used as fallback when Ollama is unavailable.
    static func parse(query: String, knownPeople: [String] = []) -> SearchIntentRaw {
        let lower = query.lowercased()
        var filter = SearchFilter()
        var foundPersonNames: [String] = []

        // Year
        if let match = query.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) {
            filter.yearFrom = Int(query[match])
            filter.yearTo = filter.yearFrom
        }

        // File type
        let extensions = ["dng", "cr3", "arw", "nef", "tiff", "tif", "jpg", "jpeg", "png", "heic", "psd"]
        for ext in extensions {
            if lower.contains(ext) {
                filter.fileType = ext
                break
            }
        }

        // Curation state
        if lower.contains("keeper") { filter.curationState = CurationState.keeper.rawValue }
        else if lower.contains("archive") { filter.curationState = CurationState.archive.rawValue }
        else if lower.contains("reject") { filter.curationState = CurationState.rejected.rawValue }

        // Time of day
        if lower.contains("golden hour") { filter.timeOfDay = TimeOfDay.goldenHour.rawValue }
        else if lower.contains("blue hour") { filter.timeOfDay = TimeOfDay.blueHour.rawValue }
        else if lower.contains("midday") || lower.contains("noon") { filter.timeOfDay = TimeOfDay.midday.rawValue }
        else if lower.contains("night") { filter.timeOfDay = TimeOfDay.night.rawValue }

        // Location: word after "from" or "in" that starts with capital letter, or known country names
        let knownLocations = ["england", "france", "germany", "japan", "italy", "spain",
                               "scotland", "wales", "ireland", "usa", "united states",
                               "uk", "canada", "australia", "pennsylvania", "paris",
                               "london", "whitby", "tokyo", "new york", "nyc"]
        for loc in knownLocations {
            if lower.contains(loc) {
                filter.location = loc.capitalized
                break
            }
        }
        if filter.location == nil {
            // Word after "from" or "in"
            let pattern = #"(?:from|in)\s+([A-Z][a-zA-Z]+)"#
            if let match = query.range(of: pattern, options: .regularExpression) {
                let full = String(query[match])
                let words = full.components(separatedBy: .whitespaces)
                if words.count >= 2 { filter.location = words.last }
            }
        }

        // Prefer map view if location was found
        let preferMapView = filter.location != nil

        // People: check remaining words against known people names (case-insensitive substring)
        if !knownPeople.isEmpty {
            let queryWords = query.components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { !$0.isEmpty }

            // Filter stop words and very short tokens that cause false positives
            let stopWords: Set<String> = [
                "the", "and", "for", "from", "with", "that", "this", "all", "any",
                "but", "not", "are", "was", "has", "had", "our", "his", "her",
                "photos", "pictures", "shots", "images", "show", "find", "get"
            ]

            for personName in knownPeople {
                let personLower = personName.lowercased()

                // For multi-word names, first try matching against sliding windows of the query
                let nameWordCount = personName.components(separatedBy: .whitespaces).count
                if nameWordCount > 1 {
                    var matched = false
                    for startIdx in 0...(max(0, queryWords.count - nameWordCount)) {
                        let endIdx = min(startIdx + nameWordCount, queryWords.count)
                        let window = queryWords[startIdx..<endIdx].joined(separator: " ").lowercased()
                        let score = PersonNameResolver.normalizedSimilarity(window, personLower)
                        if score >= 0.6 {
                            foundPersonNames.append(personName)
                            matched = true
                            break
                        }
                    }
                    if matched { continue }
                }

                // Single-word match: check each query word against this person name
                for word in queryWords {
                    let wordLower = word.lowercased()
                    // Skip words too short to reliably match or common stop words
                    guard wordLower.count >= 3, !stopWords.contains(wordLower) else { continue }
                    let score = PersonNameResolver.normalizedSimilarity(wordLower, personLower)
                    if score >= 0.6 {
                        foundPersonNames.append(personName)
                        break
                    }
                }
            }
        }

        return SearchIntentRaw(
            filter: filter,
            personNames: foundPersonNames.isEmpty ? nil : foundPersonNames,
            preferMapView: preferMapView
        )
    }
}
