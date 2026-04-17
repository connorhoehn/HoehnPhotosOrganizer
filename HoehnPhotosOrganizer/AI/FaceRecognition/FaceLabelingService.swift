import Foundation

// MARK: - FaceLabelingService

/// Labels selected face embeddings as a named person, then auto-matches
/// all remaining unlabeled faces against the updated reference pool.
///
/// Labeling tiers:
///   "user"      — You clicked chips and typed a name. Ground truth.
///   "embedding" — Distance ≤ 0.45 to a user-labeled reference. High confidence.
///   "claude"    — Borderline match confirmed/rejected by Claude Vision.
struct FaceLabelingService: Sendable {

    // MARK: - Thresholds

    /// Distance below which a face is auto-assigned (no review needed).
    static let autoAssignThreshold: Float = 0.45
    /// Distance above which a face is considered definitely different.
    /// Between autoAssign and this → needsReview = true.
    static let reviewThreshold: Float = 0.65

    // MARK: - Label

    /// Assign selected face embedding IDs to a named person.
    /// Creates the PersonIdentity if it doesn't exist yet.
    /// Returns the PersonIdentity that was used.
    @discardableResult
    static func label(
        faceIds: [String],
        as name: String,
        personRepo: PersonRepository,
        faceRepo: FaceEmbeddingRepository
    ) async throws -> PersonIdentity {
        let person = try await personRepo.findOrCreate(name: name)
        try await faceRepo.assignPerson(
            faceIds: faceIds,
            personId: person.id,
            labeledBy: "user"
        )
        print("[FaceLabelingService] Labeled \(faceIds.count) face(s) as '\(name)' (personId=\(person.id))")
        return person
    }

    // MARK: - Cluster Unlabeled

    struct FaceCluster: Sendable {
        let faceIds: [String]
    }

    /// Distance threshold for clustering — looser than autoAssign because the user
    /// will review and rename clusters anyway. Catches more same-person matches
    /// across different angles and lighting.
    static let clusterThreshold: Float = 0.55

    /// Groups all unlabeled faces into clusters using average-linkage clustering.
    /// A face joins a cluster only if its average distance to ALL existing members
    /// is below clusterThreshold. Prevents chaining different people together.
    /// Returns clusters sorted largest-first; singletons are included.
    /// Cluster a pre-fetched list of embeddings (for scoped contexts like job widgets).
    static func clusterUnlabeled(embeddings unlabeled: [FaceEmbedding]) -> [FaceCluster] {
        guard unlabeled.count >= 2 else {
            return unlabeled.map { FaceCluster(faceIds: [$0.id]) }
        }
        return _cluster(unlabeled)
    }

    static func clusterUnlabeled(faceRepo: FaceEmbeddingRepository) async throws -> [FaceCluster] {
        let unlabeled = try await faceRepo.fetchUnlabeled()
        guard unlabeled.count >= 2 else {
            return unlabeled.map { FaceCluster(faceIds: [$0.id]) }
        }

        return _cluster(unlabeled)
    }

    private static func _cluster(_ unlabeled: [FaceEmbedding]) -> [FaceCluster] {
        let n = unlabeled.count

        // Precompute pairwise distances
        var dist = Array(repeating: Array(repeating: Float.infinity, count: n), count: n)
        for i in 0..<n {
            guard let dataI = unlabeled[i].featureData else { continue }
            dist[i][i] = 0
            for j in (i+1)..<n {
                guard let dataJ = unlabeled[j].featureData else { continue }
                if let d = FaceEmbeddingService.distance(dataI, dataJ) {
                    dist[i][j] = d
                    dist[j][i] = d
                }
            }
        }

        // Average-linkage: greedily assign each face to best-fitting cluster
        var clusters: [[Int]] = []
        var assigned = Array(repeating: false, count: n)

        // Sort by most connections (faces similar to many others seed better clusters)
        let connectionCount = (0..<n).map { i in
            (0..<n).filter { j in j != i && dist[i][j] <= clusterThreshold }.count
        }
        let order = (0..<n).sorted { connectionCount[$0] > connectionCount[$1] }

        for i in order {
            guard !assigned[i] else { continue }

            var bestCluster = -1
            var bestAvgDist: Float = .infinity
            for (ci, cluster) in clusters.enumerated() {
                let avgDist = cluster.map { dist[i][$0] }.reduce(0, +) / Float(cluster.count)
                if avgDist <= clusterThreshold && avgDist < bestAvgDist {
                    bestAvgDist = avgDist
                    bestCluster = ci
                }
            }

            if bestCluster >= 0 { clusters[bestCluster].append(i) }
            else                 { clusters.append([i]) }
            assigned[i] = true
        }

        let result = clusters
            .map { FaceCluster(faceIds: $0.map { unlabeled[$0].id }) }
            .sorted { $0.faceIds.count > $1.faceIds.count }

        print("[FaceLabelingService] Clustered \(n) faces into \(result.count) groups (largest: \(result.first?.faceIds.count ?? 0))")
        return result
    }

    // MARK: - Auto-Match

    struct AutoMatchResult: Sendable {
        let matched: Int   // assigned via embedding similarity
        let flagged: Int   // marked needsReview for Claude
    }

    /// Compare all unlabeled faces against the user-labeled reference pool.
    /// - Matches within `autoAssignThreshold` → labeledBy = "embedding"
    /// - Matches within `reviewThreshold` → needsReview = true (tentative personId)
    static func runAutoMatch(faceRepo: FaceEmbeddingRepository) async throws -> AutoMatchResult {
        let labeled   = try await faceRepo.fetchLabeled()    // confirmed ground truth
        let unlabeled = try await faceRepo.fetchUnlabeled()  // no personId yet

        guard !labeled.isEmpty else {
            print("[FaceLabelingService] No labeled faces yet — nothing to match against.")
            return AutoMatchResult(matched: 0, flagged: 0)
        }

        var matched = 0
        var flagged = 0

        for candidate in unlabeled {
            guard let candidateData = candidate.featureData else { continue }

            // Find the closest labeled face
            var bestDist: Float = .infinity
            var bestPersonId: String? = nil

            for reference in labeled {
                guard let refData = reference.featureData,
                      let personId = reference.personId else { continue }
                if let dist = FaceEmbeddingService.distance(candidateData, refData) {
                    if dist < bestDist {
                        bestDist = dist
                        bestPersonId = personId
                    }
                }
            }

            guard let personId = bestPersonId else { continue }

            if bestDist <= autoAssignThreshold {
                try await faceRepo.assignPerson(faceIds: [candidate.id], personId: personId, labeledBy: "embedding")
                matched += 1
            } else if bestDist <= reviewThreshold {
                try await faceRepo.assignTentative(faceId: candidate.id, personId: personId)
                flagged += 1
            }
        }

        print("[FaceLabelingService] Auto-match complete: \(matched) assigned, \(flagged) flagged for review")
        return AutoMatchResult(matched: matched, flagged: flagged)
    }

    // MARK: - Duplicate Person Detection

    /// A pair of persons whose face embeddings are highly similar, suggesting they may be the same person.
    struct DuplicatePair: Sendable, Identifiable {
        let personA: PersonIdentity
        let personB: PersonIdentity
        let centroidDistance: Float

        var id: String { "\(personA.id)-\(personB.id)" }
    }

    /// Threshold for duplicate person detection — the maximum mean centroid distance
    /// between two person clusters to suggest a merge. Lower = stricter (fewer false positives).
    ///
    /// Must be less than `autoAssignThreshold` (0.45) since auto-assign already handles
    /// individual face matches at that distance. Duplicate detection compares cluster
    /// centroids, so a tighter threshold avoids surfacing pairs that look similar on
    /// average but aren't actually the same person.
    ///
    /// Distance buckets (Apple VNFeaturePrint):
    ///   < 0.20  — near-certain duplicate
    ///   0.20–0.30 — very likely duplicate
    ///   0.30–0.35 — probable duplicate, worth reviewing
    ///   0.35–0.45 — possible but risky, skip for now
    static let duplicateThreshold: Float = 0.35

    /// Compare embeddings across all named persons and return pairs whose mean centroid
    /// distance falls below `duplicateThreshold`. Only considers confirmed (non-review) faces.
    /// Excludes the special "Stranger" identity.
    static func findDuplicatePersons(
        personRepo: PersonRepository,
        faceRepo: FaceEmbeddingRepository
    ) async throws -> [DuplicatePair] {
        let allPersons = try await personRepo.fetchAll()
        // Exclude Stranger and auto-generated "Person N" clusters
        let namedPersons = allPersons.filter { $0.name != "Stranger" && !$0.name.hasPrefix("Person ") }
        guard namedPersons.count >= 2 else { return [] }

        // Build centroid (mean embedding) per person from confirmed faces
        struct PersonCentroid {
            let person: PersonIdentity
            let embeddings: [Data]
        }

        var centroids: [PersonCentroid] = []
        for person in namedPersons {
            let faces = try await faceRepo.fetchByPersonId(person.id, confirmedOnly: true)
            let embeddingData = faces.compactMap(\.featureData)
            guard !embeddingData.isEmpty else { continue }
            centroids.append(PersonCentroid(person: person, embeddings: embeddingData))
        }

        guard centroids.count >= 2 else { return [] }

        print("[DuplicateDetection] Comparing \(centroids.count) named person clusters (threshold: \(duplicateThreshold))")

        // Compare each pair: compute mean distance between all cross-pairs of embeddings
        var pairs: [DuplicatePair] = []
        var bucketUnder20 = 0
        var bucket20to30 = 0
        var bucket30to35 = 0  // was 30-40 at old threshold; now 30-35
        var bucket35to45 = 0
        var totalPairsCompared = 0

        for i in 0..<centroids.count {
            for j in (i + 1)..<centroids.count {
                let a = centroids[i]
                let b = centroids[j]

                var totalDist: Float = 0
                var count: Int = 0
                for embA in a.embeddings {
                    for embB in b.embeddings {
                        if let d = FaceEmbeddingService.distance(embA, embB) {
                            totalDist += d
                            count += 1
                        }
                    }
                }

                guard count > 0 else { continue }
                let meanDist = totalDist / Float(count)
                totalPairsCompared += 1

                // Log every candidate pair within the autoAssign range for diagnostics
                if meanDist < autoAssignThreshold {
                    print("[DuplicateDetection]   \(a.person.name) <-> \(b.person.name): distance \(String(format: "%.4f", meanDist)) (\(count) cross-comparisons)\(meanDist < duplicateThreshold ? " ** FLAGGED **" : "")")
                }

                // Bucket for summary
                switch meanDist {
                case ..<0.20:       bucketUnder20 += 1
                case 0.20..<0.30:   bucket20to30 += 1
                case 0.30..<0.35:   bucket30to35 += 1
                case 0.35..<0.45:   bucket35to45 += 1
                default: break
                }

                if meanDist < duplicateThreshold {
                    pairs.append(DuplicatePair(
                        personA: a.person,
                        personB: b.person,
                        centroidDistance: meanDist
                    ))
                }
            }
        }

        // Summary logging
        let nearCertain = bucketUnder20
        let veryLikely = bucket20to30
        let probable = bucket30to35
        let borderline = bucket35to45
        print("[DuplicateDetection] Summary: \(totalPairsCompared) pairs compared")
        print("[DuplicateDetection]   < 0.20 (near-certain): \(nearCertain)")
        print("[DuplicateDetection]   0.20–0.30 (very likely): \(veryLikely)")
        print("[DuplicateDetection]   0.30–0.35 (probable):    \(probable)")
        print("[DuplicateDetection]   0.35–0.45 (borderline):  \(borderline)")

        let sorted = pairs.sorted { $0.centroidDistance < $1.centroidDistance }
        print("[DuplicateDetection] Result: \(sorted.count) pair(s) flagged for review (threshold < \(duplicateThreshold))")
        return sorted
    }
}
