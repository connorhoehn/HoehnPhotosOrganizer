import SwiftUI

/// A horizontal filter bar showing per-curation-state counts with selectable chips.
/// Displays "All" chip and one chip per CurationState (Keeper, Archive, Needs Review, Rejected).
/// Receives counts as a parameter — the parent view is responsible for fetching counts
/// from PhotoRepository and passing them down. This keeps the component testable without a live DB.
struct CurationFilterBar: View {
    let counts: CurationCounts
    @Binding var selectedFilter: CurationState?  // nil = All

    var body: some View {
        HStack(spacing: 8) {
            // "All" chip
            allChip

            // CurationState chips
            ForEach(CurationState.allCases) { state in
                stateChip(state)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var allChip: some View {
        let isSelected = selectedFilter == nil
        // "All" count excludes deleted — deleted photos are only visible via the Deleted chip
        let totalCount = counts.keeper + counts.archive + counts.needsReview + counts.rejected

        return Button(action: { selectedFilter = nil }) {
            HStack(spacing: 4) {
                Text("All")
                Text("\(totalCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(height: 28)
            .paddingHorizontal(12)
            .background(isSelected ? Color.blue.opacity(0.15) : Color.clear)
            .border(isSelected ? Color.blue : Color.secondary, width: 1)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func stateChip(_ state: CurationState) -> some View {
        let isSelected = selectedFilter == state
        let count = countForState(state)

        return Button(action: { selectedFilter = state }) {
            HStack(spacing: 4) {
                Text(state.title)
                Text("\(count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(height: 28)
            .paddingHorizontal(12)
            .background(isSelected ? state.tint.opacity(0.15) : Color.clear)
            .border(isSelected ? state.tint : Color.secondary, width: 1)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func countForState(_ state: CurationState) -> Int {
        switch state {
        case .keeper:
            counts.keeper
        case .archive:
            counts.archive
        case .needsReview:
            counts.needsReview
        case .rejected:
            counts.rejected
        case .deleted:
            counts.deleted
        }
    }
}

// MARK: - View Modifiers

extension View {
    fileprivate func paddingHorizontal(_ value: CGFloat) -> some View {
        padding(.horizontal, value)
    }
}

#Preview {
    CurationFilterBar(
        counts: CurationCounts(keeper: 42, archive: 15, needsReview: 8, rejected: 3),
        selectedFilter: .constant(nil)
    )
    .frame(height: 50)
    .padding()
}
