import SwiftUI

// MARK: - Spacing

enum HPSpacing {
    static let xxs: CGFloat = 2    // Photo grid gutters (tight)
    static let xs: CGFloat = 4     // Icon-to-label, inner padding
    static let sm: CGFloat = 8     // Between related elements
    static let md: CGFloat = 12    // Chip internal padding, card internal
    static let base: CGFloat = 16  // Standard margins, section padding
    static let lg: CGFloat = 20    // Safe area horizontal
    static let xl: CGFloat = 24    // Between sections
    static let xxl: CGFloat = 32   // Major section breaks
    static let xxxl: CGFloat = 48  // Top of screen to first content
}

// MARK: - Corner Radii

enum HPRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 10
    static let large: CGFloat = 12
    static let card: CGFloat = 16
    static let pill: CGFloat = .infinity  // Capsule
}

// MARK: - Typography

enum HPFont {
    static let screenTitle: Font = .title2.weight(.bold)
    static let sectionHeader: Font = .title3.weight(.semibold)
    static let cardTitle: Font = .subheadline.weight(.semibold)
    static let cardSubtitle: Font = .caption
    static let chipLabel: Font = .subheadline.weight(.medium)
    static let chipLabelActive: Font = .subheadline.weight(.semibold)
    static let badgeLabel: Font = .caption2.weight(.semibold)
    static let metaLabel: Font = .caption2
    static let metaValue: Font = .caption.weight(.medium)
    static let timestamp: Font = .caption2
    static let body: Font = .subheadline
    static let bodyStrong: Font = .subheadline.weight(.medium)
}

// MARK: - Semantic Colors

enum HPColor {
    static let canvasBackground = Color.black
    static let chromeBackground = Color(uiColor: .systemBackground)
    static let cardBackground = Color(uiColor: .secondarySystemBackground)
    static let elevatedBackground = Color(uiColor: .tertiarySystemBackground)
    static let chipInactive = Color(uiColor: .secondarySystemFill)
    static let chipActive = Color.accentColor
    static let shimmerBase = Color(uiColor: .systemFill)
    static let shimmerHighlight = Color(uiColor: .secondarySystemFill)
    static let gridBackground = Color.black
    static let separator = Color(uiColor: .separator)

    // Curation semantic colors
    static let keeper = Color.green
    static let archive = Color.blue
    static let needsReview = Color.orange
    static let reject = Color.red
}

// MARK: - Grid

enum HPGrid {
    static let photoGutter: CGFloat = HPSpacing.xxs  // 2pt between photos
    static let defaultColumns = 3
    static let compactColumns = 4
    static let expandedColumns = 1
}

// MARK: - Animation

enum HPAnimation {
    static let chipSpring: Animation = .spring(response: 0.25, dampingFraction: 0.85)
    static let cardSpring: Animation = .spring(response: 0.3, dampingFraction: 0.8)
    static let fadeIn: Animation = .easeOut(duration: 0.2)
    static let sheetPresent: Animation = .easeInOut(duration: 0.25)
}

// MARK: - Haptics

enum HPHaptic {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func heavy() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
}
