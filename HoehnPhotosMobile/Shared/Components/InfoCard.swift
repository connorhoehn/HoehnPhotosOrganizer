import SwiftUI

struct InfoCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = HPSpacing.md
    var cornerRadius: CGFloat = HPRadius.card

    init(
        padding: CGFloat = HPSpacing.md,
        cornerRadius: CGFloat = HPRadius.card,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .padding(padding)
            .background(HPColor.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

// Elevated variant with shadow
struct ElevatedCard<Content: View>: View {
    let content: Content
    var padding: CGFloat = HPSpacing.md
    var cornerRadius: CGFloat = HPRadius.card

    init(
        padding: CGFloat = HPSpacing.md,
        cornerRadius: CGFloat = HPRadius.card,
        @ViewBuilder content: () -> Content
    ) {
        self.content = content()
        self.padding = padding
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .padding(padding)
            .background(HPColor.cardBackground, in: RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 2)
    }
}
