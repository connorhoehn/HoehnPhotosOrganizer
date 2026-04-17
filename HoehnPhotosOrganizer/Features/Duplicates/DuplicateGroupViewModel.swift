import Foundation
import SwiftUI
import Combine

@MainActor
final class DuplicateGroupViewModel: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    @Published var errorMessage: String?
    @Published var selectedForDeletion: Set<String> = []  // photo IDs marked for rejection

    private let db: AppDatabase

    init(db: AppDatabase) {
        self.db = db
    }

    func scan() async {
        isScanning = true
        errorMessage = nil
        let service = DuplicateDetectionService(db: db)
        do {
            groups = try await service.detectGroups()
        } catch {
            errorMessage = error.localizedDescription
        }
        isScanning = false
    }

    func toggleSelection(photoId: String) {
        if selectedForDeletion.contains(photoId) {
            selectedForDeletion.remove(photoId)
        } else {
            selectedForDeletion.insert(photoId)
        }
    }

    /// Marks selected photos as .rejected curation state (does NOT delete files).
    func rejectSelected(photoRepo: PhotoRepository) async {
        for photoId in selectedForDeletion {
            try? await photoRepo.updateCurationState(id: photoId, state: .rejected)
        }
        selectedForDeletion.removeAll()
        await scan()  // refresh groups
    }
}
