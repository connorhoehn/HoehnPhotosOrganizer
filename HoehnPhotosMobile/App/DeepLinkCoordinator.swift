import Foundation
import SwiftUI
import Combine

// MARK: - DeepLinkCoordinator
//
// Lightweight app-level coordinator used by in-view surfaces (like the face
// chip strip inside a photo-detail sheet) to request that the Search tab
// switch scope + run a query.
//
// Flow:
//   1. A descendant view (e.g. `PhotoFacesStrip` via its `onSelectPerson`
//      closure) calls `requestPeopleFilter(name:)` with a person name.
//   2. `MobileTabView` observes `pendingPeopleQuery`; on change it dismisses
//      any presented sheet, flips `@AppStorage("searchScope")` to `people`,
//      selects the search tab, and forwards the query string to the
//      `MobileSearchView` via `pendingSearchQuery`.
//   3. `MobileSearchView` observes `pendingSearchQuery` and writes it into
//      its local `@State` `query`, which triggers the existing debounced
//      search pipeline.
//   4. After the query has been handed off, callers clear the pending
//      field by calling `clearPending()` so subsequent requests for the
//      same name still fire.
//
// Kept intentionally minimal — no business logic, just a `@Published`
// string envelope. Business logic lives in the consuming views.
@MainActor
public final class DeepLinkCoordinator: ObservableObject {
    /// Latest request for a People-scope filter by person name. Non-nil
    /// while a request is pending consumption; consumers set back to nil
    /// once handled.
    @Published public var pendingPeopleQuery: String?

    /// Mirror for the search view to consume. `MobileTabView` forwards
    /// `pendingPeopleQuery` here once it has switched scope + tab, to
    /// avoid racing the scope switch with the query assignment.
    @Published public var pendingSearchQuery: String?

    public init() {}

    /// Request a People-scope filter for the given name. Called from
    /// inside photo-detail when a named face chip is tapped.
    public func requestPeopleFilter(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pendingPeopleQuery = trimmed
    }

    /// Consumers (the tab view, the search view) call this after they
    /// have applied the pending value, so repeated requests for the same
    /// name re-trigger the pipeline.
    public func clearPeopleQuery() {
        pendingPeopleQuery = nil
    }

    public func clearSearchQuery() {
        pendingSearchQuery = nil
    }
}
