import Foundation

// MARK: - SearchIntentRaw

/// Raw output from LLM or deterministic parser — person names are unresolved strings.
struct SearchIntentRaw: Codable {
    var filter: SearchFilter
    var personNames: [String]?
    var preferMapView: Bool?
}

// MARK: - ResolvedPerson

/// A person name from the query matched against a known PersonIdentity.
struct ResolvedPerson: Identifiable {
    let personId: String
    let personName: String      // canonical name from DB
    let queryName: String       // what the user typed
    let confidence: Double      // 1.0 = exact, lower = fuzzy
    var id: String { personId }
}

// MARK: - SearchIntent

/// Fully resolved search intent ready for execution.
struct SearchIntent {
    let filter: SearchFilter
    let resolvedPeople: [ResolvedPerson]
    let unresolvedNames: [String]
    let preferMapView: Bool
    /// True when intersection of filter + people sets was empty and results fell back to union.
    var usedUnionFallback: Bool = false
    /// People who were resolved but have zero tagged photos.
    var emptyPeople: [String] = []
}
