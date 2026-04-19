import SwiftUI

struct GlassPanel<Content: View>: View {
    enum Tone { case chrome, sheet, overlay, card }

    var tone: Tone = .chrome
    var cornerRadius: CGFloat = HPRadius.card
    var specular: Double = 0.30
    var stroke: Bool = true
    @ViewBuilder var content: () -> Content

    private var material: Material {
        switch tone {
        case .chrome: return HPMaterial.chromeBar
        case .sheet: return HPMaterial.sheet
        case .overlay: return HPMaterial.overlay
        case .card: return HPMaterial.card
        }
    }

    var body: some View {
        content()
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if stroke {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                }
            }
            .hpSpecular(intensity: specular)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .hpGlassShadow()
    }
}

#Preview("Glass Panel – Light") {
    ZStack {
        LinearGradient(colors: [.orange, .pink, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
        VStack(spacing: HPSpacing.base) {
            GlassPanel(tone: .chrome) {
                Text("Chrome").padding(HPSpacing.base)
            }
            GlassPanel(tone: .sheet) {
                Text("Sheet").padding(HPSpacing.base)
            }
            GlassPanel(tone: .overlay) {
                Text("Overlay").padding(HPSpacing.base)
            }
            GlassPanel(tone: .card) {
                Text("Card").padding(HPSpacing.base)
            }
        }
        .padding()
    }
    .preferredColorScheme(.light)
}

#Preview("Glass Panel – Dark") {
    ZStack {
        LinearGradient(colors: [.blue, .indigo, .black], startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
        GlassPanel(tone: .chrome) {
            Text("Glass on gradient").padding()
        }
    }
    .preferredColorScheme(.dark)
}
