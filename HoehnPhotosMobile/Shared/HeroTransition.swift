import SwiftUI

// MARK: - Hero transition helpers (Phase 4)
//
// iOS 18 introduced `.matchedTransitionSource(id:in:)` + `.navigationTransition(.zoom(...))`
// for lightweight hero animations across sheets and navigation pushes.
// These helpers thread the (sometimes-nil) namespace through the grid
// views so callers can opt-in without plumbing conditional modifiers.

extension View {
    /// Marks this view as the source of a Phase 4 hero zoom for a photo.
    /// No-op when `namespace` is nil (callers that haven't opted in).
    @ViewBuilder
    func heroSource(photoID: String, namespace: Namespace.ID?) -> some View {
        if let namespace {
            self.matchedTransitionSource(
                id: "\(HPNamespaceID.photoHero)-\(photoID)",
                in: namespace
            )
        } else {
            self
        }
    }
}
