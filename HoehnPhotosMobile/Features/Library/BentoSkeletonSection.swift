import SwiftUI
import HoehnPhotosCore

/// Skeleton placeholder for a bento section while library photos are loading.
/// Matches the bento layout pattern (Row A: 1 large + 2 small, Row B: 3 equal)
/// using ShimmerCell tiles and a rounded-rectangle header placeholder.
struct BentoSkeletonSection: View {
    private let spacing: CGFloat = 2

    var body: some View {
        VStack(spacing: 0) {
            // Skeleton header placeholder
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(uiColor: .systemFill))
                    .frame(width: 160, height: 20)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityHidden(true)

            // Skeleton bento rows
            GeometryReader { geo in
                let totalWidth = geo.size.width
                let largeWidth = (totalWidth - spacing) * 2.0 / 3.0
                let smallWidth = totalWidth - largeWidth - spacing
                let largeHeight = largeWidth * 3.0 / 4.0
                let smallHeight = (largeHeight - spacing) / 2.0
                let equalWidth = (totalWidth - spacing * 2) / 3.0

                VStack(spacing: spacing) {
                    // Row A: 1 large + 2 small stacked
                    HStack(spacing: spacing) {
                        ShimmerCell()
                            .frame(width: largeWidth, height: largeHeight)
                        VStack(spacing: spacing) {
                            ShimmerCell()
                                .frame(width: smallWidth, height: smallHeight)
                            ShimmerCell()
                                .frame(width: smallWidth, height: smallHeight)
                        }
                    }
                    // Row B: 3 equal squares
                    HStack(spacing: spacing) {
                        ShimmerCell().frame(width: equalWidth, height: equalWidth)
                        ShimmerCell().frame(width: equalWidth, height: equalWidth)
                        ShimmerCell().frame(width: equalWidth, height: equalWidth)
                    }
                }
            }
            .frame(height: skeletonHeight)
        }
        .accessibilityHidden(true)
    }

    private var skeletonHeight: CGFloat {
        let totalWidth = UIScreen.main.bounds.width
        let largeWidth = (totalWidth - spacing) * 2.0 / 3.0
        let largeHeight = largeWidth * 3.0 / 4.0
        let equalWidth = (totalWidth - spacing * 2) / 3.0
        return largeHeight + spacing + equalWidth
    }
}
