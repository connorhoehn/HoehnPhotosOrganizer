import SwiftUI

struct CurationActionBar: View {
    let style: BarStyle
    var currentState: String? = nil  // CurationState rawValue for highlighting
    let onCurate: (String) -> Void  // passes CurationState rawValue

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum BarStyle {
        case compact   // icon + small label, for batch mode
        case prominent // larger icons with material background, for detail view
    }

    private let actions: [(id: String, label: String, icon: String, color: Color)] = [
        ("keeper", "Keep", "checkmark.circle.fill", HPColor.keeper),
        ("archive", "Archive", "archivebox.fill", HPColor.archive),
        ("needs_review", "Review", "eye.fill", HPColor.needsReview),
        ("rejected", "Reject", "xmark.circle.fill", HPColor.reject),
    ]

    var body: some View {
        switch style {
        case .compact:
            compactBar
        case .prominent:
            prominentBar
        }
    }

    private var compactBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                ForEach(actions, id: \.id) { action in
                    Button {
                        HPHaptic.medium()
                        onCurate(action.id)
                    } label: {
                        VStack(spacing: HPSpacing.xxs) {
                            Image(systemName: action.icon)
                                .font(.system(size: 18))
                            Text(action.label)
                                .font(HPFont.badgeLabel)
                        }
                        .foregroundStyle(currentState == action.id ? action.color : .secondary)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, HPSpacing.md)
            .background(HPColor.chromeBackground)
        }
    }

    private var prominentBar: some View {
        HStack(spacing: HPSpacing.lg) {
            ForEach(actions, id: \.id) { action in
                Button {
                    HPHaptic.medium()
                    withAnimation(reduceMotion ? .default : HPAnimation.chipSpring) {
                        onCurate(action.id)
                    }
                } label: {
                    VStack(spacing: HPSpacing.xs) {
                        Image(systemName: action.icon)
                            .font(.system(size: 22))
                        Text(action.label)
                            .font(HPFont.badgeLabel)
                    }
                    .foregroundStyle(currentState == action.id ? action.color : .white.opacity(0.7))
                    .scaleEffect(currentState == action.id ? 1.1 : 1.0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HPSpacing.xl)
        .padding(.vertical, HPSpacing.md)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
