import SwiftUI

// MARK: - Shimmer Animation Modifier

struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: phase - 0.3),
                        .init(color: Color(uiColor: .systemBackground).opacity(0.4), location: phase),
                        .init(color: .clear, location: phase + 0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .blendMode(.overlay)
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

// MARK: - Skeleton Primitives

/// Rectangular skeleton placeholder (photo tiles, text lines, cards)
struct SkeletonRect: View {
    var width: CGFloat? = nil
    var height: CGFloat = 20
    var cornerRadius: CGFloat = 4

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Color(uiColor: .systemFill))
            .frame(width: width, height: height)
            .shimmer()
    }
}

/// Circular skeleton placeholder (avatars, completeness rings)
struct SkeletonCircle: View {
    var size: CGFloat = 40

    var body: some View {
        Circle()
            .fill(Color(uiColor: .systemFill))
            .frame(width: size, height: size)
            .shimmer()
    }
}

/// A row skeleton: circle + two text lines (good for list rows)
struct SkeletonRow: View {
    var body: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: 28)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonRect(width: 140, height: 14)
                SkeletonRect(width: 80, height: 10)
            }
            Spacer()
            SkeletonRect(width: 60, height: 20, cornerRadius: 10)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - ShimmerCell (used by BentoSkeletonSection + SkeletonPhotoGrid)

struct ShimmerCell: View {
    @State private var shimmerPhase: CGFloat = -1

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: Color(uiColor: .systemFill), location: shimmerPhase - 0.3),
                        .init(color: Color(uiColor: .secondarySystemFill), location: shimmerPhase),
                        .init(color: Color(uiColor: .systemFill), location: shimmerPhase + 0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .onAppear {
                withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                    shimmerPhase = 2
                }
            }
    }
}

// MARK: - Composite Skeletons

/// Grid of square shimmer cells (for photo grids)
struct SkeletonPhotoGrid: View {
    var rows: Int = 4
    var columns: Int = 3
    var spacing: CGFloat = 2

    var body: some View {
        let gridColumns = Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns)
        LazyVGrid(columns: gridColumns, spacing: spacing) {
            ForEach(0..<(rows * columns), id: \.self) { _ in
                ShimmerCell()
                    .aspectRatio(1, contentMode: .fill)
            }
        }
        .accessibilityHidden(true)
    }
}

/// People grid skeleton: 2-column grid of person card placeholders
struct SkeletonPeopleGrid: View {
    var count: Int = 6
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(0..<count, id: \.self) { _ in
                    VStack(spacing: 8) {
                        SkeletonCircle(size: 96)
                        SkeletonRect(width: 80, height: 14)
                        SkeletonRect(width: 50, height: 10)
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground))
                    )
                }
            }
            .padding(12)
        }
        .accessibilityHidden(true)
    }
}

/// Activity list skeleton: icon circle + text lines grouped in sections
struct SkeletonActivityList: View {
    var sectionCount: Int = 2
    var rowsPerSection: Int = 3

    private var rowPlaceholder: some View {
        HStack(spacing: 12) {
            SkeletonCircle(size: 28)
            VStack(alignment: .leading, spacing: 4) {
                SkeletonRect(width: 180, height: 14)
                SkeletonRect(width: 120, height: 10)
                SkeletonRect(width: 80, height: 8)
            }
        }
    }

    @ViewBuilder
    private var sectionPlaceholder: some View {
        Section {
            ForEach(0..<rowsPerSection, id: \.self) { _ in
                rowPlaceholder
            }
        } header: {
            SkeletonRect(width: 80, height: 12)
        }
    }

    var body: some View {
        List {
            ForEach(0..<sectionCount, id: \.self) { _ in
                sectionPlaceholder
            }
        }
        .accessibilityHidden(true)
    }
}

/// Job list skeleton: rows with completeness ring + title + status pill
struct SkeletonJobsList: View {
    var count: Int = 5

    var body: some View {
        List {
            ForEach(0..<count, id: \.self) { _ in
                SkeletonRow()
                    .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.insetGrouped)
        .accessibilityHidden(true)
    }
}
