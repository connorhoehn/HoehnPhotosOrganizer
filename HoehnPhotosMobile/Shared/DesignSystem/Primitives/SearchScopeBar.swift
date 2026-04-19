import SwiftUI

enum SearchScope: String, CaseIterable, Identifiable {
    case all, people, places, cameras, dates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .people: return "People"
        case .places: return "Places"
        case .cameras: return "Cameras"
        case .dates: return "Dates"
        }
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .people: return "person.2"
        case .places: return "mappin.and.ellipse"
        case .cameras: return "camera"
        case .dates: return "calendar"
        }
    }

    var accent: Color {
        switch self {
        case .all: return HPColor.chipActive
        case .people: return .pink
        case .places: return .teal
        case .cameras: return .indigo
        case .dates: return .orange
        }
    }
}

struct SearchScopeBar: View {
    @Binding var selection: SearchScope
    var namespaceID: Namespace.ID

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: HPSpacing.sm) {
                ForEach(SearchScope.allCases) { scope in
                    ScopeButton(
                        scope: scope,
                        isActive: selection == scope,
                        namespaceID: namespaceID
                    ) {
                        withAnimation(HPMotion.scopeMorph) {
                            selection = scope
                        }
                    }
                }
            }
            .padding(.horizontal, HPSpacing.base)
            .padding(.vertical, HPSpacing.sm)
        }
        .scrollClipDisabled()
    }
}

private struct ScopeButton: View {
    let scope: SearchScope
    let isActive: Bool
    let namespaceID: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button {
            HPHaptic.selection()
            action()
        } label: {
            HStack(spacing: HPSpacing.xs) {
                Image(systemName: scope.systemImage)
                    .font(.caption.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(scope.title)
                    .font(isActive ? HPFont.chipLabelActive : HPFont.chipLabel)
            }
            .padding(.horizontal, HPSpacing.md)
            .padding(.vertical, HPSpacing.sm)
            .foregroundStyle(isActive ? .white : .primary)
            .background {
                if isActive {
                    Capsule()
                        .fill(scope.accent)
                        .matchedGeometryEffect(id: HPNamespaceID.searchScope, in: namespaceID)
                }
            }
            .overlay {
                Capsule().stroke(.white.opacity(isActive ? 0.35 : 0), lineWidth: 0.5)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview("Scope Bar") {
    struct Demo: View {
        @Namespace var ns
        @State var scope: SearchScope = .all
        var body: some View {
            VStack(spacing: HPSpacing.xl) {
                SearchScopeBar(selection: $scope, namespaceID: ns)
                Text("Scope: \(scope.title)")
                    .font(HPFont.sectionHeader)
                    .contentTransition(.interpolate)
                Spacer()
            }
            .padding(.top, HPSpacing.xxl)
        }
    }
    return Demo()
}
