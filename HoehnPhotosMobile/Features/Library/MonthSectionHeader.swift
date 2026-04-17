import SwiftUI
import HoehnPhotosCore

/// Sticky section header displaying the month/year label and photo count.
/// Used in the bento grid library layout.
struct MonthSectionHeader: View {
    let displayLabel: String  // "March 2024"
    let photoCount: Int

    var body: some View {
        HStack {
            Text("\(displayLabel) (\(photoCount))")
                .font(.title3.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(uiColor: .systemBackground))
        .accessibilityAddTraits(.isHeader)
    }
}
