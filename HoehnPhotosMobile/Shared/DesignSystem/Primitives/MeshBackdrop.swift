import SwiftUI

struct MeshBackdrop: View {
    enum Palette {
        case warm
        case cool
        case dusk
        case mono

        var colors: [Color] {
            switch self {
            case .warm: return [.pink, .orange, .red, .purple, .orange, .yellow, .pink, .red, .orange]
            case .cool: return [.blue, .teal, .indigo, .cyan, .blue, .mint, .indigo, .blue, .teal]
            case .dusk: return [.purple, .indigo, .pink, .blue, .purple, .pink, .indigo, .purple, .black]
            case .mono: return [.black, .gray, .black, .gray, .black, .gray, .black, .gray, .black]
            }
        }
    }

    var palette: Palette = .dusk
    var animated: Bool = true

    @State private var t: Float = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: animated ? 1.0 / 30.0 : .infinity)) { context in
            let tt = animated ? Float(context.date.timeIntervalSinceReferenceDate).truncatingRemainder(dividingBy: 20) / 20 : 0
            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0, 0], [0.5, 0 + 0.05 * sin(tt * .pi * 2)], [1, 0],
                    [0 + 0.05 * cos(tt * .pi * 2), 0.5], [0.5, 0.5], [1 - 0.05 * cos(tt * .pi * 2), 0.5],
                    [0, 1], [0.5, 1 - 0.05 * sin(tt * .pi * 2)], [1, 1]
                ],
                colors: palette.colors
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

#Preview("Mesh Backdrop – Dusk") {
    ZStack {
        MeshBackdrop(palette: .dusk)
        VStack {
            Text("No unidentified faces")
                .font(HPFont.screenTitle)
                .foregroundStyle(.white)
            Text("Come back after your next import")
                .font(HPFont.cardSubtitle)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}

#Preview("Mesh Backdrop – Warm") {
    MeshBackdrop(palette: .warm)
}

#Preview("Mesh Backdrop – Cool") {
    MeshBackdrop(palette: .cool)
}
