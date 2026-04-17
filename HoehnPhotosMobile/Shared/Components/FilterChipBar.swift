import SwiftUI

struct FilterChip: Identifiable {
    let id: String
    let label: String
    var icon: String? = nil
    var tint: Color? = nil
    var count: Int? = nil
}

struct FilterChipBar: View {
    let chips: [FilterChip]
    let selectedId: String?
    let onSelect: (String?) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HPSpacing.sm) {
                ForEach(chips) { chip in
                    let isActive = selectedId == chip.id
                    Button {
                        withAnimation(reduceMotion ? .default : HPAnimation.chipSpring) {
                            onSelect(isActive ? nil : chip.id)
                        }
                        HPHaptic.selection()
                    } label: {
                        HStack(spacing: HPSpacing.xs) {
                            if let icon = chip.icon {
                                Image(systemName: icon)
                                    .font(.system(size: 11))
                            }
                            Text(chip.label)
                                .font(isActive ? HPFont.chipLabelActive : HPFont.chipLabel)
                                .minimumScaleFactor(0.8)
                                .lineLimit(1)
                            if let count = chip.count, count > 0 {
                                Text("\(count)")
                                    .font(HPFont.badgeLabel)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(
                                        Capsule()
                                            .fill(isActive ? Color.white.opacity(0.25) : Color.primary.opacity(0.12))
                                    )
                            }
                        }
                        .padding(.horizontal, HPSpacing.md)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(isActive
                                      ? (chip.tint ?? HPColor.chipActive)
                                      : HPColor.chipInactive)
                        )
                        .foregroundStyle(isActive ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, HPSpacing.base)
            .padding(.vertical, HPSpacing.sm)
        }
    }
}
