import SwiftUI
import HoehnPhotosCore

/// Renders a month's photos in the bento grid pattern:
///   Row A — 1 large landscape tile (2/3 width, 4:3 aspect) + 2 small squares (1/3 width, stacked)
///   Row B — 3 equal square tiles
///
/// Caps at 6 tiles. When a month has >6 photos, the 6th tile becomes an overflow
/// tile (PhotoTile with a "+N more" overlay badge).
/// Expanding the section appends remaining photos in a 3-column LazyVGrid below the bento block.
struct BentoSectionView: View {
    let photos: [PhotoAsset]        // All photos for this month (may be >6)
    let isExpanded: Bool
    let isSelecting: Bool
    let selectedPhotoIDs: Set<String>
    let onTapPhoto: (PhotoAsset) -> Void
    let onToggleExpand: () -> Void
    let onCuratePhoto: ((PhotoAsset, CurationState) -> Void)?
    /// Optional Namespace threaded down from the Library so each tile can
    /// publish a `.matchedTransitionSource` anchor for the hero zoom into
    /// `MobilePhotoDetailView` (Phase 4).
    var heroNamespace: Namespace.ID? = nil

    private let spacing: CGFloat = HPSpacing.xxs
    @State private var measuredWidth: CGFloat = 0

    /// Photos shown in the capped bento block (max 5 or 6 depending on overflow)
    private var cappedPhotos: ArraySlice<PhotoAsset> {
        photos.prefix(photos.count > 6 ? 5 : 6)
    }

    /// Whether to show overflow badge as 6th tile
    private var showOverflow: Bool {
        photos.count > 6
    }

    /// Photos shown in the expanded 3-col grid (index 5 onward when overflow)
    private var expandedPhotos: ArraySlice<PhotoAsset> {
        guard isExpanded && showOverflow else { return ArraySlice([]) }
        return photos.suffix(from: 5)
    }

    var body: some View {
        VStack(spacing: 0) {
            bentoBlock
            if isExpanded && !expandedPhotos.isEmpty {
                expandedGrid
            }
        }
    }

    // MARK: - Bento Block

    @ViewBuilder
    private var bentoBlock: some View {
        GeometryReader { geo in
            let totalWidth = geo.size.width
            let largeWidth = (totalWidth - spacing) * 2.0 / 3.0
            let smallWidth = totalWidth - largeWidth - spacing
            let largeHeight = largeWidth * 3.0 / 4.0   // 4:3 aspect
            let smallHeight = (largeHeight - spacing) / 2.0
            let equalWidth = (totalWidth - spacing * 2) / 3.0

            // Aspect ratios for each slot so PhotoTile can fill correctly.
            let largeAspect: CGFloat = largeWidth / max(largeHeight, 1)
            let smallAspect: CGFloat = smallWidth / max(smallHeight, 1)
            let equalAspect: CGFloat = 1.0

            VStack(spacing: spacing) {
                // Row A: 1 large (left) + 2 small stacked (right)
                if cappedPhotos.count >= 1 {
                    HStack(spacing: spacing) {
                        photoTile(cappedPhotos[cappedPhotos.startIndex], aspect: largeAspect)
                            .frame(width: largeWidth, height: largeHeight)

                        VStack(spacing: spacing) {
                            if cappedPhotos.count >= 2 {
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 1], aspect: smallAspect)
                                    .frame(width: smallWidth, height: smallHeight)
                            }
                            if cappedPhotos.count >= 3 {
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 2], aspect: smallAspect)
                                    .frame(width: smallWidth, height: smallHeight)
                            }
                        }
                    }
                }

                // Row B: 3 equal squares
                if cappedPhotos.count >= 4 {
                    HStack(spacing: spacing) {
                        photoTile(cappedPhotos[cappedPhotos.startIndex + 3], aspect: equalAspect)
                            .frame(width: equalWidth, height: equalWidth)
                        if cappedPhotos.count >= 5 {
                            if showOverflow {
                                // 5th tile is normal, 6th position is overflow badge
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 4], aspect: equalAspect)
                                    .frame(width: equalWidth, height: equalWidth)
                                overflowTile(photos[5], aspect: equalAspect)
                                    .frame(width: equalWidth, height: equalWidth)
                            } else {
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 4], aspect: equalAspect)
                                    .frame(width: equalWidth, height: equalWidth)
                                if cappedPhotos.count >= 6 {
                                    photoTile(cappedPhotos[cappedPhotos.startIndex + 5], aspect: equalAspect)
                                        .frame(width: equalWidth, height: equalWidth)
                                }
                            }
                        }
                    }
                }
            }
            .onAppear { measuredWidth = totalWidth }
            .onChange(of: geo.size.width) { _, newWidth in measuredWidth = newWidth }
        }
        .frame(height: bentoBlockHeight)
    }

    /// Pre-computed height based on the measured container width from GeometryReader.
    private var bentoBlockHeight: CGFloat {
        let totalWidth = measuredWidth > 0 ? measuredWidth : 390  // safe fallback
        let largeWidth = (totalWidth - spacing) * 2.0 / 3.0
        let largeHeight = largeWidth * 3.0 / 4.0
        let equalWidth = (totalWidth - spacing * 2) / 3.0
        var height = largeHeight  // Row A
        if cappedPhotos.count >= 4 {
            height += spacing + equalWidth  // Row B
        }
        return height
    }

    // MARK: - Photo Tile

    /// Curation tint for the PhotoTile stroke. Mirrors the pre-migration
    /// behavior where `.needsReview` did not paint a colored border.
    private func curationColor(for photo: PhotoAsset) -> Color? {
        guard let state = CurationState(rawValue: photo.curationState), state != .needsReview else {
            return nil
        }
        return state.tint
    }

    @ViewBuilder
    private func photoTile(_ photo: PhotoAsset, aspect: CGFloat) -> some View {
        let isSelected = selectedPhotoIDs.contains(photo.id)
        BentoPhotoTileLoader(
            photo: photo,
            aspect: aspect,
            isSelected: isSelected,
            curationColor: curationColor(for: photo),
            overlayBadge: nil,
            onTap: { onTapPhoto(photo) }
        )
        .photoContextMenu(photo: photo, onCurate: { state in
            onCuratePhoto?(photo, state)
        }, onViewDetails: {
            onTapPhoto(photo)
        })
        .heroSource(photoID: photo.id, namespace: heroNamespace)
    }

    @ViewBuilder
    private func overflowTile(_ photo: PhotoAsset, aspect: CGFloat) -> some View {
        // The +N tile still acts as an expander; we route the tap to
        // `onToggleExpand` rather than `onTapPhoto`.
        BentoPhotoTileLoader(
            photo: photo,
            aspect: aspect,
            isSelected: false,
            curationColor: nil,
            overlayBadge: "+\(photos.count - 5) more",
            onTap: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onToggleExpand()
            }
        )
        .accessibilityLabel("Show all photos. Plus \(photos.count - 5) more.")
        .accessibilityHint("Double tap to expand and show all photos")
    }

    // MARK: - Expanded Grid

    @ViewBuilder
    private var expandedGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(Array(expandedPhotos), id: \.id) { photo in
                let isSelected = selectedPhotoIDs.contains(photo.id)
                BentoPhotoTileLoader(
                    photo: photo,
                    aspect: 1,
                    isSelected: isSelected,
                    curationColor: curationColor(for: photo),
                    overlayBadge: nil,
                    onTap: { onTapPhoto(photo) }
                )
                .aspectRatio(1, contentMode: .fill)
                .photoContextMenu(photo: photo, onCurate: { state in
                    onCuratePhoto?(photo, state)
                }, onViewDetails: {
                    onTapPhoto(photo)
                })
                .heroSource(photoID: photo.id, namespace: heroNamespace)
            }
        }
    }
}

// MARK: - BentoPhotoTileLoader
//
// Thin adapter that loads the proxy UIImage for a photo and hands it to the
// design-system `PhotoTile` primitive. Uses the same proxy directory layout
// that `MobilePhotoCell` used pre-migration (`HoehnPhotos/proxies/<name>.jpg`)
// so the on-disk contract is unchanged.

private struct BentoPhotoTileLoader: View {
    let photo: PhotoAsset
    let aspect: CGFloat
    let isSelected: Bool
    let curationColor: Color?
    let overlayBadge: String?
    let onTap: () -> Void

    @State private var image: UIImage?

    private var proxyURL: URL {
        let baseName = (photo.canonicalName as NSString).deletingPathExtension
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("HoehnPhotos")
            .appendingPathComponent("proxies")
            .appendingPathComponent(baseName + ".jpg")
    }

    var body: some View {
        PhotoTile(
            image: image,
            aspect: aspect,
            isSelected: isSelected,
            curationColor: curationColor,
            overlayBadge: overlayBadge,
            onTap: onTap
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .task(id: photo.id) {
            let url = proxyURL
            let loaded = await Task.detached(priority: .utility) {
                guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
                return UIImage(data: data)
            }.value
            if let img = loaded {
                self.image = img
            }
        }
    }

    private var accessibilityLabel: String {
        let state = CurationState(rawValue: photo.curationState)?.title ?? "Uncategorized"
        let name = photo.canonicalName
        if isSelected {
            return "\(name), \(state), selected"
        }
        return "\(name), \(state)"
    }
}
