import Testing
@testable import HoehnPhotosOrganizer

struct PersonNameResolverTests {

    // MARK: - normalizedSimilarity

    @Test
    func testNormalizedSimilarityIdenticalStringsReturnOne() {
        let score = PersonNameResolver.normalizedSimilarity("alice", "alice")
        #expect(abs(score - 1.0) < 1e-9, "Identical strings must have similarity 1.0")
    }

    @Test
    func testNormalizedSimilarityEmptyStringsReturnOne() {
        // Both empty → maxLen == 0, returns 1.0 by convention
        let score = PersonNameResolver.normalizedSimilarity("", "")
        #expect(abs(score - 1.0) < 1e-9, "Two empty strings must have similarity 1.0")
    }

    @Test
    func testNormalizedSimilarityOneTypoStillHighScore() {
        // "alice" vs "alyce" — 1 substitution in 5 chars → similarity ≥ 0.8
        let score = PersonNameResolver.normalizedSimilarity("alice", "alyce")
        #expect(score >= 0.8, "Single-character typo must still produce similarity ≥ 0.8")
    }

    // MARK: - resolve: exact match

    @Test
    func testResolveExactMatchExceedsThreshold() {
        let now = ISO8601DateFormatter().string(from: .now)
        let people = [
            PersonIdentity(id: "p1", name: "Alice Smith", coverFaceEmbeddingId: nil, createdAt: now)
        ]
        let (resolved, unresolved) = PersonNameResolver.resolve(
            queryNames: ["Alice Smith"],
            knownPeople: people
        )
        #expect(resolved.count == 1, "Exact match must be resolved")
        #expect(resolved.first?.personId == "p1")
        #expect(unresolved.isEmpty)
    }

    // MARK: - resolve: partial first-name match

    @Test
    func testResolvePartialFirstNameMatchesFullName() {
        let now = ISO8601DateFormatter().string(from: .now)
        let people = [
            PersonIdentity(id: "p2", name: "Morgan Smith", coverFaceEmbeddingId: nil, createdAt: now)
        ]
        let (resolved, _) = PersonNameResolver.resolve(
            queryNames: ["Morgan"],
            knownPeople: people
        )
        #expect(resolved.count == 1, "First name alone must match against 'Morgan Smith' via part-score logic")
        #expect(resolved.first?.personId == "p2")
    }

    // MARK: - resolve: below threshold → unresolved

    @Test
    func testResolveBelowThresholdGoesToUnresolved() {
        let now = ISO8601DateFormatter().string(from: .now)
        let people = [
            PersonIdentity(id: "p3", name: "Alice", coverFaceEmbeddingId: nil, createdAt: now)
        ]
        let (resolved, unresolved) = PersonNameResolver.resolve(
            queryNames: ["Zzzzzzzz"],
            knownPeople: people,
            threshold: 0.6
        )
        #expect(resolved.isEmpty, "Completely unrelated name must not be resolved")
        #expect(unresolved == ["Zzzzzzzz"], "Unmatched name must appear in unresolved list")
    }
}
