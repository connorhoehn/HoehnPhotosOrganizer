import Foundation
import Observation

/// Persists pinned note event IDs to UserDefaults.
/// Observable so SwiftUI views re-render when pin state changes.
@Observable
final class PinnedNotesStore {

    static let shared = PinnedNotesStore()

    private let defaults = UserDefaults.standard
    private let key = "activity.pinnedNoteIds"

    /// Ordered set of pinned event IDs (most recently pinned first).
    private(set) var pinnedIds: [String] = []

    private init() {
        pinnedIds = defaults.stringArray(forKey: key) ?? []
    }

    func isPinned(eventId: String) -> Bool {
        pinnedIds.contains(eventId)
    }

    func toggle(eventId: String) {
        if isPinned(eventId: eventId) {
            unpin(eventId: eventId)
        } else {
            pin(eventId: eventId)
        }
    }

    func pin(eventId: String) {
        guard !pinnedIds.contains(eventId) else { return }
        pinnedIds.insert(eventId, at: 0)
        persist()
    }

    func unpin(eventId: String) {
        pinnedIds.removeAll { $0 == eventId }
        persist()
    }

    private func persist() {
        defaults.set(pinnedIds, forKey: key)
    }
}
