import SwiftUI

struct StatusBadge: View {
    let label: String
    let color: Color
    var style: BadgeStyle = .filled

    enum BadgeStyle {
        case filled   // color background at 0.2 opacity, colored text
        case solid    // solid color background, white text
        case outline  // color border, colored text, clear background
    }

    var body: some View {
        Text(label)
            .font(HPFont.badgeLabel)
            .padding(.horizontal, HPSpacing.sm)
            .padding(.vertical, 3)
            .foregroundStyle(foregroundColor)
            .background(backgroundView)
    }

    private var foregroundColor: Color {
        switch style {
        case .filled: return color
        case .solid: return .white
        case .outline: return color
        }
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .filled:
            Capsule().fill(color.opacity(0.2))
        case .solid:
            Capsule().fill(color)
        case .outline:
            Capsule().strokeBorder(color, lineWidth: 1)
        }
    }
}

// MARK: - Convenience

extension StatusBadge {
    static func curation(_ label: String, color: Color) -> StatusBadge {
        StatusBadge(label: label, color: color)
    }

    static func keeper() -> StatusBadge {
        StatusBadge(label: "Keeper", color: HPColor.keeper)
    }

    static func archived() -> StatusBadge {
        StatusBadge(label: "Archived", color: HPColor.archive)
    }

    static func needsReview() -> StatusBadge {
        StatusBadge(label: "Needs Review", color: HPColor.needsReview)
    }

    static func rejected() -> StatusBadge {
        StatusBadge(label: "Rejected", color: HPColor.reject)
    }
}
