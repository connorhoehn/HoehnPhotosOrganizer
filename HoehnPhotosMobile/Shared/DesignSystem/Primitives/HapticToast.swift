import SwiftUI
#if canImport(Pow)
import Pow
#endif

enum ToastKind {
    case success, info, warning, error

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: return HPColor.keeper
        case .info: return HPColor.archive
        case .warning: return HPColor.needsReview
        case .error: return HPColor.reject
        }
    }

    var feedback: SensoryFeedback {
        switch self {
        case .success: return .success
        case .info: return .selection
        case .warning: return .warning
        case .error: return .error
        }
    }
}

struct ToastMessage: Equatable, Identifiable {
    let id = UUID()
    let kind: ToastKind
    let title: String
    let subtitle: String?

    init(_ kind: ToastKind, _ title: String, subtitle: String? = nil) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
    }
}

struct HapticToast: View {
    let message: ToastMessage

    var body: some View {
        GlassPanel(tone: .overlay, cornerRadius: HPRadius.card) {
            HStack(alignment: .center, spacing: HPSpacing.md) {
                Image(systemName: message.kind.icon)
                    .font(.title3)
                    .foregroundStyle(message.kind.tint)
                    .symbolEffect(.bounce, value: message.id)
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.title).font(HPFont.cardTitle)
                    if let subtitle = message.subtitle {
                        Text(subtitle).font(HPFont.cardSubtitle).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HPSpacing.base)
            .padding(.vertical, HPSpacing.md)
        }
        .sensoryFeedback(message.kind.feedback, trigger: message.id)
    }
}

struct HapticToastHost: ViewModifier {
    @Binding var toast: ToastMessage?
    var duration: Double = 2.5

    private var toastTransition: AnyTransition {
        #if canImport(Pow)
        return .movingParts.blur.combined(with: .move(edge: .top))
        #else
        return HPTransition.slideUp
        #endif
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let toast {
                HapticToast(message: toast)
                    .padding(.horizontal, HPSpacing.base)
                    .padding(.top, HPSpacing.sm)
                    .transition(toastTransition)
                    .onAppear {
                        let current = toast.id
                        Task {
                            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                            await MainActor.run {
                                if self.toast?.id == current {
                                    withAnimation(HPMotion.smooth) { self.toast = nil }
                                }
                            }
                        }
                    }
            }
        }
        .animation(HPMotion.smooth, value: toast)
    }
}

extension View {
    func hapticToast(_ toast: Binding<ToastMessage?>) -> some View {
        modifier(HapticToastHost(toast: toast))
    }
}

#Preview("Toasts") {
    struct Demo: View {
        @State var toast: ToastMessage?
        var body: some View {
            VStack(spacing: HPSpacing.base) {
                Button("Success") { toast = .init(.success, "Named as Taylor", subtitle: "3 more faces updated") }
                Button("Info") { toast = .init(.info, "Preparing export") }
                Button("Warning") { toast = .init(.warning, "Slow sync", subtitle: "Check Wi-Fi") }
                Button("Error") { toast = .init(.error, "Couldn't save", subtitle: "Try again") }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(HPColor.canvasBackground)
            .hapticToast($toast)
        }
    }
    return Demo()
}
