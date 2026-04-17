import SwiftUI

struct SectionHeader: View {
    let title: String
    var count: Int? = nil
    var trailing: AnyView? = nil
    var style: HeaderStyle = .inline

    enum HeaderStyle {
        case sticky   // opaque background for pinned headers
        case inline   // transparent, inside scroll content
    }

    var body: some View {
        HStack {
            HStack(spacing: HPSpacing.xs) {
                Text(title)
                    .font(HPFont.sectionHeader)
                if let count {
                    Text("(\(count))")
                        .font(HPFont.sectionHeader)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let trailing {
                trailing
            }
        }
        .padding(.horizontal, HPSpacing.base)
        .padding(.vertical, HPSpacing.sm)
        .background(backgroundView)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var backgroundView: some View {
        switch style {
        case .sticky:
            HPColor.chromeBackground
        case .inline:
            Color.clear
        }
    }
}

// MARK: - Convenience

extension SectionHeader {
    init(_ title: String, count: Int? = nil, style: HeaderStyle = .inline) {
        self.title = title
        self.count = count
        self.trailing = nil
        self.style = style
    }
}
