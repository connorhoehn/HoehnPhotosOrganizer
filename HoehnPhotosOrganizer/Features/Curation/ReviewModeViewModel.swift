import Foundation
import SwiftUI
import Combine
import GRDB

/// ReviewModeViewModel manages the state and behavior of the keyboard-driven review mode.
/// Controls navigation (advance/retreat), curation state updates, and index bounds checking.
@MainActor
final class ReviewModeViewModel: ObservableObject {
    @Published var photos: [PhotoAsset] = []
    @Published var currentIndex: Int = 0
    @Published var isActive = false

    private let photoRepo: PhotoRepository

    init(photoRepo: PhotoRepository) {
        self.photoRepo = photoRepo
    }

    /// Returns the photo at currentIndex, or nil if out of bounds.
    var currentPhoto: PhotoAsset? {
        photos.indices.contains(currentIndex) ? photos[currentIndex] : nil
    }

    /// Load a new batch of photos and reset the index to 0.
    func loadPhotos(_ newPhotos: [PhotoAsset]) {
        photos = newPhotos
        currentIndex = 0
    }

    /// Apply a curation state to the current photo and advance to the next.
    /// Errors are silently logged (printed) at this stage; no UI error state needed yet.
    func applyCuration(_ state: CurationState) {
        guard let currentPhoto else { return }

        Task {
            do {
                try await photoRepo.updateCurationState(id: currentPhoto.id, state: state)
                await MainActor.run {
                    self.advance()
                }
            } catch {
                print("Error updating curation state: \(error)")
            }
        }
    }

    /// Advance to the next photo. Stays at end if already at the last photo.
    func advance() {
        if currentIndex < photos.count - 1 {
            withAnimation(.easeInOut(duration: 0.15)) {
                currentIndex += 1
            }
        }
    }

    /// Retreat to the previous photo. Stays at start if already at the first photo.
    func retreat() {
        if currentIndex > 0 {
            withAnimation(.easeInOut(duration: 0.15)) {
                currentIndex -= 1
            }
        }
    }
}
