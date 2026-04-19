import SwiftUI

struct FaceChip: View {
    enum Size { case small, medium, large
        var diameter: CGFloat { switch self { case .small: 36; case .medium: 54; case .large: 88 } }
        var nameFont: Font { switch self { case .small: HPFont.metaValue; case .medium: HPFont.cardTitle; case .large: HPFont.sectionHeader } }
    }

    var image: UIImage?
    var name: String?
    var size: Size = .medium
    var isSelected: Bool = false
    var isUnknown: Bool { (name ?? "").isEmpty }
    var action: (() -> Void)? = nil

    @State private var pressed = false

    var body: some View {
        Button {
            HPHaptic.selection()
            action?()
        } label: {
            VStack(spacing: HPSpacing.xs) {
                ZStack {
                    Circle()
                        .fill(HPColor.cardBackground)

                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .clipShape(Circle())
                    } else if isUnknown {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: size.diameter * 0.38, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }

                    Circle()
                        .stroke(ringColor, lineWidth: ringWidth)
                        .animation(HPMotion.snappy, value: isSelected)
                }
                .frame(width: size.diameter, height: size.diameter)
                .shadow(color: .black.opacity(0.14), radius: 3, y: 1)
                .scaleEffect(pressed ? 0.94 : 1)

                if size != .small {
                    Text(name ?? "Unknown")
                        .font(size.nameFont)
                        .foregroundStyle(isUnknown ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: size.diameter + HPSpacing.sm)
                }
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { p in
            withAnimation(HPMotion.chipPop) { pressed = p }
        })
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityHint(accessibilityHintText)
        .accessibilityAddTraits(accessibilityTraits)
    }

    private var accessibilityLabelText: String {
        if isUnknown {
            return "Unknown face"
        }
        return "Face of \(name ?? "")"
    }

    private var accessibilityHintText: String {
        if isUnknown {
            return "Double tap to open naming sheet"
        }
        return "Double tap to view photos of \(name ?? "")"
    }

    private var accessibilityTraits: AccessibilityTraits {
        isSelected ? [.isButton, .isSelected] : .isButton
    }

    private var ringColor: Color {
        if isSelected { return HPColor.chipActive }
        if isUnknown { return HPColor.needsReview }
        return .white.opacity(0.6)
    }

    private var ringWidth: CGFloat {
        isSelected ? 3 : (isUnknown ? 2 : 1.5)
    }
}

#Preview("Face Chips – Sizes") {
    HStack(alignment: .top, spacing: HPSpacing.lg) {
        FaceChip(image: nil, name: "Connor", size: .small) {}
        FaceChip(image: nil, name: "Taylor", size: .medium) {}
        FaceChip(image: nil, name: "Alex", size: .large) {}
    }
    .padding()
}

#Preview("Face Chips – States") {
    HStack(alignment: .top, spacing: HPSpacing.md) {
        FaceChip(image: nil, name: "Mom", isSelected: false) {}
        FaceChip(image: nil, name: "Mom", isSelected: true) {}
        FaceChip(image: nil, name: nil) {}
        FaceChip(image: nil, name: "", isSelected: true) {}
    }
    .padding()
}
