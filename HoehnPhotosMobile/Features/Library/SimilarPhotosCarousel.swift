import SwiftUI
import HoehnPhotosCore

// MARK: - SimilarPhotosCarousel
//
// Horizontal strip of ~12 small tiles below the hero image. Tapping a tile
// swaps the detail view to that photo by emitting `onSelectPhoto`.
//
// Renders inside `MobilePhotoDetailView`'s metadata sheet, below the EXIF
// grid. Driven by `SimilarPhotoFinder.findSimilar(to:)`.

struct SimilarPhotosCarousel: View {
    let photo: PhotoAsset
    let onSelectPhoto: (PhotoAsset) -> Void

    @Environment(\.appDatabase) private var appDatabase

    @State private var results: [PhotoAsset] = []
    @State private var isLoading = true

    private let tileSize: CGFloat = 64

    var body: some View {
        VStack(alignment: .leading, spacing: HPSpacing.sm) {
            HStack {
                Text("Similar")
                    .font(HPFont.sectionHeader)
                Spacer()
                if !results.isEmpty {
                    Text("\(results.count)")
                        .font(HPFont.metaValue)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, HPSpacing.base)

            if isLoading {
                loadingRow
            } else if results.isEmpty {
                Text("No similar photos yet.")
                    .font(HPFont.metaValue)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, HPSpacing.base)
                    .padding(.bottom, HPSpacing.xs)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HPSpacing.sm) {
                        ForEach(results) { sibling in
                            SimilarTile(photo: sibling, size: tileSize) {
                                HPHaptic.light()
                                onSelectPhoto(sibling)
                            }
                        }
                    }
                    .padding(.horizontal, HPSpacing.base)
                }
            }
        }
        .task(id: photo.id) { await load() }
    }

    private var loadingRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HPSpacing.sm) {
                ForEach(0..<6, id: \.self) { _ in
                    ShimmerPlaceholder(cornerRadius: HPRadius.medium)
                        .frame(width: tileSize, height: tileSize)
                }
            }
            .padding(.horizontal, HPSpacing.base)
        }
        .allowsHitTesting(false)
    }

    private func load() async {
        guard let db = appDatabase else {
            isLoading = false
            return
        }
        isLoading = true
        let found = (try? await SimilarPhotoFinder.findSimilar(to: photo, in: db, limit: 12)) ?? []
        await MainActor.run {
            self.results = found
            self.isLoading = false
        }
    }
}

// MARK: - SimilarTile

private struct SimilarTile: View {
    let photo: PhotoAsset
    let size: CGFloat
    let onTap: () -> Void

    @State private var image: UIImage?

    var body: some View {
        Button(action: onTap) {
            ZStack {
                HPColor.cardBackground
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ShimmerPlaceholder(cornerRadius: HPRadius.medium)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: HPRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: HPRadius.medium, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Similar photo \(photo.canonicalName)")
        .accessibilityAddTraits(.isButton)
        .task(id: photo.id) { await loadImage() }
    }

    private func loadImage() async {
        let name = photo.canonicalName
        let loaded = await Task.detached(priority: .utility) { () -> UIImage? in
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            let url = appSupport
                .appendingPathComponent("HoehnPhotos")
                .appendingPathComponent("proxies")
                .appendingPathComponent((name as NSString).deletingPathExtension + ".jpg")
            guard let data = try? Data(contentsOf: url) else { return nil }
            return UIImage(data: data)
        }.value
        await MainActor.run { self.image = loaded }
    }
}
