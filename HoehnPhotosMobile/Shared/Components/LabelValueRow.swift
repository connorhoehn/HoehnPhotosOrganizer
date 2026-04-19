import SwiftUI

struct LabelValueRow: View {
    let icon: String
    let label: String
    let value: String
    var style: Style = .row

    enum Style {
        case card  // vertical layout in a small card (like MetadataCell in photo detail)
        case row   // horizontal HStack (like detailRow in print detail)
    }

    var body: some View {
        switch style {
        case .card:
            VStack(alignment: .leading, spacing: HPSpacing.xs) {
                Label(label, systemImage: icon)
                    .font(HPFont.metaLabel)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(HPFont.metaValue)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HPSpacing.sm + 2)
            .background(HPColor.cardBackground, in: RoundedRectangle(cornerRadius: HPRadius.small))

        case .row:
            HStack(spacing: HPSpacing.sm + 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(label)
                    .font(HPFont.body)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(HPFont.bodyStrong)
                    .lineLimit(1)
            }
        }
    }
}
