import SwiftUI
#if canImport(Pow)
import Pow
#endif

struct FilterPill: View {
    var label: String
    var systemImage: String? = nil
    var count: Int? = nil
    var isActive: Bool = false
    var action: () -> Void

    @State private var pressing: Bool = false

    var body: some View {
        Button {
            HPHaptic.selection()
            action()
        } label: {
            HStack(spacing: HPSpacing.xs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                Text(label)
                    .font(isActive ? HPFont.chipLabelActive : HPFont.chipLabel)
                if let count {
                    Text("\(count)")
                        .font(HPFont.badgeLabel.monospacedDigit())
                        .padding(.horizontal, HPSpacing.xs)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(isActive ? .white.opacity(0.25) : HPColor.chipInactive.opacity(0.8))
                        )
                }
            }
            .padding(.horizontal, HPSpacing.md)
            .padding(.vertical, HPSpacing.xs + 2)
            .foregroundStyle(isActive ? .white : .primary)
            .background(
                Capsule(style: .continuous)
                    .fill(isActive ? AnyShapeStyle(HPColor.chipActive) : AnyShapeStyle(HPColor.chipInactive))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(isActive ? .white.opacity(0.35) : .clear, lineWidth: 0.5)
            )
            .scaleEffect(pressing ? 0.94 : 1)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isActive)
        .onLongPressGesture(minimumDuration: 0, perform: {}, onPressingChanged: { pressed in
            withAnimation(HPMotion.chipPop) { pressing = pressed }
        })
        .animation(HPMotion.chipPop, value: isActive)
        #if canImport(Pow)
        .changeEffect(.jump(height: 4), value: isActive)
        #endif
    }
}

#Preview("Filter Pills") {
    struct Demo: View {
        @State var active: Set<String> = ["Keep"]
        var body: some View {
            VStack(alignment: .leading, spacing: HPSpacing.base) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: HPSpacing.sm) {
                        FilterPill(label: "All", count: 2431, isActive: active.contains("All")) { toggle("All") }
                        FilterPill(label: "Keep", systemImage: "hand.thumbsup", count: 186, isActive: active.contains("Keep")) { toggle("Keep") }
                        FilterPill(label: "Archive", systemImage: "archivebox", count: 45, isActive: active.contains("Archive")) { toggle("Archive") }
                        FilterPill(label: "Reject", systemImage: "trash", count: 12, isActive: active.contains("Reject")) { toggle("Reject") }
                        FilterPill(label: "Needs review", systemImage: "questionmark.circle", count: 89, isActive: active.contains("Needs")) { toggle("Needs") }
                    }
                    .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        func toggle(_ k: String) { if active.contains(k) { active.remove(k) } else { active.insert(k) } }
    }
    return Demo()
}
