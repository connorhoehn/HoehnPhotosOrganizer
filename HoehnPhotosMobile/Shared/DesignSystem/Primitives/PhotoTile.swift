import SwiftUI

struct PhotoTile: View {
    var image: UIImage?
    var aspect: CGFloat = 1.0
    var cornerRadius: CGFloat = HPRadius.medium
    var isSelected: Bool = false
    var curationColor: Color? = nil
    var overlayBadge: String? = nil
    var onTap: (() -> Void)? = nil

    @State private var pressed: Bool = false

    var body: some View {
        Button {
            HPHaptic.light()
            onTap?()
        } label: {
            ZStack {
                Group {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        ShimmerPlaceholder(cornerRadius: cornerRadius)
                    }
                }
                .aspectRatio(aspect, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if let curationColor {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(curationColor, lineWidth: isSelected ? 0 : 1.5)
                        .opacity(0.9)
                }

                if isSelected {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(HPColor.chipActive, lineWidth: 3)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(HPColor.chipActive.opacity(0.18))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.white, HPColor.chipActive)
                        .padding(HPSpacing.xs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .accessibilityHidden(true)
                }

                if let overlayBadge {
                    Text(overlayBadge)
                        .font(HPFont.badgeLabel)
                        .padding(.horizontal, HPSpacing.xs + 1)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: Capsule())
                        .foregroundStyle(.white)
                        .padding(HPSpacing.xs)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .scaleEffect(pressed ? 0.97 : 1)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { p in
            withAnimation(HPMotion.chipPop) { pressed = p }
        })
        .animation(HPMotion.snappy, value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(defaultAccessibilityLabel)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var defaultAccessibilityLabel: String {
        var parts: [String] = ["Photo"]
        if let overlayBadge { parts.append(overlayBadge) }
        return parts.joined(separator: ", ")
    }
}

#Preview("Photo Tiles") {
    let cols = Array(repeating: GridItem(.flexible(), spacing: HPGrid.photoGutter), count: 3)
    return LazyVGrid(columns: cols, spacing: HPGrid.photoGutter) {
        PhotoTile(image: nil)
            .aspectRatio(1, contentMode: .fit)
        PhotoTile(image: nil, curationColor: HPColor.keeper)
            .aspectRatio(1, contentMode: .fit)
        PhotoTile(image: nil, isSelected: true)
            .aspectRatio(1, contentMode: .fit)
        PhotoTile(image: nil, curationColor: HPColor.needsReview, overlayBadge: "RAW")
            .aspectRatio(1, contentMode: .fit)
        PhotoTile(image: nil, curationColor: HPColor.reject)
            .aspectRatio(1, contentMode: .fit)
        PhotoTile(image: nil, overlayBadge: "+12")
            .aspectRatio(1, contentMode: .fit)
    }
    .padding(HPSpacing.base)
}
