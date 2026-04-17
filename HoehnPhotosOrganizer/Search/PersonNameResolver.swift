import Foundation

enum PersonNameResolver {

    /// Resolve raw query names against known people using fuzzy matching.
    /// Returns one ResolvedPerson per query name that exceeds the threshold.
    static func resolve(
        queryNames: [String],
        knownPeople: [PersonIdentity],
        threshold: Double = 0.6
    ) -> (resolved: [ResolvedPerson], unresolved: [String]) {
        var resolved: [ResolvedPerson] = []
        var unresolved: [String] = []

        for queryName in queryNames {
            let queryLower = queryName.lowercased()
            var bestMatch: (person: PersonIdentity, score: Double)?

            for person in knownPeople {
                let personLower = person.name.lowercased()

                // Full name comparison
                let fullScore = normalizedSimilarity(queryLower, personLower)
                var score = fullScore

                // Also try matching against individual name parts (e.g. "Morgan" vs "Morgan Smith")
                let nameParts = personLower.components(separatedBy: .whitespaces)
                if nameParts.count > 1 {
                    for part in nameParts {
                        let partScore = normalizedSimilarity(queryLower, part)
                        score = max(score, partScore)
                    }
                }

                if score >= threshold {
                    if bestMatch == nil || score > bestMatch!.score {
                        bestMatch = (person, score)
                    }
                }
            }

            if let match = bestMatch {
                resolved.append(ResolvedPerson(
                    personId: match.person.id,
                    personName: match.person.name,
                    queryName: queryName,
                    confidence: match.score
                ))
            } else {
                unresolved.append(queryName)
            }
        }

        return (resolved, unresolved)
    }

    // MARK: - Levenshtein

    /// Normalized similarity: 1.0 = identical, 0.0 = completely different.
    static func normalizedSimilarity(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }
        let dist = levenshteinDistance(Array(a), Array(b))
        return 1.0 - Double(dist) / Double(maxLen)
    }

    private static func levenshteinDistance(_ a: [Character], _ b: [Character]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }

        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,       // deletion
                    curr[j - 1] + 1,   // insertion
                    prev[j - 1] + cost // substitution
                )
            }
            prev = curr
        }

        return prev[n]
    }
}
