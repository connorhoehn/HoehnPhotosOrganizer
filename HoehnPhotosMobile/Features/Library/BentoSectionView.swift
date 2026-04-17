import SwiftUI
import HoehnPhotosCore

/// Renders a month's photos in the bento grid pattern:
///   Row A — 1 large landscape tile (2/3 width, 4:3 aspect) + 2 small squares (1/3 width, stacked)
///   Row B — 3 equal square tiles
///
/// Caps at 6 tiles. When a month has >6 photos, the 6th tile becomes an OverflowBadgeTile.
/// Expanding the section appends remaining photos in a 3-column LazyVGrid below the bento block.
struct BentoSectionView: View {
    let photos: [PhotoAsset]        // All photos for this month (may be >6)
    let isExpanded: Bool
    let isSelecting: Bool
    let selectedPhotoIDs: Set<String>
    let onTapPhoto: (PhotoAsset) -> Void
    let onToggleExpand: () -> Void
    let onCuratePhoto: ((PhotoAsset, CurationState) -> Void)?

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

            VStack(spacing: spacing) {
                // Row A: 1 large (left) + 2 small stacked (right)
                if cappedPhotos.count >= 1 {
                    HStack(spacing: spacing) {
                        photoTile(cappedPhotos[cappedPhotos.startIndex])
                            .frame(width: largeWidth, height: largeHeight)

                        VStack(spacing: spacing) {
                            if cappedPhotos.count >= 2 {
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 1])
                                    .frame(width: smallWidth, height: smallHeight)
                            }
                            if cappedPhotos.count >= 3 {
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 2])
                                    .frame(width: smallWidth, height: smallHeight)
                            }
                        }
                    }
                }

                // Row B: 3 equal squares
                if cappedPhotos.count >= 4 {
                    HStack(spacing: spacing) {
                        photoTile(cappedPhotos[cappedPhotos.startIndex + 3])
                            .frame(width: equalWidth, height: equalWidth)
                        if cappedPhotos.count >= 5 {
                            if showOverflow {
                                // 5th tile is normal, 6th position is overflow badge
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 4])
                                    .frame(width: equalWidth, height: equalWidth)
                                OverflowBadgeTile(
                                    photo: photos[5],
                                    remainingCount: photos.count - 5,
                                    onTap: onToggleExpand
                                )
                                .frame(width: equalWidth, height: equalWidth)
                            } else {
                                photoTile(cappedPhotos[cappedPhotos.startIndex + 4])
                                    .frame(width: equalWidth, height: equalWidth)
                                if cappedPhotos.count >= 6 {
                                    photoTile(cappedPhotos[cappedPhotos.startIndex + 5])
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

    @ViewBuilder
    private func photoTile(_ photo: PhotoAsset) -> some View {
        let isSelected = selectedPhotoIDs.contains(photo.id)
        MobilePhotoCell(photo: photo, isSelected: isSelected)
            .contentShape(Rectangle())
            .onTapGesture { onTapPhoto(photo) }
            .photoContextMenu(photo: photo, onCurate: { state in
                onCuratePhoto?(photo, state)
            }, onViewDetails: {
                onTapPhoto(photo)
            })
    }

    // MARK: - Expanded Grid

    @ViewBuilder
    private var expandedGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: 3)
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(Array(expandedPhotos), id: \.id) { photo in
                let isSelected = selectedPhotoIDs.contains(photo.id)
                MobilePhotoCell(photo: photo, isSelected: isSelected)
                    .aspectRatio(1, contentMode: .fill)
                    .onTapGesture { onTapPhoto(photo) }
                    .photoContextMenu(photo: photo, onCurate: { state in
                        onCuratePhoto?(photo, state)
                    }, onViewDetails: {
                        onTapPhoto(photo)
                    })
            }
        }
    }
}
