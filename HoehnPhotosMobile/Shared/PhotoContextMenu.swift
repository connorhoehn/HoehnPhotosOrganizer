import SwiftUI
import HoehnPhotosCore

/// Reusable context menu for any photo tile across all tabs.
/// Attach with: .photoContextMenu(photo:onCurate:onViewDetails:)
struct PhotoContextMenu: ViewModifier {
    let photo: PhotoAsset
    let onCurate: (CurationState) -> Void
    var onViewDetails: (() -> Void)? = nil

    func body(content: Content) -> some View {
        content.contextMenu {
            // Curation section
            Section("Curation") {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCurate(.keeper)
                } label: {
                    Label("Keep", systemImage: CurationState.keeper.systemIcon)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    onCurate(.archive)
                } label: {
                    Label("Archive", systemImage: CurationState.archive.systemIcon)
                }

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onCurate(.needsReview)
                } label: {
                    Label("Needs Review", systemImage: CurationState.needsReview.systemIcon)
                }

                Button(role: .destructive) {
                    UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                    onCurate(.rejected)
                } label: {
                    Label("Reject", systemImage: CurationState.rejected.systemIcon)
                }
            }

            // Actions section
            if let onViewDetails {
                Section {
                    Button {
                        HPHaptic.light()
                        onViewDetails()
                    } label: {
                        Label("View Details", systemImage: "info.circle")
                    }
                }
            }
        } preview: {
            MobilePhotoCell(photo: photo)
                .frame(width: 300, height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

extension View {
    func photoContextMenu(
        photo: PhotoAsset,
        onCurate: @escaping (CurationState) -> Void,
        onViewDetails: (() -> Void)? = nil
    ) -> some View {
        modifier(PhotoContextMenu(
            photo: photo,
            onCurate: onCurate,
            onViewDetails: onViewDetails
        ))
    }
}

// MARK: - Curation Helper

/// Shared helper that writes curation to local DB and enqueues a sync delta.
func applyCuration(
    photo: PhotoAsset,
    state: CurationState,
    db: AppDatabase,
    syncService: PeerSyncService
) async {
    try? await MobilePhotoRepository(db: db).updateCurationState(id: photo.id, state: state)
    await syncService.enqueueDelta(
        PhotoCurationDelta(photoId: photo.id, curationState: state.rawValue)
    )
    NotificationCenter.default.post(name: .cloudSyncCurationChanged, object: nil)
}
