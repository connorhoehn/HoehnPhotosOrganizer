import SwiftUI

enum HPMaterial {
    static let chromeBar: Material = .ultraThinMaterial
    static let sheet: Material = .regularMaterial
    static let overlay: Material = .ultraThinMaterial
    static let card: Material = .thickMaterial
}

enum HPBlur {
    static let subtle: CGFloat = 8
    static let moderate: CGFloat = 18
    static let strong: CGFloat = 32
}

enum HPShadow {
    static func card(elevated: Bool = false) -> some View {
        Rectangle()
            .fill(.black.opacity(elevated ? 0.18 : 0.08))
            .blur(radius: elevated ? 14 : 6)
    }

    static let cardColor: Color = .black.opacity(0.12)
    static let cardRadius: CGFloat = 8
    static let cardYOffset: CGFloat = 2

    static let glassColor: Color = .black.opacity(0.20)
    static let glassRadius: CGFloat = 16
    static let glassYOffset: CGFloat = 4
}

struct HPSpecularHighlight: ViewModifier {
    var intensity: Double = 0.35

    func body(content: Content) -> some View {
        content.overlay(
            LinearGradient(
                colors: [
                    .white.opacity(intensity),
                    .white.opacity(intensity * 0.4),
                    .clear,
                    .clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .blendMode(.overlay)
            .allowsHitTesting(false)
        )
    }
}

extension View {
    func hpSpecular(intensity: Double = 0.35) -> some View {
        modifier(HPSpecularHighlight(intensity: intensity))
    }

    func hpGlassShadow() -> some View {
        shadow(color: HPShadow.glassColor, radius: HPShadow.glassRadius, y: HPShadow.glassYOffset)
    }

    func hpCardShadow() -> some View {
        shadow(color: HPShadow.cardColor, radius: HPShadow.cardRadius, y: HPShadow.cardYOffset)
    }
}
