import SwiftUI

// MARK: - SiblingsNavigatorView

/// Horizontal thumbnail strip showing sibling frames extracted from the same roll.
/// Siblings are other child frames sharing the same parent in asset_lineage.
struct SiblingsNavigatorView: View {
    let photoAssetId: String
    var onSelect: (PhotoAsset) -> Void

    @State private var siblings: [PhotoAsset] = []
    @Environment(\.appDatabase) private var appDatabase: AppDatabase?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !siblings.isEmpty {
                Label("From same roll", systemImage: "film")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(siblings) { sibling in
                            SiblingThumb(photo: sibling, isActive: sibling.id == photoAssetId)
                                .onTapGesture { onSelect(sibling) }
                        }
                    }
                }
            }
        }
        .task(id: photoAssetId) {
            guard let db = appDatabase else { return }
            let repo = LineageRepository(db.dbPool)
            siblings = (try? await repo.fetchSiblings(for: photoAssetId)) ?? []
        }
    }
}

// MARK: - SiblingThumb

struct SiblingThumb: View {
    let photo: PhotoAsset
    let isActive: Bool

    private var proxyURL: URL {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        return ProxyGenerationActor.proxiesDirectory()
            .appendingPathComponent(baseName + ".jpg")
    }

    var body: some View {
        AsyncImage(url: proxyURL) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Image(systemName: "photo").foregroundStyle(.secondary)
        }
        .frame(width: 52, height: 52)
        .clipped()
        .cornerRadius(4)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(isActive ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }
}
