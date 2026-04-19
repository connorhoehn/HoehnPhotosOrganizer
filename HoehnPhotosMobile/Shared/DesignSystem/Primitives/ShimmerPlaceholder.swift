import SwiftUI

struct ShimmerPlaceholder: View {
    var cornerRadius: CGFloat = HPRadius.medium
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(HPColor.shimmerBase)

                LinearGradient(
                    colors: [
                        .clear,
                        HPColor.shimmerHighlight.opacity(0.6),
                        HPColor.shimmerHighlight.opacity(0.9),
                        HPColor.shimmerHighlight.opacity(0.6),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 0.6)
                .offset(x: phase * (geo.size.width + geo.size.width * 0.6))
                .blendMode(.plusLighter)
                .mask(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
        .onAppear {
            withAnimation(HPMotion.shimmer) {
                phase = 1
            }
        }
        .accessibilityHidden(true)
    }
}

#Preview("Shimmer Grid") {
    let cols = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: 3)
    LazyVGrid(columns: cols, spacing: HPGrid.photoGutter) {
        ForEach(0..<12, id: \.self) { _ in
            ShimmerPlaceholder()
                .aspectRatio(1, contentMode: .fit)
        }
    }
    .padding(HPSpacing.base)
}
